// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The `.zge` interpreter as a module (used by zigulee-viewer): runs `.zge`
//! programs without compiling Zig. See interpreter/interpreter.zig.

const std = @import("std");
const zigulee = @import("zigulee");
const interpreter = @import("interpreter/interpreter.zig");
pub const Program = interpreter.Program;
pub const Instance = interpreter.Instance;
pub const Value = interpreter.Value;
pub const ElementRef = interpreter.ElementRef;
pub const Inspect = interpreter.Inspect;
pub const PropertyInfo = interpreter.PropertyInfo;
pub const PropRef = @import("interpreter/reflect.zig").PropRef;
pub const DynHandler = @import("interpreter/reflect.zig").DynHandler;
/// The zero value of a type (`""`, `0`, ...).
pub const defaultValue = @import("interpreter/value.zig").defaultValue;
pub const compiler = @import("compiler/compiler.zig");
/// For tools that run code being edited (the preview, the viewer): a
/// binding loop logs a warning instead of aborting, and the read in the
/// loop yields the property's previous value.
pub fn warnOnBindingLoops() void {
    zigulee.core.setBindingLoopHandler(struct {
        var count: u32 = 0;
        fn warn() void {
            // Loops repeat on every update: warn now and then.
            if (count % 1000 == 0) std.log.warn("binding loop: a property's binding depends on itself", .{});
            count +%= 1;
        }
    }.warn);
}

/// Fuzz targets, for tools/fuzz.zig.
pub const fuzz_targets = @import("interpreter/fuzz_test.zig");

test {
    _ = @import("interpreter/value.zig");
    _ = @import("interpreter/reflect.zig");
    _ = @import("interpreter/models.zig");
    _ = interpreter;
    _ = @import("interpreter/interpreter_test.zig");
    _ = @import("interpreter/fuzz_test.zig");
}
