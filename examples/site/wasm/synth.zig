// synth.zig — Wavetable synthesizer engine.
// Compiled to wasm32-freestanding, loaded inside an AudioWorklet.
// Zero heap allocations; all state is static globals.

const std = @import("std");

// ── Wavetables (precomputed at comptime) ─────────────────────────────────────
const N: usize = 256;

const sine: [N]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [N]f32 = undefined;
    for (0..N) |i| {
        const p: f64 = @as(f64, @floatFromInt(i)) / @as(f64, N);
        t[i] = @floatCast(@sin(2.0 * std.math.pi * p));
    }
    break :blk t;
};

const square: [N]f32 = blk: {
    var t: [N]f32 = undefined;
    for (0..N) |i| t[i] = if (i < N / 2) @as(f32, 1.0) else @as(f32, -1.0);
    break :blk t;
};

const saw: [N]f32 = blk: {
    var t: [N]f32 = undefined;
    for (0..N) |i| t[i] = 2.0 * (@as(f32, @floatFromInt(i)) / @as(f32, N)) - 1.0;
    break :blk t;
};

const tri: [N]f32 = blk: {
    var t: [N]f32 = undefined;
    for (0..N) |i| {
        const x: f32 = @as(f32, @floatFromInt(i)) / @as(f32, N);
        t[i] = if (x < 0.5) 4.0 * x - 1.0 else 3.0 - 4.0 * x;
    }
    break :blk t;
};

// ── Voice state ───────────────────────────────────────────────────────────────
const MAX_V: usize = 8;
const Stage = enum { idle, attack, decay, sustain, release };

const Voice = struct {
    on: bool = false,
    note: u8 = 0,
    phase: f32 = 0,
    freq: f32 = 0,
    stage: Stage = .idle,
    level: f32 = 0,
    flt: f32 = 0, // one-pole lowpass state
};

var voices: [MAX_V]Voice = [_]Voice{.{}} ** MAX_V;

// ── Global params ─────────────────────────────────────────────────────────────
var wave: u8 = 0; // 0=sine 1=square 2=saw 3=tri
var atk: f32 = 0.01; // attack seconds
var dec: f32 = 0.15; // decay seconds
var sus: f32 = 0.7; // sustain level 0..1
var rel: f32 = 0.4; // release seconds
var flt_c: f32 = 0.9; // filter cutoff 0..1
var vol: f32 = 0.8; // master volume 0..1

// ── Output buffer (JS reads via WASM memory pointer) ─────────────────────────
var buf: [4096]f32 = undefined;

export fn buf_ptr() [*]f32 {
    return &buf;
}

// ── Note helpers ──────────────────────────────────────────────────────────────
fn midiFreq(note: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

export fn note_on(note: u8, vel: u8) void {
    _ = vel;
    for (&voices) |*v| {
        if (!v.on) {
            v.* = .{ .on = true, .note = note, .phase = 0, .freq = midiFreq(note), .stage = .attack, .level = 0, .flt = 0 };
            return;
        }
    }
    // Steal voice 0
    voices[0] = .{ .on = true, .note = note, .phase = 0, .freq = midiFreq(note), .stage = .attack, .level = 0, .flt = 0 };
}

export fn note_off(note: u8) void {
    for (&voices) |*v| {
        if (v.on and v.note == note and v.stage != .release) v.stage = .release;
    }
}

// ── Param setters ─────────────────────────────────────────────────────────────
export fn set_wave(w: u8) void {
    wave = if (w < 4) w else 0;
}
export fn set_atk(v: f32) void {
    atk = if (v < 0.001) 0.001 else v;
}
export fn set_dec(v: f32) void {
    dec = if (v < 0.001) 0.001 else v;
}
export fn set_sus(v: f32) void {
    sus = if (v < 0) 0 else if (v > 1) 1 else v;
}
export fn set_rel(v: f32) void {
    rel = if (v < 0.001) 0.001 else v;
}
export fn set_flt(v: f32) void {
    flt_c = if (v < 0) 0 else if (v > 1) 1 else v;
}
export fn set_vol(v: f32) void {
    vol = if (v < 0) 0 else if (v > 1) 1 else v;
}

// ── Main audio fill (called by AudioWorklet process()) ────────────────────────
export fn fill(n: u32, sr: f32) void {
    const len = if (n < buf.len) n else buf.len;
    for (buf[0..len]) |*s| s.* = 0;

    // One-pole lowpass coefficient: maps 0..1 → nearly closed..nearly open
    const alpha: f32 = flt_c * flt_c * 0.97 + 0.02;
    // Per-sample release decrement (always rel seconds to reach 0 from any level)
    const r_step: f32 = 1.0 / (rel * sr + 1.0);

    for (&voices) |*v| {
        if (!v.on) continue;

        const pinc: f32 = v.freq / sr;
        const a_step: f32 = 1.0 / (atk * sr + 1.0);
        const d_step: f32 = (1.0 - sus) / (dec * sr + 1.0);

        const tbl: *const [N]f32 = switch (wave) {
            1 => &square,
            2 => &saw,
            3 => &tri,
            else => &sine,
        };

        for (buf[0..len]) |*out| {
            const idx: usize = @as(usize, @intFromFloat(v.phase * @as(f32, N))) & (N - 1);
            const raw: f32 = tbl[idx];

            switch (v.stage) {
                .attack => {
                    v.level += a_step;
                    if (v.level >= 1.0) {
                        v.level = 1.0;
                        v.stage = .decay;
                    }
                },
                .decay => {
                    v.level -= d_step;
                    if (v.level <= sus) {
                        v.level = sus;
                        v.stage = .sustain;
                    }
                },
                .sustain => {},
                .release => {
                    v.level -= r_step;
                    if (v.level <= 0.0) {
                        v.level = 0;
                        v.stage = .idle;
                        v.on = false;
                    }
                },
                .idle => {},
            }

            v.flt += alpha * (raw * v.level - v.flt);
            out.* += v.flt * vol / @as(f32, MAX_V);

            v.phase += pinc;
            if (v.phase >= 1.0) v.phase -= 1.0;
        }
    }
}
