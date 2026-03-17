// counter_config.zig — Comptime-validated counter configuration.
// Shared between app/counter.zig (page) and wasm/counter.zig (WASM module).
// Dhi-style constraints enforced at compile time.

/// Counter bounds and behavior, validated at comptime.
pub const CounterConfig = struct {
    min: i32,
    max: i32,
    step: i32,
    initial: i32,

    /// Validate config at comptime with Dhi-style constraint checks.
    pub fn validate(comptime self: CounterConfig) CounterConfig {
        if (self.min >= self.max)
            @compileError("CounterConfig: min must be less than max");
        if (self.step <= 0)
            @compileError("CounterConfig: step must be positive (gt 0)");
        if (self.step > 100)
            @compileError("CounterConfig: step must be <= 100");
        if (self.min < -10_000)
            @compileError("CounterConfig: min must be >= -10000");
        if (self.max > 10_000)
            @compileError("CounterConfig: max must be <= 10000");
        if (self.initial < self.min or self.initial > self.max)
            @compileError("CounterConfig: initial must be within [min, max]");
        return self;
    }
};

/// The active counter configuration — change these values and the compiler
/// will validate them. Both the page UI and WASM module use this.
pub const config = (CounterConfig{
    .min = -100,
    .max = 100,
    .step = 1,
    .initial = 0,
}).validate();
