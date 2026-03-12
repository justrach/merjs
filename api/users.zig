const std = @import("std");
const mer = @import("mer");

// ---------------------------------------------------------------------------
// Schema definitions using dhi (Pydantic-style)
// ---------------------------------------------------------------------------

/// Validated model for user creation. All constraints are checked at parse time.
const CreateUserModel = mer.dhi.Model("CreateUser", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});

/// Type-safe response struct — serialized to JSON via std.json.stringify.
const UserResponse = struct {
    id:     u32,
    name:   []const u8,
    email:  []const u8,
    age:    i32,
    score:  f64,
    status: []const u8,
};

const ValidationErrorResponse = struct {
    @"error":  []const u8,
    field:     []const u8,
    model:     []const u8,
};

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

pub fn render(req: mer.Request) mer.Response {
    // Simulate valid input coming in — parse validates all constraints.
    const valid = CreateUserModel.parse(.{
        .name  = "Alice Johnson",
        .email = "alice@example.com",
        .age   = @as(i32, 28),
        .score = @as(f64, 95.5),
    }) catch |err| {
        return mer.typedJson(req.allocator, ValidationErrorResponse{
            .@"error" = @errorName(err),
            .field    = "unknown",
            .model    = CreateUserModel.Name,
        });
    };

    return mer.typedJson(req.allocator, UserResponse{
        .id     = 1,
        .name   = valid.name,
        .email  = valid.email,
        .age    = valid.age,
        .score  = valid.score,
        .status = "active",
    });
}
