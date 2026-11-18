// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The native Windows backend (`zigulee-windows`): windows with Win32,
//! drawn with Direct3D 12 or the software renderer, sound with WASAPI,
//! video with Media Foundation, and UI Automation for screen readers.

pub const win32 = @import("win32.zig");
/// Sound: the mixer's output on WASAPI.
pub const wasapi = @import("wasapi.zig");
/// Video: MP4, ... decoded by Media Foundation.
pub const mediafoundation = @import("mediafoundation.zig");
/// File dialogs: the shell's IFileOpenDialog and IFileSaveDialog.
pub const filedialog = @import("filedialog.zig");
/// Tray icons in the notification area, and notifications.
pub const tray = @import("tray.zig");
/// Web views: WebView2.
pub const webview = @import("webview.zig");

pub const init = win32.init;
pub const deinit = win32.deinit;
pub const step = win32.step;
pub const runAll = win32.runAll;
pub const now = win32.now;
pub const Window = win32.Window;
pub const Options = win32.Options;
pub const RendererKind = win32.RendererKind;
pub const Error = win32.Error;

test {
    _ = win32;
    _ = wasapi;
    _ = mediafoundation;
    _ = filedialog;
    _ = tray;
    _ = webview;
}
