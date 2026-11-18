# backends

Platform backends: they turn platform events into zigulee input and show a
window's pixels.

- `sdl3/`: SDL3 (macOS, Windows, Linux), module `zigulee-sdl3`.
- `macos/`, `windows/`, `x11/`, `wayland/`, `kms/`, `fbdev/`, `wasm/`: the
  native ones (`zigulee-macos`, ...); `linux/` has what the Linux ones
  share (`zigulee-evdev`: the kernel's input devices, for KMS and fbdev).
  KMS falls back to fbdev's screen when there is no DRM display.
- `ios/`: UIKit (iPhone, iPad, the simulator, Mac Catalyst), module
  `zigulee-ios`.
- `apple/`: what the macOS and iOS backends share (`zigulee-apple`): the
  Objective-C runtime, Metal, CoreAudio, AVFoundation.

Sound: a backend can give the mixer (`zigulee.core.audio.mixer()`) an
`Output`, which pulls mixed frames from its audio thread. The SDL3
backend (`sdl3/audio.zig`), the native macOS and iOS ones (CoreAudio:
`apple/coreaudio.zig`) and Windows (WASAPI: `windows/wasapi.zig`) ones,
and the Linux ones, X11, Wayland, KMS and fbdev (PipeWire, loaded at run time:
`linux/pipewire.zig`), have one; elsewhere `Audio` elements are silent.

Video: animated PNG is decoded by the core everywhere; a backend can add a
decoder for other formats (`zigulee.core.video.addDecoder`). On macOS and
iOS, AVFoundation (`apple/avfoundation.zig`) decodes MP4 and QuickTime
files for the native backends and the SDL3 one; on Windows, Media Foundation
(`windows/mediafoundation.zig`) does for the native backend; on Linux,
GStreamer (loaded at run time: `linux/gstreamer.zig`) does for the X11,
Wayland, KMS and fbdev backends, with whatever plugins are installed.

File dialogs: a backend can provide them (`zigulee.core.dialogs.setFileDialogs`).
SDL3's (`sdl3/dialogs.zig`) are the platform's own; the native backends
use AppKit panels (`macos/filedialog.zig`), the Windows shell's dialogs
(`windows/filedialog.zig`) and the XDG desktop portal for X11 and Wayland
(`linux/portal.zig`).

Menu bar: on macOS, the menus a `MenuBar` declares go to the bar at the
top of the screen (`macos/menubar.zig`, for the native and SDL3 backends,
through `zigulee.core.menus.setMenuBar`); elsewhere they stay in the window.

Tray and notifications (`zigulee.core.tray.setProvider`): on macOS, status
items and the Notification Center, or AppleScript outside an app bundle
(`macos/tray.zig`, native and SDL3 backends); on Windows, notification
area icons with balloons (`windows/tray.zig`, native and SDL3); on Linux,
notifications over D-Bus (`linux/notifications.zig`, X11, Wayland and
SDL3) and, with SDL3 only, SDL's tray icons (`sdl3/tray.zig`).

Microphone and camera (`zigulee.core.audio.setInput`,
`zigulee.core.camera.setProvider`): the SDL3 backend's, through SDL's
recording and camera APIs (`sdl3/capture.zig`), and the native macOS
backend's, AVFoundation capture sessions (`macos/capture.zig`); the other
native backends have none yet.

Web views (`zigulee.core.webview.setProvider`, over the window's
`native_view`): WKWebView on macOS (native and SDL3 backends) and iOS
(`apple/webview.zig`), WebView2 on Windows (native and SDL3 backends,
`windows/webview.zig`: the installed runtime, found without Microsoft's
SDK), WebKitGTK on Linux with X11 (native X11 and SDL3 backends,
`linux/webkitgtk.zig`: loaded at run time, each view a GTK window made a
child of the zigulee window, GLib's loop run inside the backend's), an
`<iframe>` on the web; none on Wayland, KMS or fbdev.

Planned: an Android backend (ROADMAP-QT.md, P7).
