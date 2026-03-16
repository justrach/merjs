# Twitter Thread — Wavetable Synth (WASM + AudioWorklet)

---

**1/**
merjs now has a wavetable synthesizer.

the entire audio engine is Zig compiled to 6.8KB of WASM.
zero JS computes a single sample.

[attach: screen recording of synth being played]

---

**2/**
github.com/justrach/merjs

here is the entire DSP hot path.

sine, square, saw, tri. 8-voice polyphony. ADSR. lowpass filter.

```zig
export fn fill(n: u32, sr: f32) void {
    for (&voices) |*v| {
        for (buf[0..n]) |*out| {
            const raw = tbl[@intFromFloat(v.phase * N) & (N-1)];
            v.flt += alpha * (raw * v.level - v.flt);
            out.* += v.flt * vol / MAX_V;
        }
    }
}
```

150 lines. no allocations. no GC. just math.

---

**3/**
it runs inside an AudioWorklet.

AudioWorklet gets a dedicated audio thread, separate from the main thread.
no garbage collector can pause it.

the reason this matters: JS audio glitches when GC runs mid-note.
WASM does not have a GC.
problem gone.

---

**4/**
the entire AudioWorklet process() call:

```js
this.w.fill(ch.length, sampleRate);
const ptr = this.w.buf_ptr();
ch.set(new Float32Array(this.w.memory.buffer, ptr, ch.length));
```

three lines of JS. dispatch into Zig, copy output to audio graph.
all the DSP is Zig.

---

**5/**
the full merjs stack for this page:

server: Zig
router: Zig
SSR: Zig
audio DSP: Zig compiled to WASM

no Node. no npm. no node_modules. no runtime.
zig all the way down.

merlionjs.com/synth
github.com/justrach/merjs

---

*thread end*
