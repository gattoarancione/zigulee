// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const UiOptions = struct {
    /// The `.zge` file to compile.
    source: std.Build.LazyPath,
    /// The `zgec` compiler (built for the host).
    zgec: *std.Build.Step.Compile,
    /// The zigulee module the generated code imports.
    zigulee: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Style of the built-in `std-widgets.zge`: "fluent", "material",
    /// "minimal", "cupertino", or "native" (the target system's:
    /// cupertino on Apple's, fluent elsewhere).
    style: []const u8 = "fluent",
};

/// `native` as the target's style.
fn targetStyle(style: []const u8, target: std.Build.ResolvedTarget) []const u8 {
    if (!std.mem.eql(u8, style, "native")) return style;
    return switch (target.result.os.tag) {
        .macos, .ios, .maccatalyst, .tvos, .visionos, .watchos => "cupertino",
        else => "fluent",
    };
}

/// Compiles a `.zge` file to Zig at build time and returns it as a module:
///
///     const ui = uiModule(b, .{ .source = b.path("app.zge"), ... });
///     exe.root_module.addImport("ui", ui);
pub fn uiModule(b: *std.Build, options: UiOptions) *std.Build.Module {
    const run = b.addRunArtifact(options.zgec);
    run.addFileArg(options.source);
    run.addArg(b.fmt("--style={s}", .{targetStyle(options.style, options.target)}));
    run.addArg("-o");
    const generated = run.addOutputFileArg("ui.zig");
    // Images and other files the .zge file uses.
    _ = run.addPrefixedDepFileOutputArg("--dep-file=", "ui.d");
    return b.createModule(.{
        .root_source_file = generated,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "zigulee", .module = options.zigulee }},
    });
}

pub const CLibraryOptions = struct {
    /// The `.zge` file.
    source: std.Build.LazyPath,
    /// Starts every C name (`app`: `app_create`, `app_contact`...) and
    /// names the library and its header (`app.h`).
    name: []const u8,
    /// The `zgec` compiler (built for the host).
    zgec: *std.Build.Step.Compile,
    /// The `zigulee` module and the C API's window part (`zigulee-c-window`).
    zigulee: *std.Build.Module,
    c_window: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    style: []const u8 = "fluent",
};

pub const CLibrary = struct {
    /// The static library: the compiled components and zigulee's runtime
    /// (no interpreter).
    lib: *std.Build.Step.Compile,
    /// The generated header (`<name>.h`, including "zigulee.h": add zigulee's
    /// `include` directory too).
    header: std.Build.LazyPath,
    /// The directory containing the header.
    include_dir: std.Build.LazyPath,
};

/// A `.zge` file's components compiled into a static library for C, with
/// a typed header (see src/compiler/c_bindings.zig).
pub fn cLibrary(b: *std.Build, options: CLibraryOptions) CLibrary {
    const ui = uiModule(b, .{ .source = options.source, .zgec = options.zgec, .zigulee = options.zigulee, .target = options.target, .optimize = options.optimize, .style = options.style });
    const run = b.addRunArtifact(options.zgec);
    run.addArg("c");
    run.addFileArg(options.source);
    run.addArg(b.fmt("--prefix={s}", .{options.name}));
    run.addArg(b.fmt("--style={s}", .{targetStyle(options.style, options.target)}));
    const header = run.addPrefixedOutputFileArg("--header=", b.fmt("{s}.h", .{options.name}));
    const glue = run.addPrefixedOutputFileArg("--glue=", b.fmt("{s}_c.zig", .{options.name}));
    const module = b.createModule(.{
        .root_source_file = glue,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = options.zigulee },
            .{ .name = "zigulee-c-window", .module = options.c_window },
            .{ .name = "ui", .module = ui },
        },
    });
    const lib = b.addLibrary(.{ .name = options.name, .linkage = .static, .root_module = module });
    return .{ .lib = lib, .header = header, .include_dir = header.dirname() };
}

pub const BitmapFontOptions = struct {
    /// The TrueType font to render.
    font: std.Build.LazyPath,
    /// Pixel sizes to pre-render (the sizes the UI uses).
    sizes: []const u16,
    /// Hexadecimal code point ranges, e.g. "20-7e,b0,2026" (default:
    /// printable ASCII and "…").
    chars: ?[]const u8 = null,
    /// Characters to add, as text.
    text: ?[]const u8 = null,
    /// The `zigulee-bitmap-font` tool (built for the host).
    tool: *std.Build.Step.Compile,
};

/// A pre-rendered font for microcontrollers, made at build time; embed it
/// (`addAnonymousImport`, then `@embedFile`) and open it with `Font.init`.
pub fn bitmapFont(b: *std.Build, options: BitmapFontOptions) std.Build.LazyPath {
    const run = b.addRunArtifact(options.tool);
    run.addFileArg(options.font);
    run.addArg("-o");
    const out = run.addOutputFileArg("font.zbf");
    var sizes: std.ArrayList(u8) = .empty;
    for (options.sizes, 0..) |s, i| sizes.print(b.allocator, "{s}{d}", .{ if (i > 0) "," else "", s }) catch @panic("OOM");
    run.addArgs(&.{ "--sizes", sizes.items });
    if (options.chars) |c| run.addArgs(&.{ "--chars", c });
    if (options.text) |t| run.addArgs(&.{ "--text", t });
    return out;
}

/// `uiModule` for projects that use zigulee as a dependency.
pub fn uiModuleFromDependency(b: *std.Build, dep: *std.Build.Dependency, source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return uiModule(b, .{ .source = source, .zgec = dep.artifact("zgec"), .zigulee = dep.module("zigulee"), .target = target, .optimize = optimize });
}

pub const IosAppOptions = struct {
    /// The executable's and the bundle's name (`name.app`).
    name: []const u8,
    /// The app's identifier (`org.example.hello`).
    bundle_id: []const u8,
    /// Under the icon (default: `name`).
    display_name: ?[]const u8 = null,
    version: []const u8 = "1.0",
    /// The app's root module: its `pub fn main(init: std.process.Init)`
    /// runs once UIKit has launched (as `main` does elsewhere).
    app: *std.Build.Module,
    /// The `zigulee-ios` backend module.
    backend: *std.Build.Module,
    /// An iOS target (`aarch64-ios`, `aarch64-ios-simulator`) or Mac
    /// Catalyst (`aarch64-maccatalyst`).
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Signs for devices: a codesign identity ("Apple Development: ...")
    /// and the provisioning profile naming the app. Without them the
    /// bundle is signed ad hoc (enough for the simulator and the Mac).
    sign_identity: ?[]const u8 = null,
    provisioning_profile: ?std.Build.LazyPath = null,
    /// Why the app wants the position, shown when iOS asks the user (a
    /// `PositionSource`: without it, iOS refuses). Plain text.
    location_usage: ?[]const u8 = null,
};

pub const IosApp = struct {
    exe: *std.Build.Step.Compile,
    /// The `name.app` directory (not yet signed).
    bundle: std.Build.LazyPath,

    /// Installs the bundle as `<prefix>/<subdir>/name.app`, signed.
    pub fn install(app: IosApp, b: *std.Build, o: IosAppOptions, subdir: []const u8) *std.Build.Step {
        const dir = b.fmt("{s}/{s}.app", .{ subdir, o.name });
        const copy = b.addInstallDirectory(.{ .source_dir = app.bundle, .install_dir = .prefix, .install_subdir = dir });
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--timestamp=none", "--sign", o.sign_identity orelse "-" });
        if (o.provisioning_profile) |profile| {
            // The profile's entitlements (the team, the app's identifier).
            const extract = b.addSystemCommand(&.{ "sh", "-c", "security cms -D -i \"$1\" | plutil -extract Entitlements xml1 -o \"$2\" -", "entitlements" });
            extract.addFileArg(profile);
            sign.addArg("--entitlements");
            sign.addFileArg(extract.addOutputFileArg("entitlements.plist"));
        }
        sign.addArg(b.getInstallPath(.prefix, dir));
        sign.step.dependOn(&copy.step);
        sign.has_side_effects = true;
        return &sign.step;
    }
};

/// An iOS app: `o.app`'s `main` started by UIKit, in a bundle with its
/// Info.plist (a scene, every orientation on iPad, a plain launch screen).
pub fn iosApp(b: *std.Build, o: IosAppOptions) IosApp {
    const main = b.addWriteFiles().add("main.zig",
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) void {
        \\    @import("zigulee-ios").start(init, @import("app").main);
        \\}
        \\
    );
    const exe = b.addExecutable(.{ .name = o.name, .root_module = b.createModule(.{
        .root_source_file = main,
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{
            .{ .name = "app", .module = o.app },
            .{ .name = "zigulee-ios", .module = o.backend },
        },
    }) });
    const t = o.target.result;
    const mac = t.os.tag == .maccatalyst;
    const min = t.os.version_range.semver.min;
    const platform = if (mac) "MacOSX" else if (t.abi == .simulator) "iPhoneSimulator" else "iPhoneOS";
    const plist = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key><string>{[name]s}</string>
        \\    <key>CFBundleIdentifier</key><string>{[id]s}</string>
        \\    <key>CFBundleName</key><string>{[name]s}</string>
        \\    <key>CFBundleDisplayName</key><string>{[display]s}</string>
        \\    <key>CFBundlePackageType</key><string>APPL</string>
        \\    <key>CFBundleShortVersionString</key><string>{[version]s}</string>
        \\    <key>CFBundleVersion</key><string>{[version]s}</string>
        \\    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\    <key>CFBundleSupportedPlatforms</key><array><string>{[platform]s}</string></array>
        \\    <key>{[min_key]s}</key><string>{[major]d}.{[minor]d}</string>
        \\    <key>UIDeviceFamily</key><array>{[families]s}</array>
        \\    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
        \\    <key>UILaunchScreen</key><dict/>
        \\    <key>UIApplicationSceneManifest</key>
        \\    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
        \\    <key>UISupportedInterfaceOrientations</key>
        \\    <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\    <key>UISupportedInterfaceOrientations~ipad</key>
        \\    <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\{[usage]s}</dict>
        \\</plist>
        \\
    , .{
        .name = o.name,
        .id = o.bundle_id,
        .display = o.display_name orelse o.name,
        .version = o.version,
        .platform = platform,
        // Catalyst runs on macOS 11 and later (iOS 14's UIKit).
        .min_key = if (mac) "LSMinimumSystemVersion" else "MinimumOSVersion",
        .major = if (mac) @max(min.major, 14) - 3 else min.major,
        .minor = if (mac) 0 else min.minor,
        .families = if (mac) "<integer>2</integer>" else "<integer>1</integer><integer>2</integer>",
        .usage = if (o.location_usage) |u| b.fmt("    <key>NSLocationWhenInUseUsageDescription</key><string>{s}</string>\n", .{u}) else "",
    });
    const bundle = b.addWriteFiles();
    const app_dir = b.fmt("{s}.app", .{o.name});
    _ = bundle.addCopyFile(exe.getEmittedBin(), b.fmt("{s}/{s}{s}", .{ app_dir, if (mac) "Contents/MacOS/" else "", o.name }));
    _ = bundle.add(b.fmt("{s}/{s}Info.plist", .{ app_dir, if (mac) "Contents/" else "" }), plist);
    if (o.provisioning_profile) |profile| _ = bundle.addCopyFile(profile, b.fmt("{s}/embedded.mobileprovision", .{app_dir}));
    return .{ .exe = exe, .bundle = bundle.getDirectory().path(b, app_dir) };
}

/// The SDK of an iOS or Mac Catalyst target, for `module` (Zig finds the
/// macOS one by itself).
fn addAppleSdk(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const os = target.result.os.tag;
    if (os != .ios and os != .maccatalyst) return;
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
        std.debug.panic("no SDK for {t}: install Xcode", .{os});
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    if (os == .maccatalyst) module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/iOSSupport/System/Library/Frameworks" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
}

/// What the macOS and iOS backends share (`zigulee-apple`).
fn appleModule(b: *std.Build, zigulee: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/backends/apple/apple.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });
    addAppleSdk(b, m, target);
    m.linkSystemLibrary("objc", .{});
    inline for (.{ "Foundation", "CoreFoundation", "QuartzCore", "CoreGraphics", "Metal", "AudioToolbox", "AVFoundation", "CoreMedia", "CoreVideo", "WebKit", "CoreLocation" }) |framework| m.linkFramework(framework, .{});
    m.addAnonymousImport("test_mp4", .{ .root_source_file = b.path("tests/video/colors.mp4") });
    return m;
}

/// The iOS backend (`zigulee-ios`).
fn iosModule(b: *std.Build, zigulee: *std.Build.Module, apple: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/backends/ios/ios.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "zigulee-apple", .module = apple },
        },
    });
    addAppleSdk(b, m, target);
    m.linkFramework("UIKit", .{});
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigulee = b.addModule("zigulee", .{
        .root_source_file = b.path("src/zigulee.zig"),
        .target = target,
        .optimize = optimize,
    });
    // HTTPS checks certificates against the system's store (crypt32 on
    // Windows, which C programs linking the library need too).
    if (target.result.os.tag == .windows) zigulee.linkSystemLibrary("crypt32", .{});

    // The .zge compiler, built for the machine running the build. (The
    // compiler uses the runtime's PNG decoder.)
    const zigulee_host = b.createModule(.{
        .root_source_file = b.path("src/zigulee.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const zgec = b.addExecutable(.{
        .name = "zgec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zgec.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigulee", .module = zigulee_host }},
        }),
    });
    b.installArtifact(zgec);

    // Makes pre-rendered fonts (`bitmapFont`).
    const bitmap_font_tool = b.addExecutable(.{
        .name = "zigulee-bitmap-font",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bitmap_font.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigulee", .module = zigulee_host }},
        }),
    });
    b.installArtifact(bitmap_font_tool);

    // The interpreter (for zigulee-viewer and the editor preview).
    const interpreter_module = b.addModule("zigulee-interpreter", .{
        .root_source_file = b.path("src/zigulee_interpreter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });

    // The language server, for editors.
    const lsp_module = b.createModule(.{
        .root_source_file = b.path("src/zigulee_lsp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "zigulee-interpreter", .module = interpreter_module },
        },
    });
    // Fonts for the live preview.
    inline for (.{
        .{ "inter_regular", "examples/fonts/inter/Inter-Regular.ttf" },
        .{ "inter_bold", "examples/fonts/inter/Inter-Bold.ttf" },
        .{ "jetbrains_mono", "examples/fonts/jetbrains-mono/JetBrainsMono-Regular.ttf" },
    }) |font| lsp_module.addAnonymousImport(font[0], .{ .root_source_file = b.path(font[1]) });
    const lsp = b.addExecutable(.{ .name = "zigulee-lsp", .root_module = lsp_module });
    b.installArtifact(lsp);

    // The C API: libzigulee (static and shared) and include/zigulee.h. Its
    // window part (events, rendering, fonts) also serves compiled
    // components' bindings (`zigulee.cLibrary`).
    const c_window_module = b.addModule("zigulee-c-window", .{
        .root_source_file = b.path("src/c_api/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "zigulee-interpreter", .module = interpreter_module },
            .{ .name = "zigulee-c-window", .module = c_window_module },
        },
    });
    const c_static = b.addLibrary(.{ .name = "zigulee", .linkage = .static, .root_module = c_api_module });
    const c_shared = b.addLibrary(.{ .name = "zigulee", .linkage = .dynamic, .root_module = c_api_module });
    b.installArtifact(c_static);
    b.installArtifact(c_shared);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/zigulee.h"), "zigulee.h").step);

    // Unit tests.
    const tests = b.addTest(.{ .root_module = zigulee });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and golden-image tests");
    test_step.dependOn(&run_tests.step);

    const compiler_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/zgec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    }) });
    test_step.dependOn(&b.addRunArtifact(compiler_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lsp_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = interpreter_module })).step);

    // The C API, from C: tests/c/api_test.c against the static library.
    const c_test = b.addExecutable(.{ .name = "c-api-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    c_test.root_module.addCSourceFile(.{ .file = b.path("tests/c/api_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    c_test.root_module.addIncludePath(b.path("include"));
    c_test.root_module.linkLibrary(c_static);
    test_step.dependOn(&b.addRunArtifact(c_test).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = c_api_module })).step);

    // A compiled component from C: tests/c/compiled_test.c against the
    // typed header and library zigulee.cLibrary makes (no interpreter).
    const compiled = cLibrary(b, .{ .source = b.path("tests/c/compiled.zge"), .name = "people", .zgec = zgec, .zigulee = zigulee, .c_window = c_window_module, .target = target, .optimize = optimize });
    const compiled_test = b.addExecutable(.{ .name = "c-compiled-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    compiled_test.root_module.addCSourceFile(.{ .file = b.path("tests/c/compiled_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    compiled_test.root_module.addIncludePath(b.path("include"));
    compiled_test.root_module.addIncludePath(compiled.include_dir);
    compiled_test.root_module.linkLibrary(compiled.lib);
    test_step.dependOn(&b.addRunArtifact(compiled_test).step);

    // A C example: `zig build run-c-hello`.
    const c_hello = b.addExecutable(.{ .name = "c-hello", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    c_hello.root_module.addCSourceFile(.{ .file = b.path("examples/c/hello.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    c_hello.root_module.addIncludePath(b.path("include"));
    c_hello.root_module.linkLibrary(c_static);
    const run_c_hello = b.addRunArtifact(c_hello);
    run_c_hello.setCwd(b.path("."));
    b.step("run-c-hello", "Run the C example (examples/c/hello.c)").dependOn(&run_c_hello.step);

    // End-to-end: .zge files compiled at build time, exercised by tests.
    const ui_sources = [_][2][]const u8{
        .{ "ui_features", "tests/ui/features.zge" },
        .{ "ui_dynamic", "tests/ui/dynamic.zge" },
        .{ "ui_language", "tests/ui/language.zge" },
        .{ "gallery_ui", "examples/gallery.zge" },
        .{ "ui_imports", "tests/ui/imports.zge" },
        .{ "ui_widgets", "tests/ui/widgets.zge" },
        .{ "ui_containers", "tests/ui/containers.zge" },
        .{ "ui_popups", "tests/ui/popups.zge" },
        .{ "ui_table", "tests/ui/table.zge" },
        .{ "todo_ui", "examples/todo.zge" },
        .{ "ui_i18n", "tests/ui/i18n.zge" },
        .{ "patrisio_ui", "examples/patrisio.zge" },
        .{ "video_ui", "examples/video.zge" },
        .{ "ui_loader", "tests/ui/loader.zge" },
        .{ "ui_connections", "tests/ui/connections.zge" },
        .{ "ui_timeline", "tests/ui/timeline.zge" },
        .{ "ui_dnd", "tests/ui/dnd.zge" },
        .{ "ui_gestures", "tests/ui/gestures.zge" },
        .{ "ui_widgets2", "tests/ui/widgets2.zge" },
        .{ "ui_pages", "tests/ui/pages.zge" },
        .{ "ui_split", "tests/ui/split.zge" },
        .{ "ui_tree", "tests/ui/tree.zge" },
        .{ "ui_selection", "tests/ui/selection.zge" },
        .{ "ui_inherit_window", "tests/ui/inherit_window.zge" },
        .{ "ui_submenus", "tests/ui/submenus.zge" },
        .{ "ui_drawer", "tests/ui/drawer.zge" },
        .{ "ui_keyboard", "tests/ui/keyboard.zge" },
        .{ "ui_tray", "tests/ui/tray.zge" },
        .{ "ui_capture", "tests/ui/capture.zge" },
        .{ "ui_links", "tests/ui/links.zge" },
        .{ "ui_webview", "tests/ui/webview.zge" },
        .{ "ui_view3d", "tests/ui/view3d.zge" },
        .{ "ui_map", "tests/ui/map.zge" },
        .{ "ui_clip", "tests/ui/clip.zge" },
        .{ "ui_anchors", "tests/ui/anchors.zge" },
        .{ "ui_canvas", "tests/ui/canvas.zge" },
        .{ "ui_mask", "tests/ui/mask.zge" },
        .{ "ui_masksource", "tests/ui/masksource.zge" },
        .{ "ui_varlist", "tests/ui/varlist.zge" },
        .{ "ui_svgfeatures", "tests/ui/svgfeatures.zge" },
        .{ "ui_strfn", "tests/ui/strfn.zge" },
        .{ "ui_textfit", "tests/ui/textfit.zge" },
        .{ "ui_grid", "tests/ui/grid.zge" },
        .{ "ui_lists", "tests/ui/lists.zge" },
        .{ "ui_richtext", "tests/ui/richtext.zge" },
        .{ "ui_svg", "tests/ui/svg.zge" },
        .{ "ui_remote", "tests/ui/remote.zge" },
        .{ "ui_winstate", "tests/ui/winstate.zge" },
        .{ "ui_settings", "tests/ui/settings.zge" },
        .{ "ui_charts", "tests/ui/charts.zge" },
        .{ "ui_http", "tests/ui/http.zge" },
        .{ "network_ui", "examples/network.zge" },
    };
    var ui_imports: [ui_sources.len + 1]std.Build.Module.Import = undefined;
    ui_imports[0] = .{ .name = "zigulee", .module = zigulee };
    for (ui_sources, 1..) |src, i| ui_imports[i] = .{
        .name = src[0],
        .module = uiModule(b, .{ .source = b.path(src[1]), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize }),
    };
    const ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ui_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &ui_imports,
    }) });
    // The todo example's Zig side, tested headless.
    const todo_ui = for (ui_imports) |imp| {
        if (std.mem.eql(u8, imp.name, "todo_ui")) break imp.module;
    } else unreachable;
    ui_tests.root_module.addImport("todo_list", b.createModule(.{
        .root_source_file = b.path("examples/todo_list.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "todo_ui", .module = todo_ui },
        },
    }));
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // The interpreter must behave like the compiled code.
    const interp_options = b.addOptions();
    interp_options.addOption([]const u8, "root", b.pathFromRoot("."));
    const interp_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/interpreter_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &ui_imports,
    }) });
    interp_tests.root_module.addImport("zigulee-interpreter", interpreter_module);
    interp_tests.root_module.addImport("build_options", interp_options.createModule());
    const run_interp_tests = b.addRunArtifact(interp_tests);
    run_interp_tests.has_side_effects = true; // reads the .zge files
    test_step.dependOn(&run_interp_tests.step);

    // Golden-image tests: `-Dupdate-golden` rewrites tests/golden/*.png.
    const golden_options = b.addOptions();
    golden_options.addOption([]const u8, "golden_dir", b.pathFromRoot("tests/golden"));
    golden_options.addOption([]const u8, "fonts_dir", b.pathFromRoot("examples/fonts"));
    golden_options.addOption(bool, "update_golden", b.option(bool, "update-golden", "Rewrite golden images from the current output") orelse false);
    const golden_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "build_options", .module = golden_options.createModule() },
            .{ .name = "ui_widgets", .module = uiModule(b, .{ .source = b.path("tests/ui/widgets.zge"), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize }) },
            .{ .name = "ui_widgets_material", .module = uiModule(b, .{ .source = b.path("tests/ui/widgets.zge"), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize, .style = "material" }) },
            .{ .name = "ui_widgets_minimal", .module = uiModule(b, .{ .source = b.path("tests/ui/widgets.zge"), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize, .style = "minimal" }) },
            .{ .name = "ui_widgets_cupertino", .module = uiModule(b, .{ .source = b.path("tests/ui/widgets.zge"), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize, .style = "cupertino" }) },
        },
    }) });
    const run_golden = b.addRunArtifact(golden_tests);
    run_golden.has_side_effects = true; // reads the golden files
    test_step.dependOn(&run_golden.step);

    // The interpreter (and the compiler in it) for tools run by the build.
    const interpreter_host = b.createModule(.{
        .root_source_file = b.path("src/zigulee_interpreter.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "zigulee", .module = zigulee_host }},
    });

    // Fuzzing: `zig build fuzz -- [iterations] [target-filter] [seed]` runs
    // the fuzz targets on random inputs (ReleaseSafe: fast, still checked).
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee_host },
                .{ .name = "zigulee-interpreter", .module = interpreter_host },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Run the fuzz targets on random inputs: zig build fuzz -- [iterations] [filter] [seed]").dependOn(&run_fuzz.step);

    // Reference documentation: `zig build docs` regenerates
    // docs/reference/*.md; the tests check that they are up to date.
    const docgen = b.addExecutable(.{
        .name = "docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docgen.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "zigulee-interpreter", .module = interpreter_host }},
        }),
    });
    const write_docs = b.addRunArtifact(docgen);
    write_docs.addArg(b.pathFromRoot("docs"));
    b.step("docs", "Regenerate the reference documentation in docs/reference").dependOn(&write_docs.step);
    const check_docs = b.addRunArtifact(docgen);
    check_docs.addArgs(&.{ b.pathFromRoot("docs"), "--check" });
    check_docs.has_side_effects = true;
    test_step.dependOn(&check_docs.step);

    // The video example's clip (examples/video/demo.png), drawn.
    const video_demo = b.addExecutable(.{
        .name = "video-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/video_demo.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zigulee", .module = zigulee_host }},
        }),
    });
    const make_video = b.addRunArtifact(video_demo);
    make_video.addArg(b.pathFromRoot("examples/video/demo.png"));
    b.step("video-demo", "Draw the video example's clip into examples/video/demo.png").dependOn(&make_video.step);

    // The Patrisio example's sounds (examples/patrisio/*.wav), synthesized.
    const patrisio_sounds = b.addExecutable(.{
        .name = "patrisio-sounds",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/patrisio_sounds.zig"), .target = b.graph.host }),
    });
    const make_sounds = b.addRunArtifact(patrisio_sounds);
    make_sounds.addArg(b.pathFromRoot("examples/patrisio"));
    b.step("patrisio-sounds", "Synthesize the Patrisio example's sounds into examples/patrisio").dependOn(&make_sounds.step);

    // WebAssembly: the zigulee-wasm backend (src/backends/wasm, with
    // zigulee.js), `zig build web` (the gallery in a browser) and a test run
    // in Node.
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const wasm_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSmall else optimize;
        const zigulee_wasm_core = b.createModule(.{ .root_source_file = b.path("src/zigulee.zig"), .target = wasm_target, .optimize = wasm_optimize });
        const wasm_backend = b.addModule("zigulee-wasm", .{
            .root_source_file = b.path("src/backends/wasm/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{.{ .name = "zigulee", .module = zigulee_wasm_core }},
        });
        const WasmApp = struct {
            fn make(bb: *std.Build, name: []const u8, root: []const u8, ui_name: []const u8, ui_source: []const u8, core_module: *std.Build.Module, backend: *std.Build.Module, compiler: *std.Build.Step.Compile, t: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
                const exe = bb.addExecutable(.{
                    .name = name,
                    .root_module = bb.createModule(.{
                        .root_source_file = bb.path(root),
                        .target = t,
                        .optimize = opt,
                        .imports = &.{
                            .{ .name = "zigulee", .module = core_module },
                            .{ .name = "zigulee-wasm", .module = backend },
                            .{ .name = ui_name, .module = uiModule(bb, .{ .source = bb.path(ui_source), .zgec = compiler, .zigulee = core_module, .target = t, .optimize = opt }) },
                        },
                    }),
                });
                exe.entry = .disabled;
                exe.rdynamic = true;
                return exe;
            }
        };
        const web_gallery = WasmApp.make(b, "gallery", "examples/web/gallery.zig", "gallery_ui", "examples/gallery.zge", zigulee_wasm_core, wasm_backend, zgec, wasm_target, wasm_optimize);
        inline for (.{
            .{ "inter_regular", "examples/fonts/inter/Inter-Regular.ttf" },
            .{ "inter_bold", "examples/fonts/inter/Inter-Bold.ttf" },
            .{ "jetbrains_mono", "examples/fonts/jetbrains-mono/JetBrainsMono-Regular.ttf" },
        }) |font| web_gallery.root_module.addAnonymousImport(font[0], .{ .root_source_file = b.path(font[1]) });
        const web_step = b.step("web", "Build the gallery for the browser in zig-out/web (serve that directory)");
        web_step.dependOn(&b.addInstallArtifact(web_gallery, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        web_step.dependOn(&b.addInstallFile(b.path("src/backends/wasm/zigulee.js"), "web/zigulee.js").step);

        // WebGL2 against the software renderer, in a headless browser (not
        // part of `test`: it needs a Chromium-based browser).
        if (b.findProgram(&.{"node"}, &.{}) catch null) |node| {
            const run_webgl = b.addSystemCommand(&.{node});
            run_webgl.addFileArg(b.path("tests/wasm/webgl.mjs"));
            run_webgl.addArtifactArg(web_gallery);
            run_webgl.addFileArg(b.path("src/backends/wasm/zigulee.js"));
            run_webgl.has_side_effects = true;
            b.step("test-webgl", "Check WebGL2 rendering against the software renderer in a headless Chromium-based browser").dependOn(&run_webgl.step);
        }
        web_step.dependOn(&b.addInstallFile(b.path("examples/web/index.html"), "web/index.html").step);

        const test_app = WasmApp.make(b, "wasm-test", "tests/wasm/app.zig", "wasm_test_ui", "tests/wasm/app.zge", zigulee_wasm_core, wasm_backend, zgec, wasm_target, wasm_optimize);
        test_app.root_module.addAnonymousImport("font", .{ .root_source_file = b.path("examples/fonts/inter/Inter-Regular.ttf") });
        if (b.findProgram(&.{"node"}, &.{})) |node| {
            const run_wasm_test = b.addSystemCommand(&.{node});
            run_wasm_test.addFileArg(b.path("tests/wasm/test.mjs"));
            run_wasm_test.addArtifactArg(test_app);
            run_wasm_test.addFileArg(b.path("src/backends/wasm/zigulee.js"));
            run_wasm_test.expectStdOutEqual("wasm: all checks passed\n");
            test_step.dependOn(&run_wasm_test.step);
        } else |_| {}
    }

    // Benchmarks: `zig build bench [-- --check] [-- filter]`, ReleaseFast.
    // `zig build bench-install -Dtarget=...` builds them for a board
    // instead, into zig-out/bin/bench, to run there.
    const zigulee_fast = b.createModule(.{
        .root_source_file = b.path("src/zigulee.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        // Small enough to copy to a board.
        .strip = true,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee_fast },
            .{ .name = "zigulee-interpreter", .module = b.createModule(.{
                .root_source_file = b.path("src/zigulee_interpreter.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "zigulee", .module = zigulee_fast }},
            }) },
            .{ .name = "gallery_ui", .module = uiModule(b, .{ .source = b.path("examples/gallery.zge"), .zgec = zgec, .zigulee = zigulee_fast, .target = target, .optimize = .ReleaseFast }) },
            .{ .name = "todo_ui", .module = uiModule(b, .{ .source = b.path("examples/todo.zge"), .zgec = zgec, .zigulee = zigulee_fast, .target = target, .optimize = .ReleaseFast }) },
        },
    });
    // The framebuffer's copy (fbdev's fb.zig), measured on an in-memory
    // screen.
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const xkb_fast = b.createModule(.{ .root_source_file = b.path("src/backends/linux/xkb.zig"), .target = target, .optimize = .ReleaseFast, .link_libc = true });
        const evdev_fast = b.createModule(.{ .root_source_file = b.path("src/backends/linux/evdev.zig"), .target = target, .optimize = .ReleaseFast, .link_libc = true, .imports = &.{
            .{ .name = "zigulee", .module = zigulee_fast },
            .{ .name = "zigulee-xkb", .module = xkb_fast },
        } });
        bench_module.addImport("zigulee-fb", b.createModule(.{ .root_source_file = b.path("src/backends/fbdev/fb.zig"), .target = target, .optimize = .ReleaseFast, .link_libc = true, .imports = &.{
            .{ .name = "zigulee", .module = zigulee_fast },
            .{ .name = "zigulee-evdev", .module = evdev_fast },
        } }));
    }
    bench_module.addAnonymousImport("inter_regular", .{ .root_source_file = b.path("examples/fonts/inter/Inter-Regular.ttf") });
    bench_module.addAnonymousImport("gallery_source", .{ .root_source_file = b.path("examples/gallery.zge") });
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true;
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run the benchmarks against their budgets: zig build bench [-- --check] [-- filter]").dependOn(&run_bench.step);
    b.step("bench-install", "Build the benchmarks for -Dtarget into zig-out/bin/bench, to run on a board").dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // Examples.
    const examples_step = b.step("examples", "Build all examples");
    const examples = [_][]const u8{ "counter", "animation", "layout", "list", "screenshot" };
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigulee", .module = zigulee }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }

    // The style of the standard widgets in the windowed examples.
    const ios_target = target.result.os.tag == .ios or target.result.os.tag == .maccatalyst;
    const example_style = b.option([]const u8, "style", "Style of the standard widgets in the examples: fluent, material, minimal, cupertino or native (default: fluent; native on iOS)") orelse if (ios_target) "native" else "fluent";

    // The Vulkan shaders, compiled to SPIR-V (checked in): `zig build
    // vulkan-shaders` after changing them (needs glslc, from shaderc).
    {
        const step = b.step("vulkan-shaders", "Compile the Vulkan shaders to SPIR-V (needs glslc)");
        const update = b.addUpdateSourceFiles();
        for ([_][]const u8{ "vulkan.vert", "vulkan.frag", "vulkan3d.vert", "vulkan3d.frag" }) |name| {
            const glslc = b.addSystemCommand(&.{ "glslc", "-O" });
            glslc.addFileArg(b.path(b.fmt("src/renderers/gpu/shaders/{s}", .{name})));
            glslc.addArg("-o");
            const spv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{name}));
            update.addCopyFileToSource(spv, b.fmt("src/renderers/gpu/shaders/{s}.spv", .{name}));
        }
        step.dependOn(&update.step);
    }

    // What the macOS and iOS backends share: the Objective-C runtime,
    // Metal, CoreAudio, AVFoundation.
    const apple_module: ?*std.Build.Module = if (target.result.os.tag.isDarwin()) blk: {
        const m = appleModule(b, zigulee, target, optimize);
        b.modules.put(b.graph.arena, "zigulee-apple", m) catch @panic("OOM");
        break :blk m;
    } else null;

    // The native macOS backend (no SDL), with VoiceOver support (which the
    // SDL3 backend uses too).
    const macos_module: ?*std.Build.Module = if (target.result.os.tag == .macos) blk: {
        const m = b.addModule("zigulee-macos", .{
            .root_source_file = b.path("src/backends/macos/macos.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "zigulee-apple", .module = apple_module.? },
            },
        });
        inline for (.{ "AppKit", "OpenGL" }) |framework| m.linkFramework(framework, .{});
        m.linkFramework("UniformTypeIdentifiers", .{ .weak = true });
        m.linkFramework("UserNotifications", .{ .weak = true });
        const macos_test_step = b.step("test-macos", "Test the native macOS backend");
        macos_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
        macos_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = apple_module.? })).step);
        test_step.dependOn(macos_test_step);
        break :blk m;
    } else null;

    // Direct3D 12 (Windows): the GPU renderer, with the declarations
    // translated from the Windows SDK headers that ship with Zig.
    const d3d12_module: ?*std.Build.Module = if (target.result.os.tag == .windows) blk: {
        const headers = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("d3d12.h",
                \\#define WIN32_LEAN_AND_MEAN
                \\#include <windows.h>
                \\#include <d3d12.h>
                \\#include <dxgi1_4.h>
                \\#include <d3dcompiler.h>
                \\
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const m = b.addModule("zigulee-d3d12", .{
            .root_source_file = b.path("src/backends/windows/d3d12.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "d3d12_c", .module = headers.createModule() },
            },
        });
        inline for (.{ "d3d12", "dxgi", "d3dcompiler_47" }) |lib| m.linkSystemLibrary(lib, .{});
        // The tests need Windows: elsewhere they are only compiled.
        const d3d12_tests = b.addTest(.{ .root_module = m });
        const d3d12_step = b.step("test-d3d12", "Run the Direct3D 12 renderer's tests (on Windows; elsewhere only build them)");
        if (b.graph.host.result.os.tag == .windows) {
            d3d12_step.dependOn(&b.addRunArtifact(d3d12_tests).step);
        } else d3d12_step.dependOn(&b.addInstallArtifact(d3d12_tests, .{}).step);
        break :blk m;
    } else null;

    // The Windows SDK's declarations (from the headers that ship with
    // Zig), for the UI Automation bridge and the native Win32 backend.
    const win32_headers: ?*std.Build.Module = if (target.result.os.tag == .windows) blk: {
        const headers = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("win32.h",
                \\#define WIN32_LEAN_AND_MEAN
                \\#include <windows.h>
                \\#include <ole2.h>
                \\#include <uiautomation.h>
                \\#include <imm.h>
                \\#include <dwmapi.h>
                \\#include <mmdeviceapi.h>
                \\#include <audioclient.h>
                \\#include <avrt.h>
                \\#include <mfapi.h>
                \\#include <mfidl.h>
                \\#include <mfreadwrite.h>
                \\#include <shlwapi.h>
                \\#include <shobjidl.h>
                \\#include <shellapi.h>
                \\
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        break :blk headers.createModule();
    } else null;

    // UI Automation (Windows): screen reader support.
    const uia_module: ?*std.Build.Module = if (win32_headers) |headers| blk: {
        const m = b.addModule("zigulee-uia", .{
            .root_source_file = b.path("src/backends/windows/uia.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "uia_c", .module = headers },
            },
        });
        inline for (.{ "uiautomationcore", "ole32", "oleaut32", "user32" }) |lib| m.linkSystemLibrary(lib, .{});
        const uia_tests = b.addTest(.{ .root_module = m });
        const uia_step = b.step("test-uia", "Run the UI Automation bridge's tests (on Windows; elsewhere only build them)");
        if (b.graph.host.result.os.tag == .windows) {
            uia_step.dependOn(&b.addRunArtifact(uia_tests).step);
        } else uia_step.dependOn(&b.addInstallArtifact(uia_tests, .{}).step);
        break :blk m;
    } else null;

    // The native Windows backend (Win32): windows, input, Direct3D 12 or
    // the software renderer, UI Automation.
    const windows_module: ?*std.Build.Module = if (win32_headers) |headers| blk: {
        const m = b.addModule("zigulee-windows", .{
            .root_source_file = b.path("src/backends/windows/windows.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "win32_c", .module = headers },
                .{ .name = "zigulee-uia", .module = uia_module.? },
                .{ .name = "zigulee-d3d12", .module = d3d12_module.? },
            },
        });
        inline for (.{ "user32", "gdi32", "imm32", "dwmapi", "ole32", "avrt", "mfplat", "mfreadwrite", "shlwapi", "shell32", "advapi32" }) |lib| m.linkSystemLibrary(lib, .{});
        m.addAnonymousImport("test_mp4", .{ .root_source_file = b.path("tests/video/colors.mp4") });
        const windows_tests = b.addTest(.{ .root_module = m });
        const windows_step = b.step("test-windows", "Test the native Windows backend (on Windows; elsewhere only build them)");
        if (b.graph.host.result.os.tag == .windows) {
            windows_step.dependOn(&b.addRunArtifact(windows_tests).step);
        } else windows_step.dependOn(&b.addInstallArtifact(windows_tests, .{}).step);
        break :blk m;
    } else null;

    // AT-SPI (Linux): screen reader support over D-Bus. Its tests need a
    // session bus (`dbus-run-session -- zig build test-atspi`); without
    // one they are skipped. They also run on macOS, with D-Bus installed.
    const atspi_module: ?*std.Build.Module = if (target.result.os.tag != .windows and target.result.os.tag != .freestanding and target.result.os.tag != .wasi) blk: {
        const m = b.addModule("zigulee-atspi", .{
            .root_source_file = b.path("src/backends/linux/atspi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zigulee", .module = zigulee }},
        });
        const atspi_step = b.step("test-atspi", "Test the AT-SPI bridge (needs a session bus, else skipped)");
        atspi_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
        test_step.dependOn(atspi_step);
        break :blk m;
    } else null;

    // Sound through PipeWire (libpipewire loaded at run time), for the
    // X11, Wayland and KMS backends. Its test needs a PipeWire server, else
    // it is skipped.
    const pipewire_module = b.addModule("zigulee-pipewire", .{
        .root_source_file = b.path("src/backends/linux/pipewire.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });
    if (target.result.os.tag == .linux) {
        const pipewire_step = b.step("test-pipewire", "Test the PipeWire audio output (needs a PipeWire server, else skipped)");
        const pipewire_tests = b.addTest(.{ .root_module = pipewire_module });
        if (b.graph.host.result.os.tag == .linux) {
            pipewire_step.dependOn(&b.addRunArtifact(pipewire_tests).step);
            test_step.dependOn(pipewire_step);
        } else pipewire_step.dependOn(&b.addInstallArtifact(pipewire_tests, .{}).step);
    }

    // Video through GStreamer (libgstreamer loaded at run time), for the
    // X11, Wayland and KMS backends. Its test needs GStreamer with an MP4
    // demuxer and H.264/AAC decoders, else it is skipped.
    const gstreamer_module = b.addModule("zigulee-gstreamer", .{
        .root_source_file = b.path("src/backends/linux/gstreamer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });
    gstreamer_module.addAnonymousImport("test_mp4", .{ .root_source_file = b.path("tests/video/colors.mp4") });
    if (target.result.os.tag == .linux) {
        const gstreamer_step = b.step("test-gstreamer", "Test the GStreamer video decoder (needs GStreamer and its plugins, else skipped)");
        const gstreamer_tests = b.addTest(.{ .root_module = gstreamer_module });
        if (b.graph.host.result.os.tag == .linux) {
            gstreamer_step.dependOn(&b.addRunArtifact(gstreamer_tests).step);
            test_step.dependOn(gstreamer_step);
        } else gstreamer_step.dependOn(&b.addInstallArtifact(gstreamer_tests, .{}).step);
    }

    // Web views through WebKitGTK (loaded at run time, with GTK), for the
    // X11 backends. Its test needs an X server and WebKitGTK
    // (`xvfb-run zig build test-webkitgtk`), else it is skipped.
    const webkitgtk_module = b.addModule("zigulee-webkitgtk", .{
        .root_source_file = b.path("src/backends/linux/webkitgtk.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigulee", .module = zigulee }},
    });
    if (target.result.os.tag == .linux) {
        const webkitgtk_step = b.step("test-webkitgtk", "Test the WebKitGTK web views (needs an X server and WebKitGTK, else skipped)");
        const webkitgtk_tests = b.addTest(.{ .root_module = webkitgtk_module });
        if (b.graph.host.result.os.tag == .linux) {
            webkitgtk_step.dependOn(&b.addRunArtifact(webkitgtk_tests).step);
            test_step.dependOn(webkitgtk_step);
        } else webkitgtk_step.dependOn(&b.addInstallArtifact(webkitgtk_tests, .{}).step);
    }

    // The native X11 backend: talks to the X server directly. Its tests
    // need one (`xvfb-run zig build test-x11`); without one they are
    // skipped.
    const x11_module: ?*std.Build.Module = if (atspi_module) |atspi| blk: {
        const m = b.addModule("zigulee-x11", .{
            .root_source_file = b.path("src/backends/x11/x11.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "zigulee-atspi", .module = atspi },
                .{ .name = "zigulee-pipewire", .module = pipewire_module },
                .{ .name = "zigulee-gstreamer", .module = gstreamer_module },
                .{ .name = "zigulee-webkitgtk", .module = webkitgtk_module },
            },
        });
        const x11_step = b.step("test-x11", "Test the X11 backend (needs an X server, else skipped)");
        x11_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
        test_step.dependOn(x11_step);
        break :blk m;
    } else null;

    // The native Wayland backend: talks to the compositor directly (Linux).
    // Its tests need one (`weston --backend=headless`); without one they
    // are skipped.
    // The keyboard with libxkbcommon (loaded at run time), for the Wayland
    // and KMS backends.
    const xkb_module = b.addModule("zigulee-xkb", .{
        .root_source_file = b.path("src/backends/linux/xkb.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wayland_module: ?*std.Build.Module = if (target.result.os.tag == .linux) blk: {
        const m = b.addModule("zigulee-wayland", .{
            .root_source_file = b.path("src/backends/wayland/wayland.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "zigulee-atspi", .module = atspi_module.? },
                .{ .name = "zigulee-xkb", .module = xkb_module },
                .{ .name = "zigulee-pipewire", .module = pipewire_module },
                .{ .name = "zigulee-gstreamer", .module = gstreamer_module },
            },
        });
        const wayland_step = b.step("test-wayland", "Test the Wayland backend (needs a compositor, else skipped)");
        const wayland_tests = b.addTest(.{ .root_module = m });
        if (b.graph.host.result.os.tag == .linux) {
            wayland_step.dependOn(&b.addRunArtifact(wayland_tests).step);
            test_step.dependOn(wayland_step);
        } else wayland_step.dependOn(&b.addInstallArtifact(wayland_tests, .{}).step);
        break :blk m;
    } else null;

    // Input from the kernel's event devices, for the KMS and fbdev
    // backends (its tests run with theirs).
    const evdev_module = b.addModule("zigulee-evdev", .{
        .root_source_file = b.path("src/backends/linux/evdev.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zigulee", .module = zigulee },
            .{ .name = "zigulee-xkb", .module = xkb_module },
        },
    });

    // The fbdev backend: full screen on the framebuffer device (Linux:
    // /dev/fb0, event devices), for displays without a DRM driver. Its
    // screen test needs a framebuffer device (vfb in CI); without one it is
    // skipped. (It also builds on macOS, where its other tests run.)
    const fbdev_module: ?*std.Build.Module = if (target.result.os.tag == .linux or target.result.os.tag == .macos) blk: {
        const m = b.addModule("zigulee-fbdev", .{
            .root_source_file = b.path("src/backends/fbdev/fbdev.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "zigulee-evdev", .module = evdev_module },
                .{ .name = "zigulee-xkb", .module = xkb_module },
                .{ .name = "zigulee-pipewire", .module = pipewire_module },
                .{ .name = "zigulee-gstreamer", .module = gstreamer_module },
            },
        });
        const fbdev_step = b.step("test-fbdev", "Test the fbdev backend (the screen test needs a framebuffer device, else skipped)");
        const fbdev_tests = b.addTest(.{ .root_module = m });
        if (b.graph.host.result.os.tag == target.result.os.tag) {
            fbdev_step.dependOn(&b.addRunArtifact(fbdev_tests).step);
            test_step.dependOn(fbdev_step);
        } else fbdev_step.dependOn(&b.addInstallArtifact(fbdev_tests, .{}).step);
        break :blk m;
    } else null;

    // The KMS backend: full screen on a display without a desktop (Linux:
    // kernel mode setting, event devices; the framebuffer device when
    // there is no DRM display). Its display test needs a DRM device (vkms
    // in CI); without one it is skipped. (It also builds on macOS, where
    // its input tests run.)
    const kms_module: ?*std.Build.Module = if (fbdev_module) |fbdev_m| blk: {
        const m = b.addModule("zigulee-kms", .{
            .root_source_file = b.path("src/backends/kms/kms.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "zigulee-evdev", .module = evdev_module },
                .{ .name = "zigulee-fbdev", .module = fbdev_m },
                .{ .name = "zigulee-xkb", .module = xkb_module },
                .{ .name = "zigulee-pipewire", .module = pipewire_module },
                .{ .name = "zigulee-gstreamer", .module = gstreamer_module },
            },
        });
        const kms_step = b.step("test-kms", "Test the KMS backend and its input (the display test needs a DRM device, else skipped)");
        const kms_tests = b.addTest(.{ .root_module = m });
        const evdev_tests = b.addTest(.{ .root_module = evdev_module });
        if (b.graph.host.result.os.tag == target.result.os.tag) {
            kms_step.dependOn(&b.addRunArtifact(kms_tests).step);
            kms_step.dependOn(&b.addRunArtifact(evdev_tests).step);
            test_step.dependOn(kms_step);
        } else {
            kms_step.dependOn(&b.addInstallArtifact(kms_tests, .{}).step);
            kms_step.dependOn(&b.addInstallArtifact(evdev_tests, .{}).step);
        }
        break :blk m;
    } else null;

    // Which backend the windowed examples and the viewer use.
    const Backend = enum { sdl3, macos, windows, x11, wayland, kms, fbdev };
    const backend = b.option(Backend, "backend", "Backend of the windowed examples and the viewer: sdl3 (default), macos, windows, x11, wayland (native), kms or fbdev (full screen, no desktop)") orelse .sdl3;
    const app_options: WindowApps = .{ .zigulee = zigulee, .zgec = zgec, .interpreter = interpreter_module, .target = target, .optimize = optimize, .style = example_style, .examples_step = examples_step };
    if (backend == .macos) {
        if (macos_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=macos needs a macOS target", .{});
    }
    if (backend == .windows) {
        if (windows_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=windows needs a Windows target", .{});
    }
    if (backend == .kms) {
        if (kms_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=kms needs a Linux target", .{});
    }
    if (backend == .fbdev) {
        if (fbdev_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=fbdev needs a Linux target", .{});
    }
    if (backend == .wayland) {
        if (wayland_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=wayland needs a Linux target", .{});
    }
    if (backend == .x11) {
        if (x11_module) |m| windowApps(b, app_options, m) else std.debug.panic("-Dbackend=x11 needs a Unix target", .{});
    }

    // The iOS backend (UIKit): iPhone and iPad (-Dtarget=aarch64-ios), the
    // simulator (aarch64-ios-simulator) and Macs (aarch64-maccatalyst).
    // `zig build ios` makes the windowed examples' app bundles, in
    // zig-out/ios; on Mac Catalyst, `zig build run-<example>` runs one.
    if (ios_target) {
        const ios = iosModule(b, zigulee, apple_module.?, target, optimize);
        b.modules.put(b.graph.arena, "zigulee-ios", ios) catch @panic("OOM");
        const ios_step = b.step("ios", "Build the windowed examples as iOS apps, in zig-out/ios (with an iOS or Mac Catalyst target)");
        const identity = b.option([]const u8, "ios-identity", "Codesign identity for iOS devices (with -Dios-profile; else signed ad hoc)");
        const profile = b.option([]const u8, "ios-profile", "Provisioning profile for iOS devices (with -Dios-identity)");
        for ([_][]const u8{ "hello", "gallery", "todo", "patrisio", "video" }) |name| {
            const app_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigulee", .module = zigulee },
                    .{ .name = "zigulee-backend", .module = ios },
                    .{ .name = b.fmt("{s}_ui", .{name}), .module = uiModule(b, .{ .source = b.path(b.fmt("examples/{s}.zge", .{name})), .zgec = zgec, .zigulee = zigulee, .target = target, .optimize = optimize, .style = example_style }) },
                },
            });
            const o: IosAppOptions = .{
                .name = name,
                .bundle_id = b.fmt("dev.zigulee.examples.{s}", .{name}),
                .app = app_module,
                .backend = ios,
                .target = target,
                .optimize = optimize,
                .sign_identity = identity,
                .provisioning_profile = if (profile) |p| .{ .cwd_relative = p } else null,
            };
            const app = iosApp(b, o);
            const installed = app.install(b, o, "ios");
            ios_step.dependOn(installed);
            if (target.result.os.tag == .maccatalyst) {
                const run = b.addSystemCommand(&.{b.getInstallPath(.prefix, b.fmt("ios/{s}.app/Contents/MacOS/{s}", .{ name, name }))});
                run.step.dependOn(installed);
                if (b.args) |args| run.addArgs(args);
                b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example (Mac Catalyst)", .{name})).dependOn(&run.step);
            }
        }
    }

    // test-ios: the iOS backend on this Mac, in a Mac Catalyst app (UIKit
    // as on an iPad): unit tests, and an app driving a window.
    if (b.graph.host.result.os.tag == .macos) {
        const cat = b.resolveTargetQuery(.{ .cpu_arch = b.graph.host.result.cpu.arch, .os_tag = .maccatalyst });
        const cat_zigulee = b.createModule(.{ .root_source_file = b.path("src/zigulee.zig"), .target = cat, .optimize = optimize });
        const cat_ios = iosModule(b, cat_zigulee, appleModule(b, cat_zigulee, cat, optimize), cat, optimize);
        const ios_test_step = b.step("test-ios", "Test the iOS backend (on a Mac, through Mac Catalyst)");
        ios_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cat_ios })).step);
        const o: IosAppOptions = .{
            .name = "ZiguleeTest",
            .bundle_id = "dev.zigulee.test",
            .app = b.createModule(.{
                .root_source_file = b.path("tests/ios/app.zig"),
                .target = cat,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigulee", .module = cat_zigulee },
                    .{ .name = "zigulee-ios", .module = cat_ios },
                    .{ .name = "ios_test_ui", .module = uiModule(b, .{ .source = b.path("tests/ios/app.zge"), .zgec = zgec, .zigulee = cat_zigulee, .target = cat, .optimize = optimize }) },
                },
            }),
            .backend = cat_ios,
            .target = cat,
            .optimize = optimize,
        };
        const app = iosApp(b, o);
        const run = std.Build.Step.Run.create(b, "run ZiguleeTest.app");
        run.addFileArg(app.bundle.path(b, "Contents/MacOS/ZiguleeTest"));
        run.expectExitCode(0);
        ios_test_step.dependOn(&run.step);
        test_step.dependOn(ios_test_step);
    }

    // SDL3 backend. SDL is built from source by the Zig package manager (a
    // lazy dependency: fetched on first use).
    if (!ios_target) if (b.lazyDependency("sdl", .{ .target = target, .optimize = optimize })) |sdl_dep| {
        const sdl_lib = sdl_dep.artifact("SDL3");
        const translate = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("sdl3.h", "#include <SDL3/SDL.h>\n"),
            .target = target,
            .optimize = optimize,
        });
        translate.addIncludePath(sdl_dep.path("include"));
        const sdl3 = b.addModule("zigulee-sdl3", .{
            .root_source_file = b.path("src/backends/sdl3/sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee },
                .{ .name = "sdl3_c", .module = translate.createModule() },
            },
        });
        sdl3.linkLibrary(sdl_lib);
        if (target.result.os.tag == .windows) sdl3.linkSystemLibrary("dwmapi", .{});
        // VoiceOver support on macOS.
        if (macos_module) |m| sdl3.addImport("zigulee-macos", m);
        if (d3d12_module) |m| sdl3.addImport("zigulee-d3d12", m);
        if (uia_module) |m| sdl3.addImport("zigulee-uia", m);
        if (windows_module) |m| sdl3.addImport("zigulee-windows", m);
        if (target.result.os.tag == .linux) if (atspi_module) |m| sdl3.addImport("zigulee-atspi", m);
        if (target.result.os.tag == .linux) sdl3.addImport("zigulee-webkitgtk", webkitgtk_module);
        if (backend == .sdl3) windowApps(b, app_options, sdl3);

        const sdl3_tests = b.addTest(.{ .root_module = sdl3 });
        const sdl3_test_step = b.step("test-sdl3", "Test the SDL3 backend (headless, no display needed)");
        sdl3_test_step.dependOn(&b.addRunArtifact(sdl3_tests).step);
        test_step.dependOn(sdl3_test_step);
    };

    // Embedded smoke check: the core must compile for a bare-metal Cortex-M4.
    const mcu_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
    });
    const zigulee_mcu = b.createModule(.{
        .root_source_file = b.path("src/zigulee.zig"),
        .target = mcu_target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });
    const mcu_lib = b.addLibrary(.{
        .name = "zigulee-mcu-check",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mcu_check.zig"),
            .target = mcu_target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .imports = &.{.{ .name = "zigulee", .module = zigulee_mcu }},
        }),
    });
    // `zig build mcu-size`: code size and memory of an MCU demo UI, against
    // the budget (tools/mcu_size.zig). Built for the Cortex-M4 (sections)
    // and for wasm32 (32-bit too, run under Node.js to measure the heap).
    const mcu_size_step = b.step("mcu-size", "Measure the MCU demo's code size and RAM against the budget [-- --check]");
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        // Inter at the sizes the thermostat uses (Style.font-size, Text's
        // default, its labels), printable ASCII and "…".
        const thermostat_font = bitmapFont(b, .{ .font = b.path("examples/fonts/inter/Inter-Regular.ttf"), .sizes = &.{ 13, 14, 16, 40 }, .tool = bitmap_font_tool });
        var demos: [2]*std.Build.Step.Compile = undefined;
        for ([_]std.Build.ResolvedTarget{ mcu_target, wasm_target }, &demos) |t, *demo| {
            const zigulee_t = b.createModule(.{
                .root_source_file = b.path("src/zigulee.zig"),
                .target = t,
                .optimize = .ReleaseSmall,
                .single_threaded = true,
                .unwind_tables = .none,
            });
            demo.* = b.addExecutable(.{
                .name = "mcu-demo",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/mcu_demo.zig"),
                    .target = t,
                    .optimize = .ReleaseSmall,
                    .single_threaded = true,
                    .unwind_tables = .none,
                    .imports = &.{
                        .{ .name = "zigulee", .module = zigulee_t },
                        .{ .name = "thermostat_ui", .module = uiModule(b, .{ .source = b.path("examples/mcu/thermostat.zge"), .zgec = zgec, .zigulee = zigulee_t, .target = t, .optimize = .ReleaseSmall, .style = "minimal" }) },
                    },
                }),
            });
        }
        for (demos) |d| d.root_module.addAnonymousImport("thermostat_font", .{ .root_source_file = thermostat_font });
        demos[0].entry = .{ .symbol_name = "_start" };
        demos[1].entry = .disabled;
        demos[1].rdynamic = true;
        const mcu_size = b.addExecutable(.{
            .name = "mcu-size",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/mcu_size.zig"), .target = b.graph.host }),
        });
        const run_size = b.addRunArtifact(mcu_size);
        run_size.addArtifactArg(demos[0]);
        run_size.addArtifactArg(demos[1]);
        run_size.addArg(b.findProgram(&.{"node"}, &.{}) catch "");
        if (b.args) |args| run_size.addArgs(args);
        run_size.has_side_effects = true;
        mcu_size_step.dependOn(&run_size.step);
    }

    // ESP32-S3 firmware (the Waveshare ESP32-S3-Touch-LCD-2,
    // examples/esp32s3): the MCU demo on a real display. Zig's LLVM has no
    // Xtensa backend, so the firmware is compiled to C (Zig's C backend),
    // then by Espressif's GCC (crosstool-NG xtensa-esp-elf, in
    // -Dxtensa-toolchain, default ~/esp/xtensa-esp-elf), and made into an
    // image the ROM bootloader loads into RAM (esptool). `zig build
    // esp32s3` builds zig-out/esp32s3/thermostat.bin, `esp32s3-flash`
    // writes it to the board (-Desp-port, default the first
    // /dev/cu.usbmodem*).
    {
        const home = b.graph.environ_map.get("HOME") orelse ".";
        const toolchain = b.option([]const u8, "xtensa-toolchain", "Espressif's xtensa-esp-elf toolchain (for zig build esp32s3)") orelse b.pathJoin(&.{ home, "esp", "xtensa-esp-elf" });
        const gcc = b.pathJoin(&.{ toolchain, "bin", "xtensa-esp32s3-elf-gcc" });
        const xtensa = b.resolveTargetQuery(.{ .cpu_arch = .xtensa, .os_tag = .freestanding, .ofmt = .c });
        const zigulee_x = b.createModule(.{
            .root_source_file = b.path("src/zigulee.zig"),
            .target = xtensa,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .unwind_tables = .none,
        });
        const firmware = b.createModule(.{
            .root_source_file = b.path("examples/esp32s3/thermostat.zig"),
            .target = xtensa,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .unwind_tables = .none,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee_x },
                .{ .name = "thermostat_ui", .module = uiModule(b, .{ .source = b.path("examples/mcu/thermostat.zge"), .zgec = zgec, .zigulee = zigulee_x, .target = xtensa, .optimize = .ReleaseSmall, .style = "minimal" }) },
            },
        });
        firmware.addAnonymousImport("thermostat_font", .{ .root_source_file = bitmapFont(b, .{ .font = b.path("examples/fonts/inter/Inter-Regular.ttf"), .sizes = &.{ 13, 14, 16, 40 }, .tool = bitmap_font_tool }) });
        const zig_c = b.addObject(.{ .name = "thermostat", .root_module = firmware }).getEmittedBin();
        // Zig takes f64 (in structs) as 4-byte aligned on Xtensa, GCC as 8:
        // the generated alignment checks go (the size checks stay, so the
        // layouts agree; Xtensa loads an f64 as two 32-bit words).
        const strip = b.addSystemCommand(&.{ "sed", "/incorrect alignment/d" });
        strip.addFileArg(zig_c);
        const c_source = strip.captureStdOut(.{ .basename = "thermostat.c" });

        // C17 (zig.h's C23 `[[noreturn]]` goes where GCC rejects it);
        // uint32_t and uintptr_t are distinct types of the same size here.
        const cflags = [_][]const u8{ "-std=gnu17", "-Os", "-mlongcalls", "-mtext-section-literals", "-ffunction-sections", "-fdata-sections", "-w", "-Wno-error=incompatible-pointer-types" };
        const compile = b.addSystemCommand(&.{gcc});
        compile.addArgs(&cflags);
        compile.addArgs(&.{ "-I", b.graph.zig_lib_directory.path orelse "." });
        compile.addArgs(&.{ "-fno-builtin-fminf", "-fno-builtin-fmaxf" });
        compile.addPrefixedFileArg("-include", b.path("examples/esp32s3/fast_math.h"));
        compile.addArg("-c");
        compile.addFileArg(c_source);
        compile.addArg("-o");
        const firmware_o = compile.addOutputFileArg("thermostat.o");
        const compile_start = b.addSystemCommand(&.{gcc});
        compile_start.addArgs(&cflags);
        compile_start.addArg("-c");
        compile_start.addFileArg(b.path("examples/esp32s3/start.c"));
        compile_start.addArg("-o");
        const start_o = compile_start.addOutputFileArg("start.o");
        const compile_runtime = b.addSystemCommand(&.{gcc});
        compile_runtime.addArgs(&cflags);
        compile_runtime.addArgs(&.{ "-I", b.graph.zig_lib_directory.path orelse "." });
        compile_runtime.addArg("-c");
        compile_runtime.addFileArg(b.path("examples/esp32s3/runtime.c"));
        compile_runtime.addArg("-o");
        const runtime_o = compile_runtime.addOutputFileArg("runtime.o");
        const link = b.addSystemCommand(&.{ gcc, "-nostartfiles", "-nostdlib", "-Wl,--gc-sections", "-Wl,--print-memory-usage" });
        link.addPrefixedFileArg("-T", b.path("examples/esp32s3/esp32s3.ld"));
        link.addFileArg(start_o);
        link.addFileArg(firmware_o);
        link.addFileArg(runtime_o);
        link.addArgs(&.{ "-lc", "-lm", "-lgcc", "-o" });
        const elf = link.addOutputFileArg("thermostat.elf");
        const image = b.addSystemCommand(&.{ "esptool", "--chip", "esp32s3", "elf2image", "--flash-mode", "dio", "--flash-freq", "80m", "--flash-size", "16MB", "-o" });
        const bin = image.addOutputFileArg("thermostat.bin");
        image.addFileArg(elf);
        _ = image.captureStdOut(.{});

        // The firmware's heap, tested on the host.
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("examples/esp32s3/heap.zig"), .target = target, .optimize = optimize }) })).step);

        // `zig build mcu-stress [-- heap-KB rounds]`: the demo under
        // stress as on the device (32-bit wasm, the firmware's heap), run by
        // Node.js (tools/mcu_stress.zig).
        {
            const wasm = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
            const zigulee_w = b.createModule(.{ .root_source_file = b.path("src/zigulee.zig"), .target = wasm, .optimize = .ReleaseSmall, .single_threaded = true });
            const stress = b.addExecutable(.{ .name = "mcu-stress", .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mcu_stress.zig"),
                .target = wasm,
                .optimize = .ReleaseSmall,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zigulee", .module = zigulee_w },
                    .{ .name = "thermostat_ui", .module = uiModule(b, .{ .source = b.path("examples/mcu/thermostat.zge"), .zgec = zgec, .zigulee = zigulee_w, .target = wasm, .optimize = .ReleaseSmall, .style = "minimal" }) },
                    .{ .name = "esp32s3_heap", .module = b.createModule(.{ .root_source_file = b.path("examples/esp32s3/heap.zig"), .target = wasm, .optimize = .ReleaseSmall }) },
                    .{ .name = "zigulee-interpreter", .module = b.createModule(.{ .root_source_file = b.path("src/zigulee_interpreter.zig"), .target = wasm, .optimize = .ReleaseSmall, .single_threaded = true, .imports = &.{.{ .name = "zigulee", .module = zigulee_w }} }) },
                },
            }) });
            stress.root_module.addAnonymousImport("thermostat_source", .{ .root_source_file = b.path("examples/mcu/thermostat.zge") });
            stress.root_module.addAnonymousImport("thermostat_font", .{ .root_source_file = bitmapFont(b, .{ .font = b.path("examples/fonts/inter/Inter-Regular.ttf"), .sizes = &.{ 13, 14, 16, 40 }, .tool = bitmap_font_tool }) });
            stress.entry = .disabled;
            stress.rdynamic = true;
            const node = b.addSystemCommand(&.{
                "node", "-e",
                \\const fs = require("fs");
                \\let mem;
                \\const log = (p, n) => console.log(Buffer.from(new Uint8Array(mem.buffer, p, n)).toString());
                \\const now = () => performance.now();
                \\WebAssembly.instantiate(fs.readFileSync(process.argv[1]), { env: { log, now } }).then((m) => {
                \\  mem = m.instance.exports.memory;
                \\  const failed = m.instance.exports.zigulee_mcu_stress(Number(process.argv[2] || 90), Number(process.argv[3] || 6), Number(process.argv[4] || 0));
                \\  process.exit(failed ? 1 : 0);
                \\});
            });
            node.addArtifactArg(stress);
            if (b.args) |args| node.addArgs(args);
            node.has_side_effects = true;
            b.step("mcu-stress", "The MCU demo under stress, 32-bit with the firmware's heap (Node.js) [-- heap-KB rounds interpreted]").dependOn(&node.step);
        }

        const esp_step = b.step("esp32s3", "Build the ESP32-S3 firmware (needs Espressif's toolchain and esptool)");
        esp_step.dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "esp32s3" }, "thermostat.bin").step);
        esp_step.dependOn(&b.addInstallFileWithDir(elf, .{ .custom = "esp32s3" }, "thermostat.elf").step);
        const port = b.option([]const u8, "esp-port", "The ESP32-S3's serial port (for zig build esp32s3-flash)");
        const flash = b.addSystemCommand(&.{ "sh", "-c", "port=${1:-$(ls /dev/cu.usbmodem* /dev/ttyACM* 2>/dev/null | head -1)}; exec esptool --chip esp32s3 --port \"$port\" --baud 921600 write-flash 0 \"$2\"", "flash", port orelse "" });
        flash.addFileArg(bin);
        flash.has_side_effects = true;
        b.step("esp32s3-flash", "Build the ESP32-S3 firmware and write it to the board").dependOn(&flash.step);
    }

    const check_mcu_step = b.step("check-mcu", "Compile the core for thumb-freestanding (Cortex-M4)");
    // Installing forces full code generation, not just semantic analysis.
    check_mcu_step.dependOn(&b.addInstallArtifact(mcu_lib, .{
        .dest_dir = .{ .override = .{ .custom = "mcu-check" } },
    }).step);
}

const WindowApps = struct {
    zigulee: *std.Build.Module,
    zgec: *std.Build.Step.Compile,
    interpreter: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    style: []const u8,
    examples_step: *std.Build.Step,
};

/// The windowed examples and the viewer, with `backend` (zigulee-sdl3 or
/// zigulee-macos, imported as "zigulee-backend").
fn windowApps(b: *std.Build, o: WindowApps, backend: *std.Build.Module) void {
    // Apps written in .zge, shown in windows.
    const window_examples = [_][]const u8{ "hello", "gallery", "todo", "patrisio", "video" };
    for (window_examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = o.target,
                .optimize = o.optimize,
                .imports = &.{
                    .{ .name = "zigulee", .module = o.zigulee },
                    .{ .name = "zigulee-backend", .module = backend },
                    .{ .name = b.fmt("{s}_ui", .{name}), .module = uiModule(b, .{
                        .source = b.path(b.fmt("examples/{s}.zge", .{name})),
                        .zgec = o.zgec,
                        .zigulee = o.zigulee,
                        .target = o.target,
                        .optimize = o.optimize,
                        .style = o.style,
                    }) },
                },
            }),
        });
        o.examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example (opens a window)", .{name})).dependOn(&run.step);
    }

    // The viewer: interprets a .zge file and reloads it on changes.
    const viewer = b.addExecutable(.{
        .name = "zigulee-viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zigulee_viewer.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = o.zigulee },
                .{ .name = "zigulee-backend", .module = backend },
                .{ .name = "zigulee-interpreter", .module = o.interpreter },
            },
        }),
    });
    inline for (.{
        .{ "inter_regular", "examples/fonts/inter/Inter-Regular.ttf" },
        .{ "inter_bold", "examples/fonts/inter/Inter-Bold.ttf" },
        .{ "jetbrains_mono", "examples/fonts/jetbrains-mono/JetBrainsMono-Regular.ttf" },
    }) |font| viewer.root_module.addAnonymousImport(font[0], .{ .root_source_file = b.path(font[1]) });
    b.installArtifact(viewer);
    const run_viewer = b.addRunArtifact(viewer);
    if (b.args) |args| run_viewer.addArgs(args);
    b.step("run-viewer", "Show a .zge file, reloading it on changes: zig build run-viewer -- file.zge").dependOn(&run_viewer.step);
}
