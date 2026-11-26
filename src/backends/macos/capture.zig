// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The microphone and the camera with AVFoundation (macOS): a capture
//! session each, for the default device, delivering sample buffers on a
//! queue of its own. Camera frames come as BGRA and go to the core as
//! RGBA; the microphone's sound as 48 kHz mono floats.
//!
//! Sessions start on their queue (starting takes a while), after the user
//! allowed the device: the first time, macOS asks (an app bundle needs
//! `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in its
//! Info.plist). Refused, it delivers nothing.

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("zigulee-apple").objc;
const audio = zigulee.core.audio;
const camera = zigulee.core.camera;
const Rgba8 = zigulee.core.Rgba8;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const class = objc.class;

const log = std.log.scoped(.zigulee_macos);

extern "c" fn CMSampleBufferGetImageBuffer(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CMSampleBufferGetDataBuffer(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CMBlockBufferGetDataLength(bb: ?*anyopaque) usize;
extern "c" fn CMBlockBufferCopyDataBytes(bb: ?*anyopaque, offset: usize, length: usize, dest: *anyopaque) i32;
extern "c" fn CVPixelBufferLockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: ?*anyopaque) ?[*]const u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetWidth(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetHeight(pb: ?*anyopaque) usize;

extern const kCVPixelBufferPixelFormatTypeKey: id;
extern const AVMediaTypeVideo: id;
extern const AVMediaTypeAudio: id;
extern const AVFormatIDKey: id;
extern const AVSampleRateKey: id;
extern const AVNumberOfChannelsKey: id;
extern const AVLinearPCMBitDepthKey: id;
extern const AVLinearPCMIsFloatKey: id;
extern const AVLinearPCMIsNonInterleaved: id;
extern const AVLinearPCMIsBigEndianKey: id;

const pixel_format_bgra = 0x42475241; // 'BGRA'
const audio_format_pcm = 0x6c70636d; // 'lpcm'
const rate = 48000;
const read_only_lock = 1;

const authorization_not_determined = 0;
const authorization_authorized = 3;

fn number(v: u32) id {
    return msg(id, class("NSNumber"), "numberWithUnsignedInt:", .{v});
}

/// A capture session for one kind of device, and what it delivers to.
const Capture = struct {
    kind: enum { video, audio },
    queue: objc.dispatch_queue_t = null,
    session: id = null,
    output: id = null,
    /// Camera: where frames go.
    frames: ?*const camera.Provider.Sink = null,
    /// Microphone: where sound goes.
    sound: ?*const audio.Input.Sink = null,
    /// The queue's: pixels converted, samples read.
    pixels: std.ArrayList(Rgba8) = .empty,
    samples: std.ArrayList(f32) = .empty,

    fn mediaType(self: *const Capture) id {
        return if (self.kind == .video) AVMediaTypeVideo else AVMediaTypeAudio;
    }

    /// Sets up the session for the default device (not started yet).
    fn open(self: *Capture) bool {
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const device = msg(id, class("AVCaptureDevice"), "defaultDeviceWithMediaType:", .{self.mediaType()});
        if (device == null) {
            log.info("no {s} device", .{if (self.kind == .video) "camera" else "microphone"});
            return false;
        }
        var err: id = null;
        const input = msg(id, class("AVCaptureDeviceInput"), "deviceInputWithDevice:error:", .{ device, &err });
        if (input == null) {
            log.info("cannot open the {s}: {s}", .{ if (self.kind == .video) "camera" else "microphone", objc.utf8(msg(id, err, "localizedDescription", .{})) });
            return false;
        }
        const session = msg(id, msg(id, class("AVCaptureSession"), "alloc", .{}), "init", .{});
        if (!msg(bool, session, "canAddInput:", .{input})) {
            msg(void, session, "release", .{});
            return false;
        }
        msg(void, session, "addInput:", .{input});
        self.queue = objc.dispatch_queue_create(if (self.kind == .video) "zigulee.camera" else "zigulee.microphone", null);
        const output = if (self.kind == .video) blk: {
            const out = msg(id, msg(id, class("AVCaptureVideoDataOutput"), "alloc", .{}), "init", .{});
            const settings = msg(id, class("NSMutableDictionary"), "dictionary", .{});
            msg(void, settings, "setObject:forKey:", .{ number(pixel_format_bgra), kCVPixelBufferPixelFormatTypeKey });
            msg(void, out, "setVideoSettings:", .{settings});
            msg(void, out, "setAlwaysDiscardsLateVideoFrames:", .{true});
            break :blk out;
        } else blk: {
            const out = msg(id, msg(id, class("AVCaptureAudioDataOutput"), "alloc", .{}), "init", .{});
            const settings = msg(id, class("NSMutableDictionary"), "dictionary", .{});
            msg(void, settings, "setObject:forKey:", .{ number(audio_format_pcm), AVFormatIDKey });
            msg(void, settings, "setObject:forKey:", .{ number(rate), AVSampleRateKey });
            msg(void, settings, "setObject:forKey:", .{ number(1), AVNumberOfChannelsKey });
            msg(void, settings, "setObject:forKey:", .{ number(32), AVLinearPCMBitDepthKey });
            msg(void, settings, "setObject:forKey:", .{ number(1), AVLinearPCMIsFloatKey });
            msg(void, settings, "setObject:forKey:", .{ number(0), AVLinearPCMIsNonInterleaved });
            msg(void, settings, "setObject:forKey:", .{ number(0), AVLinearPCMIsBigEndianKey });
            msg(void, out, "setAudioSettings:", .{settings});
            break :blk out;
        };
        msg(void, output, "setSampleBufferDelegate:queue:", .{ delegate(), self.queue });
        if (!msg(bool, session, "canAddOutput:", .{output})) {
            msg(void, output, "release", .{});
            msg(void, session, "release", .{});
            objc.dispatch_release(self.queue);
            self.queue = null;
            return false;
        }
        msg(void, session, "addOutput:", .{output});
        self.session = session;
        self.output = output;
        return true;
    }

    /// Starts the session on its queue, once the device is allowed.
    fn start(self: *Capture) void {
        const status = msg(isize, class("AVCaptureDevice"), "authorizationStatusForMediaType:", .{self.mediaType()});
        switch (status) {
            authorization_authorized => objc.dispatch_async_f(self.queue, self, startRunning),
            authorization_not_determined => msg(void, class("AVCaptureDevice"), "requestAccessForMediaType:completionHandler:", .{
                self.mediaType(),
                if (self.kind == .video) &video_allowed else &audio_allowed,
            }),
            else => log.info("the {s} is not allowed (System Settings, Privacy & Security)", .{if (self.kind == .video) "camera" else "microphone"}),
        }
    }

    fn startRunning(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.session != null) msg(void, self.session, "startRunning", .{});
    }

    fn stopRunning(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        msg(void, self.session, "stopRunning", .{});
        msg(void, self.output, "setSampleBufferDelegate:queue:", .{ @as(id, null), @as(objc.dispatch_queue_t, null) });
    }

    /// Stops and lets the session go. On the queue, after any start and
    /// any delivery: when it returns, nothing more is delivered.
    fn close(self: *Capture) void {
        if (self.session == null) return;
        objc.dispatch_sync_f(self.queue, self, stopRunning);
        msg(void, self.output, "release", .{});
        msg(void, self.session, "release", .{});
        objc.dispatch_release(self.queue);
        self.* = .{ .kind = self.kind, .pixels = self.pixels, .samples = self.samples };
        self.frames = null;
        self.sound = null;
    }

    /// The queue: a camera frame.
    fn frame(self: *Capture, sbuf: ?*anyopaque) void {
        const sink = self.frames orelse return;
        const pb = CMSampleBufferGetImageBuffer(sbuf) orelse return;
        if (CVPixelBufferLockBaseAddress(pb, read_only_lock) != 0) return;
        defer _ = CVPixelBufferUnlockBaseAddress(pb, read_only_lock);
        const base = CVPixelBufferGetBaseAddress(pb) orelse return;
        const w = CVPixelBufferGetWidth(pb);
        const h = CVPixelBufferGetHeight(pb);
        const stride = CVPixelBufferGetBytesPerRow(pb);
        self.pixels.resize(std.heap.c_allocator, w * h) catch return;
        for (0..h) |y| {
            const row = base[y * stride ..][0 .. w * 4];
            for (self.pixels.items[y * w ..][0..w], 0..) |*p, x|
                p.* = .{ .r = row[x * 4 + 2], .g = row[x * 4 + 1], .b = row[x * 4], .a = 255 };
        }
        sink.frame(sink.ctx, self.pixels.items, @intCast(w), @intCast(h));
    }

    /// The queue: sound (mono floats, as asked).
    fn heard(self: *Capture, sbuf: ?*anyopaque) void {
        const sink = self.sound orelse return;
        const bb = CMSampleBufferGetDataBuffer(sbuf) orelse return;
        const len = CMBlockBufferGetDataLength(bb);
        self.samples.resize(std.heap.c_allocator, len / @sizeOf(f32)) catch return;
        if (self.samples.items.len == 0) return;
        if (CMBlockBufferCopyDataBytes(bb, 0, self.samples.items.len * @sizeOf(f32), self.samples.items.ptr) != 0) return;
        sink.write(sink.ctx, self.samples.items, 1);
    }
};

var video: Capture = .{ .kind = .video };
var sound: Capture = .{ .kind = .audio };

var video_allowed: objc.Block = .global(&videoAllowed);
var audio_allowed: objc.Block = .global(&audioAllowed);

/// The user answered (on another thread).
fn videoAllowed(_: *objc.Block, granted: bool) callconv(.c) void {
    allowed(&video, granted);
}
fn audioAllowed(_: *objc.Block, granted: bool) callconv(.c) void {
    allowed(&sound, granted);
}
fn allowed(c: *Capture, granted: bool) void {
    if (!granted) return log.info("the {s} was not allowed", .{if (c.kind == .video) "camera" else "microphone"});
    // On the main thread, where it may have been closed meanwhile.
    objc.dispatch_async_f(objc.mainQueue(), c, startIfOpen);
}

fn startIfOpen(ctx: ?*anyopaque) callconv(.c) void {
    const c: *Capture = @ptrCast(@alignCast(ctx));
    if (c.queue != null) objc.dispatch_async_f(c.queue, c, Capture.startRunning);
}

var delegate_object: id = null;

/// The sample buffer delegate of both sessions.
fn delegate() id {
    if (delegate_object) |d| return d;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeCaptureDelegate", 0);
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("AVCaptureVideoDataOutputSampleBufferDelegate"));
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("AVCaptureAudioDataOutputSampleBufferDelegate"));
    _ = objc.class_addMethod(cls, objc.sel("captureOutput:didOutputSampleBuffer:fromConnection:"), @ptrCast(&delivered), "v@:@^{opaqueCMSampleBuffer=}@");
    objc.objc_registerClassPair(cls);
    delegate_object = msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    return delegate_object;
}

fn delivered(_: id, _: SEL, output: id, sbuf: ?*anyopaque, _: id) callconv(.c) void {
    if (output != null and output == video.output) {
        video.frame(sbuf);
    } else if (output != null and output == sound.output) {
        sound.heard(sbuf);
    }
}

// ---- The providers ----

pub const camera_provider: camera.Provider = .{ .ctx = null, .vtable = &.{ .start = cameraStart, .stop = cameraStop } };

fn cameraStart(_: ?*anyopaque, sink: *const camera.Provider.Sink) camera.Provider.Error!void {
    if (!video.open()) return error.CameraUnavailable;
    video.frames = sink;
    video.start();
}

fn cameraStop(_: ?*anyopaque) void {
    video.close();
}

pub const microphone: audio.Input = .{ .ctx = null, .vtable = &.{ .start = micStart, .stop = micStop } };

fn micStart(_: ?*anyopaque, sink: *const audio.Input.Sink) audio.Input.Error!u32 {
    if (!sound.open()) return error.AudioUnavailable;
    sound.sound = sink;
    sound.start();
    return rate;
}

fn micStop(_: ?*anyopaque) void {
    sound.close();
}

test "the capture delegate's class" {
    // No device is opened here (that would ask the user): only the class
    // AVFoundation calls.
    const d = delegate();
    try std.testing.expect(msg(bool, d, "respondsToSelector:", .{objc.sel("captureOutput:didOutputSampleBuffer:fromConnection:")}));
}
