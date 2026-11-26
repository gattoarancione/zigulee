// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The UI clock. The core never reads a platform clock itself (bare-metal
//! targets have none): the event loop advances it once per iteration via
//! `updateTimersAndAnimations(now_ms)`. Animations read it as a property, so
//! they are invalidated whenever time advances.

const properties = @import("properties.zig");

/// Milliseconds on the event loop's monotonic clock.
threadlocal var tick: properties.Property(u64) = .init(0);

/// Current time in milliseconds, without registering a dependency.
pub fn now() u64 {
    return tick.getUntracked();
}

/// Makes the binding being evaluated depend on the clock, so it re-evaluates
/// every time the clock advances.
pub fn track() void {
    _ = tick.get();
}

/// Advances the clock. Going backwards is ignored: the clock is monotonic.
pub fn advanceTo(now_ms: u64) void {
    if (now_ms > tick.getUntracked()) tick.set(now_ms);
}

/// True while something (typically a running animation) depends on the
/// clock. The event loop keeps requesting frames while this holds.
pub fn hasActiveAnimations() bool {
    return tick.base.dependents != null;
}
