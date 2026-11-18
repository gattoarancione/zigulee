// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Linux accessibility: shows zigulee windows' accessible items
//! (`zigulee.core.accessibility`) to screen readers (Orca) through AT-SPI,
//! the accessibility protocol of Linux desktops, which runs over D-Bus.
//!
//! The process connects once to the accessibility bus and registers its
//! application with the registry (`Socket.Embed`); every window with a
//! `Bridge` is a frame under the application, and every accessible item an
//! object under its window: `/org/a11y/atspi/accessible/<id>`. Objects
//! answer from the latest snapshot (the Accessible, Component, Action,
//! Value and Text interfaces) and perform actions through zigulee; changes
//! are signalled as AT-SPI events. Ids are kept per item, so a screen
//! reader does not lose its place when the snapshot changes; those of items
//! that are gone answer UnknownObject.
//!
//! Messages are read on the window's thread, in `update`. For a loop that
//! sleeps, `wake` (if set) is called from a helper thread when messages
//! arrive, to wake it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const a11y = core.accessibility;
const dbus = @import("dbus.zig");
/// File dialogs through the XDG desktop portal (over the same D-Bus
/// client).
pub const portal = @import("portal.zig");
/// Desktop notifications over D-Bus.
pub const notifications = @import("notifications.zig");
/// `open-url` through the desktop portal (or xdg-open).
pub const openuri = @import("openuri.zig");
const c = std.c;

const log = std.log.scoped(.zigulee_atspi);

pub const Error = dbus.Error;

const path_prefix = "/org/a11y/atspi/accessible/";
const root_path = path_prefix ++ "root";
const null_path = "/org/a11y/atspi/null";

const i_accessible = "org.a11y.atspi.Accessible";
const i_application = "org.a11y.atspi.Application";
const i_component = "org.a11y.atspi.Component";
const i_action = "org.a11y.atspi.Action";
const i_value = "org.a11y.atspi.Value";
const i_selection = "org.a11y.atspi.Selection";
const i_text = "org.a11y.atspi.Text";
const i_properties = "org.freedesktop.DBus.Properties";
const e_unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
const e_unknown_object = "org.freedesktop.DBus.Error.UnknownObject";
const e_invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";

/// Called from a helper thread when messages arrive (to wake a sleeping
/// event loop, which then calls `update`). Set before the first `create`.
pub var wake: ?*const fn () void = null;

// AT-SPI roles (AtspiRole).
const Role = enum(u32) {
    check_box = 7,
    combo_box = 11,
    frame = 23,
    image = 27,
    label = 29,
    list = 31,
    list_item = 32,
    page_tab = 37,
    page_tab_list = 38,
    panel = 39,
    progress_bar = 42,
    push_button = 43,
    radio_button = 44,
    slider = 51,
    spin_button = 52,
    table = 55,
    table_cell = 56,
    table_column_header = 57,
    toggle_button = 62,
    application = 75,
    entry = 79,
    table_row = 90,

    fn name(r: Role) []const u8 {
        return switch (r) {
            .check_box => "check box",
            .combo_box => "combo box",
            .frame => "frame",
            .image => "image",
            .label => "label",
            .list => "list",
            .list_item => "list item",
            .page_tab => "page tab",
            .page_tab_list => "page tab list",
            .panel => "panel",
            .progress_bar => "progress bar",
            .push_button => "push button",
            .radio_button => "radio button",
            .slider => "slider",
            .spin_button => "spin button",
            .table => "table",
            .table_cell => "table cell",
            .table_column_header => "table column header",
            .table_row => "table row",
            .toggle_button => "toggle button",
            .application => "application",
            .entry => "entry",
        };
    }
};

fn roleOf(role: core.AccessibleRole) Role {
    return switch (role) {
        .button => .push_button,
        .checkbox => .check_box,
        .radio_button => .radio_button,
        .switch_ => .toggle_button,
        .combobox => .combo_box,
        .list => .list,
        .list_item => .list_item,
        .slider => .slider,
        .spinbox => .spin_button,
        .tab => .page_tab,
        .tab_list => .page_tab_list,
        .table => .table,
        .table_row => .table_row,
        .table_cell => .table_cell,
        .column_header => .table_column_header,
        .text => .label,
        .text_input => .entry,
        .progress_indicator => .progress_bar,
        .image => .image,
        .group, .tab_panel, .unset, .none => .panel,
    };
}

// AT-SPI states (AtspiStateType): bits of two 32-bit words.
const State = enum(u6) {
    active = 1,
    checked = 4,
    editable = 7,
    enabled = 8,
    focusable = 11,
    focused = 12,
    multiselectable = 18,
    resizable = 21,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    visible = 30,
    checkable = 41,
    read_only = 43,
};

const States = struct {
    bits: u64 = 0,
    fn set(s: *States, state: State) void {
        s.bits |= @as(u64, 1) << @intFromEnum(state);
    }
};

/// The actions of a role: names, and what each does.
fn actionsOf(role: core.AccessibleRole) []const struct { []const u8, a11y.Action } {
    return switch (role) {
        .button, .list_item, .tab, .combobox, .radio_button, .table_row, .column_header => &.{.{ "click", .default }},
        .checkbox, .switch_ => &.{.{ "toggle", .default }},
        .slider, .spinbox => &.{ .{ "increment", .increment }, .{ "decrement", .decrement } },
        else => &.{},
    };
}

fn isSelectable(role: core.AccessibleRole) bool {
    return role == .list_item or role == .table_row or role == .tab;
}

/// An item of a list or table (selected through its Selection).
fn isSelectionItem(role: core.AccessibleRole) bool {
    return role == .list_item or role == .table_row;
}

fn isSelectionContainer(role: core.AccessibleRole) bool {
    return role == .list or role == .table;
}

fn isSelected(t: Target) bool {
    return t == .item and isSelectionItem(t.item.node.role) and t.item.node.checked;
}

fn hasValue(role: core.AccessibleRole) bool {
    return switch (role) {
        .slider, .spinbox, .progress_indicator => true,
        else => false,
    };
}

fn hasText(role: core.AccessibleRole) bool {
    return role == .text or role == .text_input;
}

// ---- The application (one per process) ----

const App = struct {
    gpa: Allocator,
    conn: *dbus.Connection,
    /// The registry's desktop: the application's parent.
    parent: struct { name: []const u8 = "", path: []const u8 = null_path } = .{},
    parent_bytes: ?dbus.Received = null,
    bridges: std.ArrayList(*Bridge) = .empty,
    /// What each object id is: a window's frame (`item` null) or an item.
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    next_id: u32 = 1,
    id: i32 = 0,
    /// The helper thread that waits for messages (with `wake`), and the
    /// pipe it is told things on: 'd' (messages read), 'q' (quit).
    waiter: ?std.Thread = null,
    pipe: [2]c.fd_t = .{ -1, -1 },
    waiting: std.atomic.Value(bool) = .init(false),

    const Object = struct { bridge: *Bridge, item: ?*core.Item };

    fn open(gpa: Allocator, address: []const u8) Error!*App {
        const conn = try dbus.Connection.open(gpa, address);
        errdefer conn.close();
        const self = try gpa.create(App);
        self.* = .{ .gpa = gpa, .conn = conn };
        // Register with the registry (absent on a bare bus: then clients
        // find the application by its name only).
        var w: dbus.Writer = .init(gpa);
        defer w.deinit();
        w.ref(conn.unique_name, root_path);
        if (conn.callOk(.{ .destination = "org.a11y.atspi.Registry", .path = root_path, .interface = "org.a11y.atspi.Socket", .member = "Embed" }, "(so)", try w.finish())) |r| {
            var body = r.message.reader();
            if (body.structure()) {
                const name = body.string() catch "";
                const path = body.string() catch null_path;
                self.parent = .{ .name = name, .path = path };
                self.parent_bytes = r;
            } else |_| r.deinit(gpa);
        } else |err| log.info("not registered with the AT-SPI registry ({t})", .{err});
        if (wake != null) self.startWaiter();
        return self;
    }

    fn close(self: *App) void {
        if (self.waiter) |t| {
            _ = c.write(self.pipe[1], "q", 1);
            t.join();
        }
        if (self.pipe[0] >= 0) {
            _ = c.close(self.pipe[0]);
            _ = c.close(self.pipe[1]);
        }
        if (self.parent_bytes) |r| r.deinit(self.gpa);
        self.objects.deinit(self.gpa);
        self.bridges.deinit(self.gpa);
        self.conn.close();
        self.gpa.destroy(self);
    }

    fn startWaiter(self: *App) void {
        if (c.pipe(&self.pipe) != 0) return;
        self.waiter = std.Thread.spawn(.{}, waitLoop, .{self}) catch null;
    }

    /// The helper thread: when messages arrive, wakes the loop, then waits
    /// until they are read.
    fn waitLoop(self: *App) void {
        while (true) {
            var fds = [2]c.pollfd{
                .{ .fd = self.pipe[0], .events = c.POLL.IN, .revents = 0 },
                .{ .fd = self.conn.fd, .events = c.POLL.IN, .revents = 0 },
            };
            const n: c.nfds_t = if (self.waiting.load(.acquire)) 1 else 2;
            if (c.poll(&fds, n, -1) < 0) continue;
            if (fds[0].revents != 0) {
                var b: [1]u8 = undefined;
                if (c.read(self.pipe[0], &b, 1) != 1 or b[0] == 'q') return;
                self.waiting.store(false, .release);
            } else if (n == 2 and fds[1].revents != 0) {
                self.waiting.store(true, .release);
                if (wake) |f| f();
                if (fds[1].revents & (c.POLL.HUP | c.POLL.ERR) != 0) return;
            }
        }
    }

    /// Answers the messages that have arrived.
    fn dispatch(self: *App) Error!void {
        while (try self.conn.next(0)) |r| {
            defer r.deinit(self.gpa);
            if (r.message.type == .call) self.handle(&r.message) catch |err| switch (err) {
                error.OutOfMemory, error.Disconnected => |e| return e,
                else => self.conn.replyError(&r.message, e_invalid_args, @errorName(err)) catch {},
            };
        }
        if (self.waiting.load(.acquire)) _ = c.write(self.pipe[1], "d", 1);
    }

    fn objectPath(buf: []u8, id: u32) []const u8 {
        return std.fmt.bufPrint(buf, path_prefix ++ "{d}", .{id}) catch unreachable;
    }

    fn writeRef(self: *App, w: *dbus.Writer, t: Target) void {
        var buf: [64]u8 = undefined;
        w.ref(self.conn.unique_name, switch (t) {
            .root => root_path,
            .frame => |b| objectPath(&buf, b.frame_id),
            .item => |it| objectPath(&buf, it.bridge.ids.get(it.node.item).?),
            .none => null_path,
        });
    }

    /// What a path names, if it is still there.
    fn resolve(self: *App, path: []const u8) ?Target {
        const rest = std.mem.cutPrefix(u8, path, path_prefix) orelse return null;
        if (std.mem.eql(u8, rest, "root")) return .root;
        const id = std.fmt.parseInt(u32, rest, 10) catch return null;
        const o = self.objects.get(id) orelse return null;
        const item = o.item orelse return .{ .frame = o.bridge };
        const i = o.bridge.index.get(item) orelse return null;
        return .{ .item = .{ .bridge = o.bridge, .node = o.bridge.nodes[i], .index = i } };
    }

    fn handle(self: *App, m: *const dbus.Message) !void {
        const t = self.resolve(m.path) orelse return self.conn.replyError(m, e_unknown_object, m.path);
        var w: dbus.Writer = .init(self.gpa);
        defer w.deinit();
        var r = m.reader();
        const sig: ?[]const u8 = if (std.mem.eql(u8, m.interface, i_properties))
            try self.properties(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_accessible))
            try self.accessible(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_component))
            try self.component(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_action))
            try self.action(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_text))
            try self.text(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_selection))
            try self.selection(t, m.member, &r, &w)
        else if (std.mem.eql(u8, m.interface, i_application) and std.mem.eql(u8, m.member, "GetLocale")) blk: {
            w.string("");
            break :blk "s";
        } else null;
        if (sig) |s| return self.conn.reply(m, s, try w.finish());
        return self.conn.replyError(m, e_unknown_method, m.member);
    }

    // org.freedesktop.DBus.Properties

    fn properties(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        const iface = try r.string();
        if (std.mem.eql(u8, member, "Get")) {
            const name = try r.string();
            if (!self.property(t, iface, name, w)) return error.UnknownProperty;
            return "v";
        }
        if (std.mem.eql(u8, member, "GetAll")) {
            const a = w.beginArray('{');
            for (propertyNames(iface)) |name| {
                var probe: dbus.Writer = .init(self.gpa);
                defer probe.deinit();
                if (!self.property(t, iface, name, &probe)) continue;
                w.structure();
                w.string(name);
                _ = self.property(t, iface, name, w);
            }
            w.endArray(a);
            return "a{sv}";
        }
        if (std.mem.eql(u8, member, "Set")) {
            const name = try r.string();
            const sig = try r.signature();
            if (std.mem.eql(u8, iface, i_value) and std.mem.eql(u8, name, "CurrentValue") and std.mem.eql(u8, sig, "d")) {
                const v = try r.double();
                const it = switch (t) {
                    .item => |it| it,
                    else => return error.UnknownProperty,
                };
                var buf: [32]u8 = undefined;
                _ = a11y.setValue(it.node.item, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
                return "";
            }
            if (std.mem.eql(u8, iface, i_application) and std.mem.eql(u8, name, "Id") and std.mem.eql(u8, sig, "i")) {
                self.id = try r.int32();
                return "";
            }
            return error.ReadOnlyProperty;
        }
        return null;
    }

    fn propertyNames(iface: []const u8) []const []const u8 {
        if (std.mem.eql(u8, iface, i_accessible)) return &.{ "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" };
        if (std.mem.eql(u8, iface, i_application)) return &.{ "ToolkitName", "Version", "AtspiVersion", "Id" };
        if (std.mem.eql(u8, iface, i_value)) return &.{ "MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text" };
        if (std.mem.eql(u8, iface, i_action)) return &.{"NActions"};
        if (std.mem.eql(u8, iface, i_text)) return &.{ "CharacterCount", "CaretOffset" };
        if (std.mem.eql(u8, iface, i_selection)) return &.{"NSelectedChildren"};
        return &.{};
    }

    /// Writes property `name` of `iface` as a variant; false if `t` has no
    /// such property.
    fn property(self: *App, t: Target, iface: []const u8, name: []const u8, w: *dbus.Writer) bool {
        const eql = std.mem.eql;
        if (eql(u8, iface, i_accessible)) {
            if (eql(u8, name, "Name")) {
                w.variant("s");
                w.string(t.name());
            } else if (eql(u8, name, "Description") or eql(u8, name, "HelpText")) {
                w.variant("s");
                w.string(if (t == .item) t.item.node.description else "");
            } else if (eql(u8, name, "Parent")) {
                w.variant("(so)");
                self.writeRef(w, self.parentOf(t));
            } else if (eql(u8, name, "ChildCount")) {
                w.variant("i");
                w.int32(@intCast(self.childCount(t)));
            } else if (eql(u8, name, "Locale") or eql(u8, name, "AccessibleId")) {
                w.variant("s");
                w.string("");
            } else return false;
            return true;
        }
        if (eql(u8, iface, i_application)) {
            if (t != .root) return false;
            if (eql(u8, name, "ToolkitName")) {
                w.variant("s");
                w.string("zigulee");
            } else if (eql(u8, name, "Version")) {
                w.variant("s");
                w.string("0");
            } else if (eql(u8, name, "AtspiVersion")) {
                w.variant("s");
                w.string("2.1");
            } else if (eql(u8, name, "Id")) {
                w.variant("i");
                w.int32(self.id);
            } else return false;
            return true;
        }
        const it = switch (t) {
            .item => |it| it,
            else => return false,
        };
        const n = it.node;
        if (eql(u8, iface, i_value) and hasValue(n.role)) {
            const v: f64 = if (eql(u8, name, "MinimumValue"))
                n.value_minimum
            else if (eql(u8, name, "MaximumValue"))
                n.value_maximum
            else if (eql(u8, name, "MinimumIncrement"))
                (if (n.value_step > 0) n.value_step else 1)
            else if (eql(u8, name, "CurrentValue"))
                std.fmt.parseFloat(f64, n.value) catch 0
            else if (eql(u8, name, "Text")) {
                w.variant("s");
                w.string(n.value);
                return true;
            } else return false;
            w.variant("d");
            w.double(v);
            return true;
        }
        if (eql(u8, iface, i_selection) and eql(u8, name, "NSelectedChildren") and isSelectionContainer(n.role)) {
            var kids: std.ArrayList(Target) = .empty;
            defer kids.deinit(self.gpa);
            self.children(t, &kids) catch return false;
            var count: i32 = 0;
            for (kids.items) |k| count += @intFromBool(isSelected(k));
            w.variant("i");
            w.int32(count);
            return true;
        }
        if (eql(u8, iface, i_action) and eql(u8, name, "NActions")) {
            w.variant("i");
            w.int32(@intCast(actionsOf(n.role).len));
            return true;
        }
        if (eql(u8, iface, i_text) and hasText(n.role)) {
            if (!eql(u8, name, "CharacterCount") and !eql(u8, name, "CaretOffset")) return false;
            w.variant("i");
            w.int32(@intCast(std.unicode.utf8CountCodepoints(textOf(n)) catch 0));
            return true;
        }
        return false;
    }

    fn textOf(n: a11y.Node) []const u8 {
        return if (n.role == .text_input) n.value else n.label;
    }

    fn parentOf(self: *App, t: Target) Target {
        _ = self;
        return switch (t) {
            .root, .none => .none,
            .frame => .root,
            .item => |it| if (it.node.parent) |p| .{ .item = .{ .bridge = it.bridge, .node = it.bridge.nodes[p], .index = p } } else .{ .frame = it.bridge },
        };
    }

    /// The children of `t`, in order.
    fn children(self: *App, t: Target, out: *std.ArrayList(Target)) Allocator.Error!void {
        switch (t) {
            .none => {},
            .root => for (self.bridges.items) |b| try out.append(self.gpa, .{ .frame = b }),
            .frame, .item => {
                const b = if (t == .frame) t.frame else t.item.bridge;
                const parent: ?u32 = if (t == .item) t.item.index else null;
                for (b.nodes, 0..) |n, i| if (n.parent == parent) {
                    try out.append(self.gpa, .{ .item = .{ .bridge = b, .node = n, .index = @intCast(i) } });
                };
            },
        }
    }

    fn childCount(self: *App, t: Target) usize {
        return switch (t) {
            .none => 0,
            .root => self.bridges.items.len,
            .frame, .item => blk: {
                const b = if (t == .frame) t.frame else t.item.bridge;
                const parent: ?u32 = if (t == .item) t.item.index else null;
                var count: usize = 0;
                for (b.nodes) |n| count += @intFromBool(n.parent == parent);
                break :blk count;
            },
        };
    }

    // org.a11y.atspi.Accessible

    fn accessible(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, member, "GetChildren") or eql(u8, member, "GetChildAtIndex")) {
            var kids: std.ArrayList(Target) = .empty;
            defer kids.deinit(self.gpa);
            try self.children(t, &kids);
            if (eql(u8, member, "GetChildAtIndex")) {
                const i = try r.int32();
                self.writeRef(w, if (i >= 0 and i < kids.items.len) kids.items[@intCast(i)] else .none);
                return "(so)";
            }
            const a = w.beginArray('(');
            for (kids.items) |k| self.writeRef(w, k);
            w.endArray(a);
            return "a(so)";
        }
        if (eql(u8, member, "GetIndexInParent")) {
            var kids: std.ArrayList(Target) = .empty;
            defer kids.deinit(self.gpa);
            try self.children(self.parentOf(t), &kids);
            var index: i32 = -1;
            for (kids.items, 0..) |k, i| if (k.same(t)) {
                index = @intCast(i);
            };
            w.int32(index);
            return "i";
        }
        if (eql(u8, member, "GetRole")) {
            w.uint32(@intFromEnum(t.role()));
            return "u";
        }
        if (eql(u8, member, "GetRoleName") or eql(u8, member, "GetLocalizedRoleName")) {
            w.string(t.role().name());
            return "s";
        }
        if (eql(u8, member, "GetState")) {
            const s = t.states();
            const a = w.beginArray('u');
            w.uint32(@truncate(s.bits));
            w.uint32(@truncate(s.bits >> 32));
            w.endArray(a);
            return "au";
        }
        if (eql(u8, member, "GetAttributes")) {
            const a = w.beginArray('{');
            w.structure();
            w.string("toolkit");
            w.string("zigulee");
            w.endArray(a);
            return "a{ss}";
        }
        if (eql(u8, member, "GetRelationSet")) {
            w.endArray(w.beginArray('('));
            return "a(ua(so))";
        }
        if (eql(u8, member, "GetApplication")) {
            self.writeRef(w, .root);
            return "(so)";
        }
        if (eql(u8, member, "GetInterfaces")) {
            const a = w.beginArray('s');
            w.string(i_accessible);
            switch (t) {
                .root => w.string(i_application),
                .frame => w.string(i_component),
                .item => |it| {
                    w.string(i_component);
                    if (actionsOf(it.node.role).len > 0) w.string(i_action);
                    if (hasValue(it.node.role)) w.string(i_value);
                    if (hasText(it.node.role)) w.string(i_text);
                    if (isSelectionContainer(it.node.role)) w.string(i_selection);
                },
                .none => {},
            }
            w.endArray(a);
            return "as";
        }
        return null;
    }

    // org.a11y.atspi.Selection: a list's or table's items selected (by
    // their index among its children; only those shown).

    fn selection(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        const eql = std.mem.eql;
        const it = switch (t) {
            .item => |it| it,
            else => return null,
        };
        if (!isSelectionContainer(it.node.role)) return null;
        const multiple = it.node.multiselectable;
        var kids: std.ArrayList(Target) = .empty;
        defer kids.deinit(self.gpa);
        try self.children(t, &kids);
        const child = struct {
            fn at(list: []const Target, i: i32) ?Target {
                if (i < 0 or i >= list.len or !isItem(list[@intCast(i)])) return null;
                return list[@intCast(i)];
            }
            fn isItem(k: Target) bool {
                return k == .item and isSelectionItem(k.item.node.role);
            }
            /// The `i`th of the selected ones.
            fn selected(list: []const Target, i: i32) ?Target {
                var k: i32 = 0;
                for (list) |candidate| if (isSelected(candidate)) {
                    if (k == i) return candidate;
                    k += 1;
                };
                return null;
            }
        };
        if (eql(u8, member, "GetSelectedChild")) {
            self.writeRef(w, child.selected(kids.items, try r.int32()) orelse .none);
            return "(so)";
        }
        var ok = false;
        if (eql(u8, member, "IsChildSelected")) {
            ok = if (child.at(kids.items, try r.int32())) |k| isSelected(k) else false;
        } else if (eql(u8, member, "SelectChild")) {
            if (child.at(kids.items, try r.int32())) |k| {
                const item = k.item.node.item;
                ok = isSelected(k) or (multiple and a11y.setSelected(item, true)) or a11y.perform(it.bridge.ui, item, .select);
            }
        } else if (eql(u8, member, "DeselectChild")) {
            if (child.at(kids.items, try r.int32())) |k| ok = !isSelected(k) or a11y.setSelected(k.item.node.item, false);
        } else if (eql(u8, member, "DeselectSelectedChild")) {
            if (child.selected(kids.items, try r.int32())) |k| ok = a11y.setSelected(k.item.node.item, false);
        } else if (eql(u8, member, "SelectAll")) {
            ok = multiple;
            if (multiple) for (kids.items) |k| {
                if (child.isItem(k) and !isSelected(k)) ok = a11y.setSelected(k.item.node.item, true) and ok;
            };
        } else if (eql(u8, member, "ClearSelection")) {
            ok = true;
            for (kids.items) |k| if (isSelected(k)) {
                ok = a11y.setSelected(k.item.node.item, false) and ok;
            };
        } else return null;
        w.boolean(ok);
        return "b";
    }

    // org.a11y.atspi.Component

    fn component(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        const eql = std.mem.eql;
        if (t == .root or t == .none) return null;
        if (eql(u8, member, "GetExtents") or eql(u8, member, "GetPosition")) {
            const e = t.extents(try r.uint32());
            w.structure();
            w.int32(e[0]);
            w.int32(e[1]);
            if (eql(u8, member, "GetPosition")) return "(ii)";
            w.int32(e[2]);
            w.int32(e[3]);
            return "(iiii)";
        }
        if (eql(u8, member, "GetSize")) {
            const e = t.extents(1);
            w.structure();
            w.int32(e[2]);
            w.int32(e[3]);
            return "(ii)";
        }
        if (eql(u8, member, "Contains") or eql(u8, member, "GetAccessibleAtPoint")) {
            const x = try r.int32();
            const y = try r.int32();
            const coords = try r.uint32();
            if (eql(u8, member, "Contains")) {
                w.boolean(inside(t.extents(coords), x, y));
                return "b";
            }
            // The innermost item at the point, within `t`.
            const b = if (t == .frame) t.frame else t.item.bridge;
            var found: Target = .none;
            for (b.nodes, 0..) |n, i| {
                const candidate: Target = .{ .item = .{ .bridge = b, .node = n, .index = @intCast(i) } };
                if (inside(candidate.extents(coords), x, y) and (t == .frame or b.isWithin(@intCast(i), t.item.index))) found = candidate;
            }
            self.writeRef(w, found);
            return "(so)";
        }
        if (eql(u8, member, "GetLayer")) {
            w.uint32(if (t == .frame) 7 else 3); // window, widget
            return "u";
        }
        if (eql(u8, member, "GetMDIZOrder")) {
            w.int16(0);
            return "n";
        }
        if (eql(u8, member, "GetAlpha")) {
            w.double(1);
            return "d";
        }
        if (eql(u8, member, "GrabFocus")) {
            w.boolean(if (t == .item) a11y.perform(t.item.bridge.ui, t.item.node.item, .focus) else false);
            return "b";
        }
        return null;
    }

    fn inside(e: [4]i32, x: i32, y: i32) bool {
        return x >= e[0] and y >= e[1] and x < e[0] + e[2] and y < e[1] + e[3];
    }

    // org.a11y.atspi.Action

    fn action(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        _ = self;
        const eql = std.mem.eql;
        const it = switch (t) {
            .item => |it| it,
            else => return null,
        };
        const actions = actionsOf(it.node.role);
        if (eql(u8, member, "GetActions")) {
            const a = w.beginArray('(');
            for (actions) |act| {
                w.structure();
                w.string(act[0]);
                w.string("");
                w.string("");
            }
            w.endArray(a);
            return "a(sss)";
        }
        const i = try r.int32();
        const act = if (i >= 0 and i < actions.len) actions[@intCast(i)] else return error.NoSuchAction;
        if (eql(u8, member, "DoAction")) {
            w.boolean(a11y.perform(it.bridge.ui, it.node.item, act[1]));
            return "b";
        }
        if (eql(u8, member, "GetName") or eql(u8, member, "GetLocalizedName")) {
            w.string(act[0]);
            return "s";
        }
        if (eql(u8, member, "GetDescription") or eql(u8, member, "GetKeyBinding")) {
            w.string("");
            return "s";
        }
        return null;
    }

    // org.a11y.atspi.Text (enough to read it)

    fn text(self: *App, t: Target, member: []const u8, r: *dbus.Reader, w: *dbus.Writer) !?[]const u8 {
        _ = self;
        const it = switch (t) {
            .item => |it| if (hasText(it.node.role)) it else return null,
            else => return null,
        };
        if (!std.mem.eql(u8, member, "GetText")) return null;
        const s = textOf(it.node);
        const start = try r.int32();
        const end = try r.int32();
        // Offsets are in characters; -1: the end.
        var view = std.unicode.Utf8View.init(s) catch return error.BadText;
        var cps = view.iterator();
        var i: i32 = 0;
        var from: usize = s.len;
        var to: usize = s.len;
        while (true) : (i += 1) {
            const at = cps.i;
            if (i == @max(start, 0)) from = at;
            if (end >= 0 and i == end) {
                to = at;
                break;
            }
            if (cps.nextCodepointSlice() == null) break;
        }
        w.string(s[@min(from, to)..to]);
        return "s";
    }

    // Events (org.a11y.atspi.Event.*), signature siiva{sv}.

    fn event(self: *App, t: Target, iface: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, data: EventData) void {
        var w: dbus.Writer = .init(self.gpa);
        defer w.deinit();
        w.string(detail);
        w.int32(d1);
        w.int32(d2);
        switch (data) {
            .none => {
                w.variant("i");
                w.int32(0);
            },
            .text => |s| {
                w.variant("s");
                w.string(s);
            },
            .number => |v| {
                w.variant("d");
                w.double(v);
            },
            .ref => |o| {
                w.variant("(so)");
                self.writeRef(&w, o);
            },
        }
        w.endArray(w.beginArray('{'));
        var buf: [64]u8 = undefined;
        const path = switch (t) {
            .root => root_path,
            .frame => |b| objectPath(&buf, b.frame_id),
            .item => |it| objectPath(&buf, it.bridge.ids.get(it.node.item).?),
            .none => return,
        };
        const body = w.finish() catch return;
        _ = self.conn.send(.{ .type = .signal, .path = path, .interface = iface, .member = member, .signature = "siiva{sv}", .body = body }) catch |err|
            log.info("event not sent: {t}", .{err});
    }
};

const EventData = union(enum) { none, text: []const u8, number: f64, ref: Target };

/// An object, resolved.
const Target = union(enum) {
    /// The application.
    root,
    /// A window.
    frame: *Bridge,
    item: struct { bridge: *Bridge, node: a11y.Node, index: u32 },
    /// The null object.
    none,

    fn same(a: Target, b: Target) bool {
        return switch (a) {
            .root => b == .root,
            .none => b == .none,
            .frame => |f| b == .frame and b.frame == f,
            .item => |it| b == .item and b.item.node.item == it.node.item,
        };
    }

    fn name(t: Target) []const u8 {
        return switch (t) {
            .root => if (app) |a| (if (a.bridges.items.len > 0) a.bridges.items[0].title else "") else "",
            .frame => |b| b.title,
            .item => |it| it.node.label,
            .none => "",
        };
    }

    fn role(t: Target) Role {
        return switch (t) {
            .root => .application,
            .frame => .frame,
            .item => |it| roleOf(it.node.role),
            .none => .panel,
        };
    }

    fn states(t: Target) States {
        var s: States = .{};
        switch (t) {
            .root, .none => {},
            .frame => |b| {
                inline for (.{ .enabled, .sensitive, .showing, .visible, .resizable }) |st| s.set(st);
                if (b.active) s.set(.active);
            },
            .item => |it| {
                const n = it.node;
                s.set(.showing);
                s.set(.visible);
                if (n.enabled) {
                    s.set(.enabled);
                    s.set(.sensitive);
                }
                if (actionsOf(n.role).len > 0 or n.role == .text_input) s.set(.focusable);
                if (n.focused and it.bridge.active) s.set(.focused);
                if (n.checkable) s.set(.checkable);
                if (n.multiselectable and isSelectionContainer(n.role)) s.set(.multiselectable);
                if (isSelectable(n.role)) {
                    // A list's or table's row, a tab: selected, not checked.
                    s.set(.selectable);
                    if (n.checked) s.set(.selected);
                } else if (n.checked) s.set(.checked);
                if (n.role == .text_input) {
                    s.set(.editable);
                    s.set(.single_line);
                }
                if (n.role == .progress_indicator) s.set(.read_only);
            },
        }
        return s;
    }

    /// x, y, width, height in `coords`: 0 the screen, 1 the window, 2 the
    /// parent.
    fn extents(t: Target, coords: u32) [4]i32 {
        switch (t) {
            .root, .none => return .{ 0, 0, 0, 0 },
            .frame => |b| {
                const at: [2]i32 = if (coords == 0) b.position else .{ 0, 0 };
                const size = b.ui.size();
                return .{ at[0], at[1], @intFromFloat(@round(size.width * b.scale)), @intFromFloat(@round(size.height * b.scale)) };
            },
            .item => |it| {
                const b = it.bridge;
                var r = it.node.bounds;
                if (coords == 2) if (it.node.parent) |p| {
                    r.x -= b.nodes[p].bounds.x;
                    r.y -= b.nodes[p].bounds.y;
                };
                const at: [2]i32 = if (coords == 0) b.position else .{ 0, 0 };
                return .{
                    at[0] + @as(i32, @intFromFloat(@round(r.x * b.scale))),
                    at[1] + @as(i32, @intFromFloat(@round(r.y * b.scale))),
                    @intFromFloat(@round(r.width * b.scale)),
                    @intFromFloat(@round(r.height * b.scale)),
                };
            },
        }
    }
};

var app: ?*App = null;

/// The accessibility bus's address: `AT_SPI_BUS_ADDRESS`, or the one the
/// session bus gives (org.a11y.Bus, which starts it if needed).
fn busAddress(gpa: Allocator) Error![]u8 {
    if (c.getenv("AT_SPI_BUS_ADDRESS")) |a| return gpa.dupe(u8, std.mem.span(a));
    const session = dbus.sessionBusAddress() orelse return error.ConnectFailed;
    const conn = try dbus.Connection.open(gpa, session);
    defer conn.close();
    const r = try conn.callOk(.{ .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = "org.a11y.Bus", .member = "GetAddress" }, "", "");
    defer r.deinit(gpa);
    var body = r.message.reader();
    return gpa.dupe(u8, body.string() catch return error.BadMessage);
}

// ---- The bridge (one per window) ----

pub const Options = struct {
    /// The bus to use instead of the accessibility bus (tests).
    address: ?[]const u8 = null,
};

pub const Bridge = struct {
    gpa: Allocator,
    ui: *core.Window,
    tracker: a11y.Tracker,
    nodes: []const a11y.Node = &.{},
    index: std.AutoHashMapUnmanaged(*core.Item, u32) = .empty,
    /// The object id of each item.
    ids: std.AutoHashMapUnmanaged(*core.Item, u32) = .empty,
    frame_id: u32,
    focused: ?*core.Item = null,
    updated: bool = false,
    /// Set by the backend: the window's title, its position on screen
    /// (physical pixels) and scale, and whether it has the keyboard focus.
    title: []const u8 = "",
    position: [2]i32 = .{ 0, 0 },
    scale: f32 = 1,
    active: bool = false,

    /// Shows `ui`'s accessible items to screen readers. Call `update` from
    /// the event loop. `ui` must outlive the bridge. Fails if there is no
    /// accessibility bus.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Bridge {
        if (app == null) {
            const address = if (options.address) |a| try gpa.dupe(u8, a) else try busAddress(gpa);
            defer gpa.free(address);
            app = try App.open(gpa, address);
        }
        const a = app.?;
        errdefer if (a.bridges.items.len == 0) {
            a.close();
            app = null;
        };
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .tracker = .init(gpa, ui), .frame_id = a.next_id };
        try a.objects.put(a.gpa, a.next_id, .{ .bridge = self, .item = null });
        a.next_id += 1;
        try a.bridges.append(a.gpa, self);
        a.event(.root, "org.a11y.atspi.Event.Object", "ChildrenChanged", "add", @intCast(a.bridges.items.len - 1), 0, .{ .ref = .{ .frame = self } });
        return self;
    }

    pub fn destroy(self: *Bridge) void {
        const a = app.?;
        a.event(.root, "org.a11y.atspi.Event.Object", "ChildrenChanged", "remove", -1, 0, .{ .ref = .{ .frame = self } });
        _ = a.objects.remove(self.frame_id);
        var it = self.ids.valueIterator();
        while (it.next()) |id| _ = a.objects.remove(id.*);
        for (a.bridges.items, 0..) |b, i| if (b == self) {
            _ = a.bridges.orderedRemove(i);
            break;
        };
        if (a.bridges.items.len == 0) {
            a.close();
            app = null;
        }
        self.ids.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.tracker.deinit();
        self.gpa.destroy(self);
    }

    /// Whether item `i` is `ancestor` or inside it.
    fn isWithin(self: *const Bridge, i: u32, ancestor: u32) bool {
        var at: ?u32 = i;
        while (at) |j| : (at = self.nodes[j].parent) if (j == ancestor) return true;
        return false;
    }

    /// The window got or lost the keyboard focus.
    pub fn setActive(self: *Bridge, active: bool) void {
        if (active == self.active) return;
        self.active = active;
        const a = app orelse return;
        a.event(.{ .frame = self }, "org.a11y.atspi.Event.Window", if (active) "Activate" else "Deactivate", "", 0, 0, .none);
        a.event(.{ .frame = self }, "org.a11y.atspi.Event.Object", "StateChanged", "active", @intFromBool(active), 0, .none);
        if (self.focused) |f| if (self.index.get(f)) |i|
            a.event(.{ .item = .{ .bridge = self, .node = self.nodes[i], .index = i } }, "org.a11y.atspi.Event.Object", "StateChanged", "focused", @intFromBool(active), 0, .none);
    }

    /// Answers what screen readers asked, takes a new snapshot if anything
    /// changed, and tells them what did.
    pub fn update(self: *Bridge) Error!void {
        const a = app.?;
        a.dispatch() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => log.info("accessibility bus: {t}", .{err}),
        };
        if (!self.tracker.isDirty() and self.updated) return;
        self.updated = true;

        var old: std.AutoHashMapUnmanaged(*core.Item, struct { u64, u64, bool }) = .empty;
        defer old.deinit(self.gpa);
        for (self.nodes) |n| try old.put(self.gpa, n.item, .{ std.hash.Wyhash.hash(0, n.value), std.hash.Wyhash.hash(0, n.label), n.checked });

        self.nodes = try self.tracker.update();
        self.index.clearRetainingCapacity();
        for (self.nodes, 0..) |n, i| try self.index.put(self.gpa, n.item, @intCast(i));

        // Ids of items that are gone, and new ones.
        var stale: std.ArrayList(*core.Item) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.ids.iterator();
        while (it.next()) |e| if (!self.index.contains(e.key_ptr.*)) try stale.append(self.gpa, e.key_ptr.*);
        for (stale.items) |item| {
            const id = self.ids.fetchRemove(item).?.value;
            _ = a.objects.remove(id);
            a.event(.{ .frame = self }, "org.a11y.atspi.Event.Object", "ChildrenChanged", "remove", -1, 0, .none);
        }
        try a.objects.ensureUnusedCapacity(a.gpa, @intCast(self.nodes.len));
        for (self.nodes, 0..) |n, i| {
            const gop = try self.ids.getOrPut(self.gpa, n.item);
            if (gop.found_existing) continue;
            gop.value_ptr.* = a.next_id;
            a.objects.putAssumeCapacity(a.next_id, .{ .bridge = self, .item = n.item });
            a.next_id += 1;
            if (self.nodes.len > 0 and old.count() > 0) {
                const t: Target = .{ .item = .{ .bridge = self, .node = n, .index = @intCast(i) } };
                a.event(a.parentOf(t), "org.a11y.atspi.Event.Object", "ChildrenChanged", "add", -1, 0, .{ .ref = t });
            }
        }

        // Lists and tables whose selection changed (told once each).
        var reselected: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        defer reselected.deinit(self.gpa);
        for (self.nodes, 0..) |n, i| {
            const before = old.get(n.item) orelse continue;
            const t: Target = .{ .item = .{ .bridge = self, .node = n, .index = @intCast(i) } };
            if (before[1] != std.hash.Wyhash.hash(0, n.label))
                a.event(t, "org.a11y.atspi.Event.Object", "PropertyChange", "accessible-name", 0, 0, .{ .text = n.label });
            if (before[0] != std.hash.Wyhash.hash(0, n.value)) {
                if (hasValue(n.role))
                    a.event(t, "org.a11y.atspi.Event.Object", "PropertyChange", "accessible-value", 0, 0, .{ .number = std.fmt.parseFloat(f64, n.value) catch 0 })
                else if (hasText(n.role))
                    a.event(t, "org.a11y.atspi.Event.Object", "TextChanged", "insert", 0, @intCast(std.unicode.utf8CountCodepoints(n.value) catch 0), .{ .text = n.value });
            }
            if (before[2] != n.checked and isSelectable(n.role)) {
                a.event(t, "org.a11y.atspi.Event.Object", "StateChanged", "selected", @intFromBool(n.checked), 0, .none);
                if (isSelectionItem(n.role)) if (n.parent) |p| if (isSelectionContainer(self.nodes[p].role)) try reselected.put(self.gpa, p, {});
            }
        }
        for (reselected.keys()) |p|
            a.event(.{ .item = .{ .bridge = self, .node = self.nodes[p], .index = p } }, "org.a11y.atspi.Event.Object", "SelectionChanged", "", 0, 0, .none);
        var focused: ?*core.Item = null;
        for (self.nodes) |n| if (n.focused) {
            focused = n.item;
        };
        if (focused != self.focused) {
            if (self.focused) |f| if (self.index.get(f)) |i|
                a.event(.{ .item = .{ .bridge = self, .node = self.nodes[i], .index = i } }, "org.a11y.atspi.Event.Object", "StateChanged", "focused", 0, 0, .none);
            self.focused = focused;
            if (focused) |f| {
                const i = self.index.get(f).?;
                a.event(.{ .item = .{ .bridge = self, .node = self.nodes[i], .index = i } }, "org.a11y.atspi.Event.Object", "StateChanged", "focused", 1, 0, .none);
            }
        }
    }
};

// ---- Tests (on a session bus: run them in `dbus-run-session`) ----

const testing = std.testing;

const TestUi = struct {
    ui: core.Window,
    button: core.items.Rectangle = .{},
    check: core.items.Rectangle = .{},
    slider: core.items.Rectangle = .{},
    button_props: core.AccessibleProperties = .{},
    check_props: core.AccessibleProperties = .{},
    slider_props: core.AccessibleProperties = .{},
    pressed: u32 = 0,
    set_to: [16]u8 = undefined,
    set_len: usize = 0,

    fn init(self: *TestUi) void {
        self.* = .{ .ui = undefined };
        self.ui.init(testing.allocator, .{ .width = 300, .height = 100 });
        const root = self.ui.rootItem();
        for ([_]*core.items.Rectangle{ &self.button, &self.check, &self.slider }, 0..) |r, i| {
            root.appendChild(&r.item);
            r.item.setGeometry(.{ .x = 10 + 100 * @as(f32, @floatFromInt(i)), .y = 20, .width = 80, .height = 30 });
        }
        self.button.item.accessible = &self.button_props;
        self.button_props.role.set(.button);
        self.button_props.label.set("OK");
        self.button_props.action_default.setHandler(&self.pressed, struct {
            fn f(n: *u32) void {
                n.* += 1;
            }
        }.f);
        self.check.item.accessible = &self.check_props;
        self.check_props.role.set(.checkbox);
        self.check_props.label.set("Remember");
        self.check_props.checkable.set(true);
        self.check_props.checked.set(true);
        self.slider.item.accessible = &self.slider_props;
        self.slider_props.role.set(.slider);
        self.slider_props.label.set("Volume");
        self.slider_props.value.set("2");
        self.slider_props.value_maximum.set(10);
        self.slider_props.action_set_value.setHandler(self, struct {
            fn f(t: *TestUi, v: []const u8) void {
                @memcpy(t.set_to[0..v.len], v);
                t.set_len = v.len;
            }
        }.f);
    }

    fn deinit(self: *TestUi) void {
        inline for (.{ "button", "check", "slider" }) |name| {
            @field(self, name ++ "_props").deinit();
            @field(self, name).deinit();
        }
        self.ui.deinit();
    }
};

/// A client on the bus, asking the application (answered by `bridge`).
const Client = struct {
    conn: *dbus.Connection,
    bridge: *Bridge,

    fn ask(self: Client, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !dbus.Received {
        const serial = try self.conn.send(.{ .type = .call, .destination = app.?.conn.unique_name, .path = path, .interface = iface, .member = member, .signature = sig, .body = body });
        for (0..500) |_| {
            try self.bridge.update();
            while (try self.conn.next(10)) |r| {
                if (r.message.reply_serial == serial and (r.message.type == .reply or r.message.type == .err)) return r;
                r.deinit(testing.allocator);
            }
        }
        return error.Timeout;
    }

    fn property(self: Client, path: []const u8, iface: []const u8, name: []const u8) !dbus.Received {
        var w: dbus.Writer = .init(testing.allocator);
        defer w.deinit();
        w.string(iface);
        w.string(name);
        return self.ask(path, i_properties, "Get", "ss", try w.finish());
    }

    fn children(self: Client, path: []const u8, out: *std.ArrayList([]const u8)) !dbus.Received {
        const r = try self.ask(path, i_accessible, "GetChildren", "", "");
        var body = r.message.reader();
        const end = try body.array('(');
        while (body.pos < end) {
            try body.structure();
            _ = try body.string();
            try out.append(testing.allocator, try body.string());
        }
        return r;
    }
};

test "a window's items as AT-SPI objects, with actions" {
    const address = dbus.sessionBusAddress() orelse {
        log.info("no session bus (DBUS_SESSION_BUS_ADDRESS): skipped", .{});
        return error.SkipZigTest;
    };
    var t: TestUi = undefined;
    t.init();
    defer t.deinit();
    const bridge = try Bridge.create(testing.allocator, &t.ui, .{ .address = address });
    defer bridge.destroy();
    bridge.title = "Test window";
    try bridge.update();
    const conn = try dbus.Connection.open(testing.allocator, address);
    defer conn.close();
    const client: Client = .{ .conn = conn, .bridge = bridge };

    // The application, its window, the window's items.
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(testing.allocator);
    const r1 = try client.children(root_path, &frames);
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(testing.allocator);
    const r2 = try client.children(frames.items[0], &items);
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), items.items.len);

    {
        const r = try client.property(frames.items[0], i_accessible, "Name");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        try testing.expectEqualStrings("s", try body.signature());
        try testing.expectEqualStrings("Test window", try body.string());
    }
    {
        const r = try client.property(items.items[0], i_accessible, "Name");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        _ = try body.signature();
        try testing.expectEqualStrings("OK", try body.string());
    }
    {
        const r = try client.ask(items.items[0], i_accessible, "GetRole", "", "");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        try testing.expectEqual(@intFromEnum(Role.push_button), try body.uint32());
    }
    {
        // The check box: checked.
        const r = try client.ask(items.items[1], i_accessible, "GetState", "", "");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        _ = try body.array('u');
        const low = try body.uint32();
        try testing.expect(low & (1 << @intFromEnum(State.checked)) != 0);
        try testing.expect(low & (1 << @intFromEnum(State.enabled)) != 0);
    }
    {
        // Where the button is in the window.
        var w: dbus.Writer = .init(testing.allocator);
        defer w.deinit();
        w.uint32(1);
        const r = try client.ask(items.items[0], i_component, "GetExtents", "u", try w.finish());
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        try body.structure();
        try testing.expectEqual(@as(i32, 10), try body.int32());
        try testing.expectEqual(@as(i32, 20), try body.int32());
        try testing.expectEqual(@as(i32, 80), try body.int32());
        try testing.expectEqual(@as(i32, 30), try body.int32());
    }
    {
        // Pressing the button.
        var w: dbus.Writer = .init(testing.allocator);
        defer w.deinit();
        w.int32(0);
        const r = try client.ask(items.items[0], i_action, "DoAction", "i", try w.finish());
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        try testing.expect(try body.boolean());
        try testing.expectEqual(@as(u32, 1), t.pressed);
    }
    {
        // The slider's value, and setting it.
        const r = try client.property(items.items[2], i_value, "CurrentValue");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        try testing.expectEqualStrings("d", try body.signature());
        try testing.expectEqual(@as(f64, 2), try body.double());
        var w: dbus.Writer = .init(testing.allocator);
        defer w.deinit();
        w.string(i_value);
        w.string("CurrentValue");
        w.variant("d");
        w.double(3);
        const s = try client.ask(items.items[2], i_properties, "Set", "ssv", try w.finish());
        defer s.deinit(testing.allocator);
        try testing.expectEqual(dbus.Type.reply, s.message.type);
        try testing.expectEqualStrings("3", t.set_to[0..t.set_len]);
    }
    {
        // An item that is gone: its object too.
        t.check_props.role.set(.unset);
        try bridge.update();
        const r = try client.ask(items.items[1], i_accessible, "GetRole", "", "");
        defer r.deinit(testing.allocator);
        try testing.expectEqual(dbus.Type.err, r.message.type);
        try testing.expectEqualStrings(e_unknown_object, r.message.error_name);
    }
}

test {
    _ = dbus;
    _ = portal;
    _ = notifications;
    _ = openuri;
}

/// A list of two items, several selectable.
const ListUi = struct {
    ui: core.Window,
    list: core.items.Rectangle = .{},
    rows: [2]core.items.Rectangle = .{ .{}, .{} },
    list_props: core.AccessibleProperties = .{},
    row_props: [2]core.AccessibleProperties = .{ .{}, .{} },

    fn init(self: *ListUi) void {
        self.* = .{ .ui = undefined };
        self.ui.init(testing.allocator, .{ .width = 200, .height = 100 });
        self.ui.rootItem().appendChild(&self.list.item);
        self.list.item.setGeometry(.{ .width = 200, .height = 100 });
        self.list.item.accessible = &self.list_props;
        self.list_props.role.set(.list);
        self.list_props.multiselectable.set(true);
        for (&self.rows, &self.row_props, 0..) |*row, *props, i| {
            self.list.item.appendChild(&row.item);
            row.item.setGeometry(.{ .y = @floatFromInt(i * 30), .width = 200, .height = 30 });
            row.item.accessible = props;
            props.role.set(.list_item);
            props.label.set(if (i == 0) "Ada" else "Grace");
            props.action_set_selected.setHandler(props, setSelected);
        }
    }

    fn setSelected(props: *core.AccessibleProperties, on: bool) void {
        props.checked.set(on);
    }

    fn deinit(self: *ListUi) void {
        for (&self.row_props) |*p| p.deinit();
        for (&self.rows) |*r| r.deinit();
        self.list_props.deinit();
        self.list.deinit();
        self.ui.deinit();
    }
};

test "a list's items selected through AT-SPI" {
    const address = dbus.sessionBusAddress() orelse {
        log.info("no session bus (DBUS_SESSION_BUS_ADDRESS): skipped", .{});
        return error.SkipZigTest;
    };
    var t: ListUi = undefined;
    t.init();
    defer t.deinit();
    const bridge = try Bridge.create(testing.allocator, &t.ui, .{ .address = address });
    defer bridge.destroy();
    try bridge.update();
    const conn = try dbus.Connection.open(testing.allocator, address);
    defer conn.close();
    const client: Client = .{ .conn = conn, .bridge = bridge };

    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(testing.allocator);
    const r1 = try client.children(root_path, &frames);
    defer r1.deinit(testing.allocator);
    var lists: std.ArrayList([]const u8) = .empty;
    defer lists.deinit(testing.allocator);
    const r2 = try client.children(frames.items[0], &lists);
    defer r2.deinit(testing.allocator);
    const list = lists.items[0];

    const call = struct {
        fn f(asker: Client, path: []const u8, member: []const u8, index: ?i32) !bool {
            var w: dbus.Writer = .init(testing.allocator);
            defer w.deinit();
            if (index) |i| w.int32(i);
            const r = try asker.ask(path, i_selection, member, if (index != null) "i" else "", try w.finish());
            defer r.deinit(testing.allocator);
            var body = r.message.reader();
            return body.boolean();
        }
        fn count(asker: Client, path: []const u8) !i32 {
            const r = try asker.property(path, i_selection, "NSelectedChildren");
            defer r.deinit(testing.allocator);
            var body = r.message.reader();
            _ = try body.signature();
            return body.int32();
        }
    };
    {
        // Several selectable.
        const r = try client.ask(list, i_accessible, "GetState", "", "");
        defer r.deinit(testing.allocator);
        var body = r.message.reader();
        _ = try body.array('u');
        try testing.expect(try body.uint32() & (1 << @intFromEnum(State.multiselectable)) != 0);
    }
    try testing.expect(try call.f(client, list, "SelectChild", 0));
    try testing.expect(try call.f(client, list, "SelectChild", 1));
    try testing.expectEqual(@as(i32, 2), try call.count(client, list));
    try testing.expect(try call.f(client, list, "DeselectSelectedChild", 0)); // Ada
    try testing.expect(!try call.f(client, list, "IsChildSelected", 0));
    try testing.expect(try call.f(client, list, "IsChildSelected", 1));
    try testing.expect(try call.f(client, list, "SelectAll", null));
    try testing.expectEqual(@as(i32, 2), try call.count(client, list));
    try testing.expect(try call.f(client, list, "ClearSelection", null));
    try testing.expectEqual(@as(i32, 0), try call.count(client, list));
    try testing.expect(t.row_props[0].checked.get() == false and t.row_props[1].checked.get() == false);
}
