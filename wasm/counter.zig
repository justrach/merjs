// counter.zig — compiled to wasm32-freestanding.
// Zig owns all counter state; JS is a dumb shim that calls these exports.
// Bounds validated at comptime via counter_config.zig (Dhi-style constraints).

const cfg = @import("counter_config.zig").config;

var count: i32 = cfg.initial;

export fn increment() void {
    if (count <= cfg.max - cfg.step) {
        count += cfg.step;
    } else {
        count = cfg.max;
    }
}

export fn decrement() void {
    if (count >= cfg.min + cfg.step) {
        count -= cfg.step;
    } else {
        count = cfg.min;
    }
}

export fn get_count() i32 {
    return count;
}

export fn reset() void {
    count = cfg.initial;
}

export fn get_min() i32 {
    return cfg.min;
}

export fn get_max() i32 {
    return cfg.max;
}

export fn get_step() i32 {
    return cfg.step;
}
