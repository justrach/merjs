//! Email hook interface and template builders for merjs-auth.
//!
//! merjs-auth does not send email directly. Instead it builds an
//! `EmailMessage` and calls your `SendEmailFn`. Wire up your mail provider
//! (Resend, Postmark, SendGrid, etc.) by providing that function.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Types ──────────────────────────────────────────────────────────────────

pub const TemplateType = enum {
    welcome,
    verify_email,
    password_reset,
    magic_link,
};

pub const EmailMessage = struct {
    to: []const u8,
    subject: []const u8,
    html_body: []const u8,
    text_body: []const u8,
    template_type: TemplateType,
};

/// Your mail-sending implementation. Receives a fully-built EmailMessage
/// and is responsible for delivery. Return an error on failure; merjs-auth
/// will surface it to the caller.
pub const SendEmailFn = *const fn (msg: EmailMessage, alloc: Allocator) anyerror!void;

// ── Template builders ──────────────────────────────────────────────────────
// All allocate with `alloc`; use an arena so the entire message can be freed
// at once after sending.

/// Build a "verify your email" message containing a one-time token link.
/// `base_url` e.g. "https://app.example.com", `token` is the raw 64-char hex.
pub fn buildVerifyEmail(alloc: Allocator, base_url: []const u8, token: []const u8) !EmailMessage {
    const link = try std.fmt.allocPrint(alloc, "{s}/auth/verify-email?token={s}", .{ base_url, token });

    const html = try std.fmt.allocPrint(alloc,
        \\<!doctype html><html><body>
        \\<h2>Verify your email address</h2>
        \\<p>Click the link below to verify your email. This link expires in 24 hours.</p>
        \\<p><a href="{s}">{s}</a></p>
        \\<p>If you did not create an account, you can safely ignore this email.</p>
        \\</body></html>
    , .{ link, link });

    const text = try std.fmt.allocPrint(alloc,
        \\Verify your email address
        \\
        \\Click the link below to verify your email (expires in 24 hours):
        \\{s}
        \\
        \\If you did not create an account, you can safely ignore this email.
    , .{link});

    return EmailMessage{
        .to = "", // caller must set .to after construction
        .subject = "Verify your email address",
        .html_body = html,
        .text_body = text,
        .template_type = .verify_email,
    };
}

/// Build a "reset your password" message.
/// `token` is the raw 64-char hex (expires in 1 hour).
pub fn buildPasswordReset(alloc: Allocator, base_url: []const u8, token: []const u8) !EmailMessage {
    const link = try std.fmt.allocPrint(alloc, "{s}/auth/reset-password?token={s}", .{ base_url, token });

    const html = try std.fmt.allocPrint(alloc,
        \\<!doctype html><html><body>
        \\<h2>Reset your password</h2>
        \\<p>Click the link below to reset your password. This link expires in 1 hour.</p>
        \\<p><a href="{s}">{s}</a></p>
        \\<p>If you did not request a password reset, you can safely ignore this email.</p>
        \\</body></html>
    , .{ link, link });

    const text = try std.fmt.allocPrint(alloc,
        \\Reset your password
        \\
        \\Click the link below to reset your password (expires in 1 hour):
        \\{s}
        \\
        \\If you did not request a password reset, you can safely ignore this email.
    , .{link});

    return EmailMessage{
        .to = "",
        .subject = "Reset your password",
        .html_body = html,
        .text_body = text,
        .template_type = .password_reset,
    };
}

/// Build a magic-link sign-in message.
/// `token` is the raw 64-char hex (expires in 15 minutes).
pub fn buildMagicLink(alloc: Allocator, base_url: []const u8, token: []const u8) !EmailMessage {
    const link = try std.fmt.allocPrint(alloc, "{s}/auth/magic-link?token={s}", .{ base_url, token });

    const html = try std.fmt.allocPrint(alloc,
        \\<!doctype html><html><body>
        \\<h2>Sign in to your account</h2>
        \\<p>Click the link below to sign in. This link expires in 15 minutes and can only be used once.</p>
        \\<p><a href="{s}">{s}</a></p>
        \\<p>If you did not request this link, you can safely ignore this email.</p>
        \\</body></html>
    , .{ link, link });

    const text = try std.fmt.allocPrint(alloc,
        \\Sign in to your account
        \\
        \\Click the link below to sign in (expires in 15 minutes, one-time use):
        \\{s}
        \\
        \\If you did not request this link, you can safely ignore this email.
    , .{link});

    return EmailMessage{
        .to = "",
        .subject = "Your sign-in link",
        .html_body = html,
        .text_body = text,
        .template_type = .magic_link,
    };
}

/// Build a welcome email for a newly created account.
pub fn buildWelcome(alloc: Allocator, name: []const u8, email: []const u8) !EmailMessage {
    const html = try std.fmt.allocPrint(alloc,
        \\<!doctype html><html><body>
        \\<h2>Welcome, {s}!</h2>
        \\<p>Your account has been created with the email address <strong>{s}</strong>.</p>
        \\<p>We're glad you're here.</p>
        \\</body></html>
    , .{ name, email });

    const text = try std.fmt.allocPrint(alloc,
        \\Welcome, {s}!
        \\
        \\Your account has been created with the email address: {s}
        \\
        \\We're glad you're here.
    , .{ name, email });

    return EmailMessage{
        .to = email,
        .subject = try std.fmt.allocPrint(alloc, "Welcome, {s}!", .{name}),
        .html_body = html,
        .text_body = text,
        .template_type = .welcome,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "buildVerifyEmail contains token in link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msg = try buildVerifyEmail(alloc, "https://example.com", "abc123token");
    try std.testing.expect(std.mem.indexOf(u8, msg.html_body, "abc123token") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.text_body, "abc123token") != null);
    try std.testing.expectEqual(TemplateType.verify_email, msg.template_type);
}

test "buildWelcome sets .to field to email" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msg = try buildWelcome(alloc, "Alice", "alice@example.com");
    try std.testing.expectEqualStrings("alice@example.com", msg.to);
    try std.testing.expectEqual(TemplateType.welcome, msg.template_type);
}
