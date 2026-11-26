// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! zigulee: a declarative GUI framework for Zig, in the spirit of Slint.
//! See ROADMAP.md for the plan and current status.

pub const core = @import("core/core.zig");
pub const software = @import("renderers/software/software.zig");
pub const gpu = @import("renderers/gpu/gpu.zig");

pub const Property = core.Property;
pub const Callback = core.Callback;
pub const Model = core.Model;
pub const VecModel = core.VecModel;
pub const ChangeTracker = core.ChangeTracker;
pub const PropertyTracker = core.PropertyTracker;
pub const runChangeHandlers = core.runChangeHandlers;
pub const Animation = core.Animation;
pub const Easing = core.Easing;
pub const Timer = core.Timer;
/// Names the application: its settings and folders go by it.
pub const setApplicationName = core.paths.setApplicationName;
pub const updateTimersAndAnimations = core.updateTimersAndAnimations;
pub const hasActiveAnimations = core.hasActiveAnimations;
pub const nextTimerDeadline = core.nextTimerDeadline;
pub const Window = core.Window;
pub const Item = core.Item;
pub const items = core.items;
pub const Color = core.Color;
pub const Brush = core.Brush;
pub const Font = core.Font;

test {
    _ = core;
    _ = software;
    _ = gpu;
}
