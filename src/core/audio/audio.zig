// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Audio: clips (sound data, read in place: WAV files), a mixer that plays
//! them as voices, the interface a backend implements to play the
//! mixer's output, and the one it implements to capture sound
//! (`capture.zig`). The `Audio` element and
//! the `Sound` and `Music` components play through `mixer()`.
//!
//! A backend gives the mixer its output at startup:
//!
//!     zigulee.core.audio.mixer().setOutput(my_output);
//!
//! and the mixer starts it the first time something plays.

const mixer_mod = @import("mixer.zig");
const clip_mod = @import("clip.zig");

pub const Clip = clip_mod.Clip;
pub const SampleFormat = clip_mod.SampleFormat;
pub const wav = @import("wav.zig");
pub const Mixer = mixer_mod.Mixer;
pub const Feed = @import("feed.zig").Feed;
pub const Voice = mixer_mod.Voice;
pub const PlayOptions = mixer_mod.PlayOptions;
pub const Listener = mixer_mod.Listener;
pub const Output = mixer_mod.Output;
/// Sound from the microphone.
pub const capture = @import("capture.zig");
pub const Input = capture.Input;
pub const setInput = capture.setInput;
/// The `Microphone` element.
pub const Microphone = capture.Microphone;
pub const max_voices = mixer_mod.max_voices;
/// The `Audio` element.
pub const AudioElement = @import("element.zig").AudioElement;

var global: Mixer = .{};

/// The process's mixer (what the UI plays through).
pub fn mixer() *Mixer {
    return &global;
}

test {
    _ = mixer_mod;
    _ = clip_mod;
    _ = wav;
    _ = @import("feed.zig");
    _ = @import("element.zig");
    _ = capture;
}
