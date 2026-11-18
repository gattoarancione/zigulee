// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The iOS backend (`zigulee-ios`): windows with UIKit on iPhone, iPad, the
//! simulator and Mac (Catalyst), sound with CoreAudio, video with
//! AVFoundation, and VoiceOver support.

/// The Objective-C runtime, for calling UIKit from apps.
pub const objc = @import("zigulee-apple").objc;
pub const uikit = @import("uikit.zig");
pub const accessibility = @import("accessibility.zig");

pub const start = uikit.start;
pub const init = uikit.init;
pub const deinit = uikit.deinit;
pub const step = uikit.step;
pub const runAll = uikit.runAll;
pub const now = uikit.now;
pub const Window = uikit.Window;
pub const Options = uikit.Options;
pub const RendererKind = uikit.RendererKind;
pub const Error = uikit.Error;

test {
    _ = uikit;
    _ = accessibility;
}
