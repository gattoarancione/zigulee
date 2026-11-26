// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The native macOS backend (`zigulee-macos`): windows with AppKit, sound
//! with CoreAudio, video, camera and microphone with AVFoundation, the
//! position with Core Location, and
//! VoiceOver support (also used by the SDL3 backend on
//! macOS).

const apple = @import("zigulee-apple");
pub const objc = apple.objc;
pub const accessibility = @import("accessibility.zig");
pub const cocoa = @import("cocoa.zig");
/// The GPU renderer on Metal.
pub const metal = apple.metal;
/// Sound: the mixer's output on CoreAudio.
pub const coreaudio = apple.coreaudio;
/// Video: MP4, QuickTime, ... decoded by AVFoundation.
pub const avfoundation = apple.avfoundation;
/// File dialogs: NSOpenPanel, NSSavePanel.
pub const filedialog = @import("filedialog.zig");
/// The menu bar at the top of the screen.
pub const menubar = @import("menubar.zig");
/// Status items for tray icons, and notifications.
pub const tray = @import("tray.zig");
/// The microphone and the camera with AVFoundation.
pub const capture = @import("capture.zig");
/// Web views: WKWebView.
pub const webview = apple.webview;

pub const init = cocoa.init;
pub const deinit = cocoa.deinit;
pub const step = cocoa.step;
pub const runAll = cocoa.runAll;
pub const now = cocoa.now;
pub const Window = cocoa.Window;
pub const Options = cocoa.Options;
pub const RendererKind = cocoa.RendererKind;
pub const Error = cocoa.Error;

test {
    _ = accessibility;
    _ = cocoa;
    _ = filedialog;
    _ = menubar;
    _ = tray;
    _ = capture;
}
