// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! What the macOS and iOS backends share (`zigulee-apple`): the Objective-C
//! runtime, the GPU renderer on Metal, sound with CoreAudio, video with
//! AVFoundation, web views with WebKit and the position with Core Location.

pub const objc = @import("objc.zig");
/// The GPU renderer on Metal.
pub const metal = @import("metal.zig");
/// Sound: the mixer's output on CoreAudio.
pub const coreaudio = @import("coreaudio.zig");
/// Video: MP4, QuickTime, ... decoded by AVFoundation.
pub const avfoundation = @import("avfoundation.zig");
/// Web views: WKWebView.
pub const webview = @import("webview.zig");
/// The position: Core Location.
pub const location = @import("location.zig");

test {
    _ = objc;
    _ = metal;
    _ = coreaudio;
    _ = avfoundation;
    _ = webview;
    _ = location;
}
