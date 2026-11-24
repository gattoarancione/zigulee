# Proposal: `StateMachine`, statecharts in `.zge`

Status: done (2026-11-24), all four steps: machines in components and
globals, states inside states with history, parallel regions, final
states and `done`, eventless transitions, compiled and interpreted
(language.md, "State machines"; examples/traffic.zge), and SCXML import
(`zgec scxml`, tooling.md; examples/scxml/microwave.scxml). Its questions were
answered the same day (see the end); what the steps settled is under
"Decided while building". It goes beyond the roadmap's "States and
Transitions" (🟡, no state groups) in ROADMAP-QT.md.

## Why

A `.zge` file can already hold a small state machine, built by hand: an
enum for the state, functions for the transitions (their guards as `if`s),
a `Timer` for each delay, `changed` for what happens on entry, `states
[...]` for how each state looks. It works for three or four states and
then stops scaling:

- the transitions are scattered over functions, nowhere in one place;
- `changed` runs once per frame, batched: no real entry and exit actions,
  no order between leaving one state and entering the next, and nothing
  says which state was left;
- no nesting (a transition shared by a group of states is written once per
  state), no parallel regions, no history, no final states;
- each delay is a `Timer` of its own, started and stopped by hand.

SCXML (W3C, 2015) settled what a statechart means: hierarchical and
parallel states, entry and exit actions, history, final states, delayed
events, a run-to-completion event queue. This proposal brings those
semantics into the language, compiled like the rest: no XML at run time,
no interpreter, a flat table in Zig, cheap enough for a microcontroller.

## Syntax

A `StateMachine` element, not drawn, with the states inside:

```slint
enum Reason { timeout, refused }

export component Fetcher inherits Window {
    var out <string> text;

    machine := StateMachine {
        // Events, typed as callbacks are.
        event go;
        event done(bool);
        event cancel;

        initial idle;

        state idle {
            on go => loading;
        }
        state loading {
            entered => { spinner.visible = true; }
            exited => { spinner.visible = false; }
            on done(ok) when ok => ready;
            on done(ok) => failed { root.text = "refused"; }
            after 5s => failed { root.text = "timed out"; }
            on cancel => idle;
        }
        state ready {
            initial viewing;
            history;                                  // shallow (deep: `history deep;`)
            state viewing { on edit => editing; }
            state editing { on save => viewing; }
            on cancel => idle;                        // for both children
        }
        state failed {
            on go => loading;
        }
    }

    states [
        busy when machine.active(loading) : { label.color: gray; }
    ]
    Button { text: "Go"; clicked => { machine.go(); } }
}
```

- `event name(types)` declares an event; sending it is calling it:
  `machine.done(true)`, from handlers and from Zig. Events are typed and
  checked like callbacks; a misspelt or missing event is a compile error,
  not a string that never matches. There is no string form (decided
  2026-11-24): an event chosen at run time is an `if` over the events,
  written by the app.
- `state name { ... }` is a state; states nest. A state with child states
  is compound and names its `initial` one (else its first).
- `parallel name { ... }` is a state whose children are all active at
  once, each a region of its own.
- `final name;` is a final state. When a compound state's final child is
  entered, or every region of a parallel one has reached its final state,
  the state's `done` event is raised (`on done.ready => ...`).
- `history;` or `history deep;` in a compound state: entering it through
  its history (`=> ready.history`) resumes the child (or descendants) last
  active, else its initial one.
- `entered => { ... }` and `exited => { ... }` are the entry and exit
  actions.
- `on event(params) when guard => target { actions }`: a transition.
  Each part after the event is optional: no `when` is always taken, no
  target (`on tick { count += 1; }`) is an internal transition that
  neither leaves nor enters a state, and a missing block runs nothing.
  The guard and the actions read the event's parameters.
- `after duration => target { actions }`: a delayed transition, armed when
  the state is entered and cancelled when it is left.
- A transition with neither `on` nor `after`, `when guard => target`, is
  eventless: taken as soon as its guard holds after a step (SCXML's
  transitions without `event`).

What the machine shows to the rest of the component:

- `machine.active(name)`: whether that state is active, a bool usable in
  bindings and `states [...]` (SCXML's `In()`). Names are checked at
  compile time; a nested state can be named alone when that is not
  ambiguous, else by its path (`ready.editing`).
- `machine.current`: the active leaf states' names, joined by `/`
  (`"ready/editing"`), for debugging and accessibility; a string.
- `machine.state`: the same as a value of an enum generated per machine,
  one member per leaf state (`Fetcher.machine.State.editing` in Zig,
  `machine.state == MachineState.editing` in `.zge`), for code that
  switches on it. With parallel regions, one such property per region
  (`machine.net-state`, `machine.sync-state`), each its region's leaf.
  Both forms exist (decided 2026-11-24).
- `machine.running`, `machine.start()`, `machine.stop()`: the machine runs
  from when the component is created unless `running: false`; `stop()`
  leaves every state (exit actions included), `start()` enters the
  initial configuration again.
- `changed machine.current => { ... }` works like any `changed`.

A `global` can hold a machine (decided 2026-11-24): an app's session
(signed out, signing in, signed in) or connection state, reachable from
every component as `Session.machine.active(signed-in)`, events sent as
`Session.machine.sign-in(user)`. It runs from the program's start.

```slint
export global Session {
    var out <string> user;
    machine := StateMachine {
        event sign-in(string);
        event signed-in;
        event sign-out;
        state signed-out { on sign-in(name) => signing-in { Session.user = name; } }
        state signing-in { on signed-in => signed-in; after 10s => signed-out; }
        state signed-in { on sign-out => signed-out { Session.user = ""; } }
    }
}
```

A machine is an element inside a component or global first (decided
2026-11-24); a top-level `machine Name { ... }`, shared between
components and tested alone, can come after step 3 if wanted, with the
same body.

## Semantics

SCXML's algorithm, with the same names for the same things:

- **Run to completion.** An event sent while the machine is processing
  another is queued. Each event makes one step: the transitions it
  enables are chosen, then taken; then eventless transitions are taken
  until none is enabled; then the next queued event. Events sent from
  actions are queued too. As in SCXML (decided 2026-11-24), events the
  machine sends itself, from its own guards' and actions' code, go in an
  internal queue processed before the external one: a step and the
  events it raises finish before anything from outside is looked at.
- **Choosing.** In each active state, from the innermost outwards, the
  first transition in document order whose event matches and whose guard
  holds. A child's transition wins over its parent's (the parent's is the
  fallback). Two transitions in different regions of a parallel state are
  both taken unless their exit sets conflict, in which case the one in
  the earlier region wins.
- **Taking.** Exit actions of the states left (innermost first), then the
  transition's actions, then entry actions of the states entered
  (outermost first). History is recorded on exit.
- **Synchronous, not batched.** Unlike `changed`, the step runs when the
  event is sent: `machine.go(); machine.active(loading)` is true on the
  next line. Bindings that read `active()` and `current` update as any
  property does.
- **Guards** are expressions, evaluated while choosing transitions, maybe
  more than once: they must not assign (the compiler rejects assignments
  in them; calls to functions that assign are a new check, which
  bindings do not have today either).
- **Delays** use the UI clock (`time.zig`), as Timer does: deterministic
  in tests, paused with it.
- **Loops.** Eventless transitions that keep enabling each other stop
  after a fixed number of rounds (100) with a logged error, rather than
  hanging the UI thread.

## Code generation

The compiler turns each machine into data and a small runtime in the core
(`src/core/statemachine.zig`), shared by compiled code and the
interpreter:

- **States** numbered in document order: a table of parent, first child,
  kind (atomic, compound, parallel, final, history) and initial child.
  The active configuration is a bit set (`u64`, or a `[n]u64` when there
  are more states), so `active()` is a bit test.
- **Transitions:** a table per state of event id, guard, target set and
  actions, guards and actions being generated functions of the component
  (as handlers are today). Exit and entry sets are computed at compile
  time where the source and target are known (nearly always), at run time
  only for history.
- **Events:** an enum per machine; `machine.done(true)` queues the event
  id and its parameters in a fixed-size queue (a compile-time size,
  default 16; overflow is a logged error and drops the event), two queues
  in fact: internal and external.
- **`current` and `state`:** `current` is built from the configuration
  when read (a binding, so only when used); each `state` property is set
  as part of a step, after the entry actions.
- **Delays:** one timer slot per `after` (the UI clock's timers), armed on
  entry and disarmed on exit.
- **No allocation** after the component is created: the tables are
  constants, the configuration, history and queue live in the component.
  That keeps it usable on the ESP32-S3 and Cortex-M builds.

The interpreter builds the same tables from the analyzed document, so
`zigulee-viewer` and the language server (hover on a state shows its
transitions, go to definition on a target, rename) need no machine of
their own.

## What exists already, and stays

- `states [...]` keeps its meaning (property overrides while a condition
  holds, with `in`/`out` animations); `machine.active(x)` is just a
  condition it can use. They complement each other: the machine decides,
  `states` shows.
- Enums, `Timer`, `changed` and functions stay the way to write small
  machines by hand; nothing is deprecated.

## Importing SCXML

Later, not needed for the rest: `zgec scxml machine.scxml` writes the
equivalent `StateMachine` as `.zge`, for machines designed in SCXML
tools. The mapping is one to one for `<state>`, `<parallel>`, `<final>`,
`<history>`, `<transition event cond target type>`, `<onentry>`,
`<onexit>`, `<raise>` and `<send delay>`; `cond` and executable content
written in a small expression subset are translated, anything else
(ECMAScript data model, `<invoke>`, `<script>`, `<send>` to other
targets) is left as a comment for the author to finish, with a warning.

## Work, in order

1. **Flat machines.** `StateMachine` in components and globals, `event`,
   `state`, `initial`, `on`, `when`, targetless transitions,
   `entered`/`exited`, `after`, `active()`, `current`, `state` and its
   enum, `start()`/`stop()`, the internal and external queues; the core
   runtime and its tests; compiler, interpreter and the language server's
   symbols; docs in language.md; an example (a traffic light, a fetch
   with timeout).
2. **Hierarchy.** Nested states, transitions inherited from parents,
   `history` and `history deep`, paths in `active()`.
3. **Parallel and final.** `parallel`, `final`, `done.<state>` events,
   conflict resolution between regions, eventless transitions.
4. **SCXML import** (`zgec scxml`), with conformance tests taken from the
   W3C SCXML test suite where they fit the supported subset.

Each step ships on its own, with its tests passing in the compiled and
interpreted runs (`tests/interpreter_test.zig`).

## Decided while building step 4 (2026-11-24)

- The output is a `global` named after the document's `name` (else its
  file), holding `machine := StateMachine { ... }`; the data model is the
  global's `var in-out` properties, typed after their literal values
  (`int` when a value is not a literal, with a warning).
- Data is read and assigned as `root.name`: unqualified, the machine
  element's own members (`x`, `width`, `visible`...) would hide it.
- Names are made valid `.zge` names (other characters as `_`, `s_` before
  a digit, `-n2`... when taken; `history` cannot be a state's name), and
  events that would take a machine member's name get `-event`.
- `<send>` to the machine itself is a `<raise>` (the machine's own events
  go first, where SCXML's external queue would put them after the
  internal events); with a `delay` in `<onentry>`, an `after` of its
  state, so it is cancelled when the state is left (SCXML would keep it
  pending): a warning says so once. `<cancel>` in `<onexit>` is then the
  `after`'s own cancelling, dropped silently.
- A `<history>`'s default transition is replaced by its state's initial
  state, with a warning when they differ; event prefixes (`a.*`) are
  matched exactly, with a warning.
- Unconvertible conditions become `false` (the transition is never
  taken) with the original as a comment; unconvertible actions become
  comments. Every such case is a warning with its line, and the output
  compiles.
- XML is read by a small reader of its own (xml.zig): no dependency.
- The W3C test suite itself is not vendored: conformance tests are SCXML
  documents of our own in its style (a `pass` final state), converted and
  run by the interpreter, one per rule (document order, the internal
  queue, done events, history, `In()`, the data model).

## Decided while building step 3 (2026-11-24)

- Names are scoped: a name in a transition (target or `done.x`) is looked
  for among the states inside the parent of the transition's state (one
  directly inside first), then a level further out, up to the whole
  machine; so regions can each have their own `on` and `off`. From outside
  the machine (`active()`), from the top. Step 2's rule is the outermost
  level of this one.
- `final name;`, or `final name { entered => { } exited => { } }`: a final
  state has no transitions or states inside. `on done.x` needs x to have
  states inside; a user event may still be called `done` (`on done(ok)`).
- A final state at the top of a machine: the machine stays in it (SCXML
  would end the session); nothing more happens until `stop()` and
  `start()`.
- Eventless transitions (`when guard => target`) are checked on entry and
  after each event, as SCXML does, not when what the guard reads changes.
  After 100 in a row they wait for the next event, with an error logged.
- Conflicts between regions follow SCXML: two transitions conflict when
  the states they leave overlap; one from a state inside the other's
  source wins, else the first in document order.
- `current` joins the active atomic states' paths with `, `. `state` is
  the first active atomic state (document order); each region (a state
  directly inside a parallel one) gets `<name>-state` (its path with `-`
  where regions share names), of the enum `<Id><Name>State`. Before a
  region ran, it reads the region's first atomic state.
- The runtime keeps the active states as a set, and selects, filters and
  takes transitions as SCXML's algorithm does (exit set in reverse
  document order, entry set in document order, regions of parallel states
  filled in); `done` events go on the internal queue.

## Decided while building step 2 (2026-11-24)

- Transitions are external, as SCXML's default: one from a state to a
  state inside it leaves and enters the state again (its entry and exit
  actions run). Internal transitions are the targetless ones.
- A name alone names a top-level state of that name, else the only state
  of that name anywhere; otherwise the compiler asks for the path and
  lists the candidates (step 3 looks near the transition first). Paths go down from there (`menu.detail`), and
  `.history` may end one whose last state keeps a history. `active()`
  takes the same names and paths (not a history).
- `history` cannot name a state; a history in a state with no states
  inside, and `initial` naming a state that is not directly inside, are
  errors.
- `current` is the innermost active state's path joined by `/`
  (`on/menu/detail`). The `state` enum has a value per state with no
  states inside: its name, or its path with `-` (`a-x`) where two share a
  name.
- The runtime keeps the innermost active state (its ancestors are active
  with it) and, per state, its recorded history; it finds the transition
  domain at run time (the innermost proper ancestor of the source that
  contains the target), which keeps the generated table small.

## Decided while building step 1 (2026-11-24)

- An event cannot take the name of a member every machine has
  (`running`, `current`, `state`, `active`, `start`, `stop`): `event
  start;` is a compile error that says so (the examples above say `go`).
- From Zig, events are sent by methods of the component holding the
  machine: `app.send_fetch_done(true)` for event `done` of `fetch` (a
  global's: `Session.instance.send_machine_sign_in("ada")`).
- After `stop()`, `current` is `""` and `active()` false for every state,
  but `state` keeps the last active state (an enum has no "none").
- The runtime is one type for every machine, `core.statemachine
  .StateMachine`: a constant `Definition` (states, transitions numbered in
  order, triggers, targets) and hooks into the component (guard, action,
  entered, exited, delay), each a `switch` over the transition or state in
  the generated code, evaluating the syntax tree in the interpreter. Event
  arguments travel as a small union (bool, int, float, string; enums as
  ints); strings are copied only when an event has to wait in a queue.
- The language server knows states and events as symbols: hover, go to
  definition, references and rename work on their declarations, `initial`,
  transition targets, the events transitions wait for, `active(name)` and
  sent events.

## Questions, answered (2026-11-24)

1. **Element or construct?** An element first, in components and
   globals; a top-level `machine Name { ... }` maybe later.
2. **Event syntax.** Typed events only, sent by calling them; no string
   form.
3. **`current`.** Both: the `current` string and a generated enum
   (`state`, one per parallel region).
4. **Internal events first.** Yes, as SCXML: an internal queue ahead of
   the external one.
5. **Globals.** Yes, a `global` can hold a machine.
