// counter.zig — compiled to wasm32-freestanding.
// Zig owns all counter state; JS is a dumb shim that calls these exports.

var count: i32 = 0;

export fn increment() void {
    count += 1;
}

export fn decrement() void {
    count -= 1;
}

export fn get_count() i32 {
    return count;
}

export fn reset() void {
    count = 0;
}
