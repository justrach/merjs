//! Security-hardened SAX-style XML parser for SAML 2.0 responses.
//!
//! Design goals:
//!   - Zero heap allocation in the parser state machine itself.
//!   - Callback-driven (SAX) so callers accumulate only what they need.
//!   - Strict security limits enforced before and during parsing.
//!   - Namespace prefix stripping so callers can match on local names.
//!
//! Security limits:
//!   - Document size:         64 KiB  (error.DocumentTooLarge)
//!   - Nesting depth:         16      (error.NestingTooDeep)
//!   - Element name length:   128 B   (error.ElementNameTooLong)
//!   - Text content per node: 8 KiB   (error.TextTooLong)
//!   - DTD declarations:      banned  (error.DoctypeNotAllowed)
//!   - External entities:     banned  (error.ExternalEntityNotAllowed)

const std = @import("std");
const Allocator = std.mem.Allocator;
const saml_schema = @import("schema.zig");

pub const ParseError = error{
    DocumentTooLarge,
    NestingTooDeep,
    ElementNameTooLong,
    TextTooLong,
    DoctypeNotAllowed,
    ExternalEntityNotAllowed,
    MalformedXml,
    UnexpectedEof,
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    /// Local name with namespace prefix stripped.
    local_name: []const u8,
    attrs: []const Attr,
};

pub const EventType = enum { element_start, element_end, text };

pub const Event = union(EventType) {
    element_start: Element,
    element_end: struct { local_name: []const u8 },
    text: []const u8,
};

const MAX_DOCUMENT_SIZE: usize = 65536;
const MAX_NESTING_DEPTH: usize = 16;
const MAX_ELEMENT_NAME_LEN: usize = 128;
const MAX_TEXT_LEN: usize = 8192;
const MAX_ATTRS_PER_ELEMENT: usize = 32;

fn stripPrefix(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| return name[colon + 1 ..];
    return name;
}

inline fn isWS(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

inline fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

inline fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':' or c == '-' or c == '.';
}

fn unescapeXml(src: []const u8, buf: []u8) usize {
    var wi: usize = 0;
    var ri: usize = 0;
    while (ri < src.len and wi < buf.len) {
        if (src[ri] != '&') {
            buf[wi] = src[ri];
            wi += 1;
            ri += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, src, ri + 1, ';') orelse {
            buf[wi] = src[ri];
            wi += 1;
            ri += 1;
            continue;
        };
        const ent = src[ri + 1 .. semi];
        var consumed = true;
        if (std.mem.eql(u8, ent, "amp")) {
            buf[wi] = '&';
            wi += 1;
        } else if (std.mem.eql(u8, ent, "lt")) {
            buf[wi] = '<';
            wi += 1;
        } else if (std.mem.eql(u8, ent, "gt")) {
            buf[wi] = '>';
            wi += 1;
        } else if (std.mem.eql(u8, ent, "quot")) {
            buf[wi] = '"';
            wi += 1;
        } else if (std.mem.eql(u8, ent, "apos")) {
            buf[wi] = '\'';
            wi += 1;
        } else if (ent.len > 1 and ent[0] == '#') {
            const ns = ent[1..];
            var ok = true;
            const cp: u21 = blk: {
                if (ns.len > 1 and (ns[0] == 'x' or ns[0] == 'X')) {
                    break :blk @intCast(std.fmt.parseInt(u32, ns[1..], 16) catch {
                        ok = false;
                        break :blk 0;
                    });
                }
                break :blk @intCast(std.fmt.parseInt(u32, ns, 10) catch {
                    ok = false;
                    break :blk 0;
                });
            };
            if (ok) {
                wi += std.unicode.utf8Encode(cp, buf[wi..]) catch 1;
            } else consumed = false;
        } else {
            consumed = false;
        }
        if (consumed) ri = semi + 1 else {
            buf[wi] = src[ri];
            wi += 1;
            ri += 1;
        }
    }
    return wi;
}

/// Callback-based SAX parser.
pub fn parse(
    xml: []const u8,
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, event: Event) ParseError!void,
) ParseError!void {
    if (xml.len > MAX_DOCUMENT_SIZE) return error.DocumentTooLarge;
    if (std.mem.indexOf(u8, xml, "<!DOCTYPE") != null) return error.DoctypeNotAllowed;
    if (std.mem.indexOf(u8, xml, "<!ENTITY") != null) {
        if (std.mem.indexOf(u8, xml, "SYSTEM") != null or std.mem.indexOf(u8, xml, "PUBLIC") != null)
            return error.ExternalEntityNotAllowed;
    }

    var pos: usize = 0;
    var depth: usize = 0;

    var attr_name_bufs: [MAX_ATTRS_PER_ELEMENT][MAX_ELEMENT_NAME_LEN]u8 = undefined;
    var attr_val_bufs: [MAX_ATTRS_PER_ELEMENT][MAX_TEXT_LEN]u8 = undefined;
    var attr_name_lens: [MAX_ATTRS_PER_ELEMENT]usize = [_]usize{0} ** MAX_ATTRS_PER_ELEMENT;
    var attr_val_lens: [MAX_ATTRS_PER_ELEMENT]usize = [_]usize{0} ** MAX_ATTRS_PER_ELEMENT;
    var attrs_scratch: [MAX_ATTRS_PER_ELEMENT]Attr = undefined;
    var text_buf: [MAX_TEXT_LEN]u8 = undefined;
    var text_len: usize = 0;

    while (pos < xml.len) {
        const c = xml[pos];
        if (c == '<') {
            if (text_len > 0) {
                var unesc: [MAX_TEXT_LEN]u8 = undefined;
                const ulen = unescapeXml(text_buf[0..text_len], &unesc);
                try callback(ctx, .{ .text = unesc[0..ulen] });
                text_len = 0;
            }
            if (pos + 1 >= xml.len) return error.UnexpectedEof;

            // Comment
            if (pos + 3 < xml.len and xml[pos + 1] == '!' and xml[pos + 2] == '-' and xml[pos + 3] == '-') {
                pos += 4;
                var found = false;
                while (pos + 2 < xml.len) : (pos += 1) {
                    if (xml[pos] == '-' and xml[pos + 1] == '-' and xml[pos + 2] == '>') {
                        pos += 3;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnexpectedEof;
                continue;
            }
            // CDATA
            if (pos + 8 < xml.len and std.mem.startsWith(u8, xml[pos..], "<![CDATA[")) {
                pos += 9;
                const cs = pos;
                var found = false;
                while (pos + 2 < xml.len) : (pos += 1) {
                    if (xml[pos] == ']' and xml[pos + 1] == ']' and xml[pos + 2] == '>') {
                        const cd = xml[cs..pos];
                        if (text_len + cd.len > MAX_TEXT_LEN) return error.TextTooLong;
                        @memcpy(text_buf[text_len .. text_len + cd.len], cd);
                        text_len += cd.len;
                        try callback(ctx, .{ .text = text_buf[0..text_len] });
                        text_len = 0;
                        pos += 3;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnexpectedEof;
                continue;
            }
            // PI
            if (xml[pos + 1] == '?') {
                pos += 2;
                var found = false;
                while (pos + 1 < xml.len) : (pos += 1) {
                    if (xml[pos] == '?' and xml[pos + 1] == '>') {
                        pos += 2;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnexpectedEof;
                continue;
            }
            // Closing tag
            if (xml[pos + 1] == '/') {
                pos += 2;
                while (pos < xml.len and isWS(xml[pos])) pos += 1;
                const ns = pos;
                while (pos < xml.len and isNameChar(xml[pos])) pos += 1;
                const rn = xml[ns..pos];
                if (rn.len == 0) return error.MalformedXml;
                while (pos < xml.len and xml[pos] != '>') pos += 1;
                if (pos >= xml.len) return error.UnexpectedEof;
                pos += 1;
                if (depth == 0) return error.MalformedXml;
                depth -= 1;
                try callback(ctx, .{ .element_end = .{ .local_name = stripPrefix(rn) } });
                continue;
            }
            // Opening tag
            pos += 1;
            while (pos < xml.len and isWS(xml[pos])) pos += 1;
            if (pos >= xml.len) return error.UnexpectedEof;
            if (!isNameStart(xml[pos])) return error.MalformedXml;
            const ens = pos;
            while (pos < xml.len and isNameChar(xml[pos])) pos += 1;
            const ren = xml[ens..pos];
            if (ren.len > MAX_ELEMENT_NAME_LEN) return error.ElementNameTooLong;
            const le = stripPrefix(ren);

            var na: usize = 0;
            while (pos < xml.len) {
                while (pos < xml.len and isWS(xml[pos])) pos += 1;
                if (pos >= xml.len) return error.UnexpectedEof;
                if (xml[pos] == '/' or xml[pos] == '>') break;
                if (!isNameStart(xml[pos])) return error.MalformedXml;
                const ans = pos;
                while (pos < xml.len and isNameChar(xml[pos])) pos += 1;
                const ran = xml[ans..pos];
                if (ran.len > MAX_ELEMENT_NAME_LEN) return error.ElementNameTooLong;
                while (pos < xml.len and isWS(xml[pos])) pos += 1;
                if (pos >= xml.len or xml[pos] != '=') return error.MalformedXml;
                pos += 1;
                while (pos < xml.len and isWS(xml[pos])) pos += 1;
                if (pos >= xml.len) return error.UnexpectedEof;
                const q = xml[pos];
                if (q != '"' and q != '\'') return error.MalformedXml;
                pos += 1;
                const vs = pos;
                while (pos < xml.len and xml[pos] != q) pos += 1;
                if (pos >= xml.len) return error.UnexpectedEof;
                const rv = xml[vs..pos];
                pos += 1;
                if (na < MAX_ATTRS_PER_ELEMENT) {
                    const al = stripPrefix(ran);
                    const alen = @min(al.len, MAX_ELEMENT_NAME_LEN);
                    @memcpy(attr_name_bufs[na][0..alen], al[0..alen]);
                    attr_name_lens[na] = alen;
                    attr_val_lens[na] = unescapeXml(rv, &attr_val_bufs[na]);
                    na += 1;
                }
            }
            for (0..na) |i| {
                attrs_scratch[i] = .{
                    .name = attr_name_bufs[i][0..attr_name_lens[i]],
                    .value = attr_val_bufs[i][0..attr_val_lens[i]],
                };
            }
            const sc = pos < xml.len and xml[pos] == '/';
            if (sc) {
                pos += 1;
                if (pos >= xml.len or xml[pos] != '>') return error.MalformedXml;
                pos += 1;
            } else {
                if (pos >= xml.len or xml[pos] != '>') return error.MalformedXml;
                pos += 1;
            }
            if (!sc) {
                if (depth >= MAX_NESTING_DEPTH) return error.NestingTooDeep;
                depth += 1;
            }
            try callback(ctx, .{ .element_start = .{ .local_name = le, .attrs = attrs_scratch[0..na] } });
            if (sc) try callback(ctx, .{ .element_end = .{ .local_name = le } });
            continue;
        }
        if (text_len >= MAX_TEXT_LEN) return error.TextTooLong;
        text_buf[text_len] = c;
        text_len += 1;
        pos += 1;
    }
    if (text_len > 0) {
        var unesc: [MAX_TEXT_LEN]u8 = undefined;
        const ulen = unescapeXml(text_buf[0..text_len], &unesc);
        try callback(ctx, .{ .text = unesc[0..ulen] });
    }
    if (depth != 0) return error.MalformedXml;
}

// ── ISO 8601 parser ───────────────────────────────────────────────────────

/// Parse an ISO 8601 UTC timestamp to Unix seconds.
/// Supports: Z suffix, fractional seconds, +HH:MM / -HH:MM offsets.
pub fn parseIso8601(s: []const u8) ParseError!i64 {
    if (s.len < 20) return error.MalformedXml;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.MalformedXml;
    if (s[4] != '-') return error.MalformedXml;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return error.MalformedXml;
    if (s[7] != '-') return error.MalformedXml;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return error.MalformedXml;
    if (s[10] != 'T' and s[10] != 't') return error.MalformedXml;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return error.MalformedXml;
    if (s[13] != ':') return error.MalformedXml;
    const minu = std.fmt.parseInt(u32, s[14..16], 10) catch return error.MalformedXml;
    if (s[16] != ':') return error.MalformedXml;
    const secs = std.fmt.parseInt(u32, s[17..19], 10) catch return error.MalformedXml;

    var tz_off: i64 = 0;
    var tp: usize = 19;
    if (tp < s.len and s[tp] == '.') {
        tp += 1;
        while (tp < s.len and std.ascii.isDigit(s[tp])) tp += 1;
    }
    if (tp < s.len) {
        const tc = s[tp];
        if (tc == 'Z' or tc == 'z') {
            tz_off = 0;
        } else if ((tc == '+' or tc == '-') and tp + 5 < s.len) {
            const th = std.fmt.parseInt(i64, s[tp + 1 .. tp + 3], 10) catch return error.MalformedXml;
            if (s[tp + 3] != ':') return error.MalformedXml;
            const tm = std.fmt.parseInt(i64, s[tp + 4 .. tp + 6], 10) catch return error.MalformedXml;
            tz_off = th * 3600 + tm * 60;
            if (tc == '-') tz_off = -tz_off;
        }
    }

    const y = @as(i64, year);
    const m = @as(i64, month);
    const d = @as(i64, day);
    const h = @as(i64, hour);
    const mn = @as(i64, minu);
    const sc = @as(i64, secs);

    const dim = [_]i64{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const ilp: i64 = if ((@rem(y, 4) == 0 and @rem(y, 100) != 0) or (@rem(y, 400) == 0)) 1 else 0;
    const yse = y - 1970;
    const leaps: i64 = blk: {
        if (y <= 1970) break :blk 0;
        const n = y - 1;
        const base: i64 = @divTrunc(1969, 4) - @divTrunc(1969, 100) + @divTrunc(1969, 400);
        break :blk (@divTrunc(n, 4) - @divTrunc(n, 100) + @divTrunc(n, 400)) - base;
    };
    var days: i64 = yse * 365 + leaps;
    var mi: i64 = 1;
    while (mi < m) : (mi += 1) {
        days += dim[@intCast(mi)];
        if (mi == 2) days += ilp;
    }
    days += d - 1;
    return days * 86400 + h * 3600 + mn * 60 + sc - tz_off;
}

// ── SAML validation errors ────────────────────────────────────────────────

pub const SamlError = error{
    StatusNotSuccess,
    ConditionsExpired,
    ConditionsNotYetValid,
    AudienceMismatch,
    MissingNameId,
    MissingIssuer,
};

// ── Extraction state machine ──────────────────────────────────────────────

const Path = enum {
    root,
    response,
    response_status,
    response_status_code,
    response_issuer,
    assertion,
    assertion_issuer,
    assertion_subject,
    assertion_subject_name_id,
    assertion_conditions,
    assertion_conditions_audience_restriction,
    assertion_conditions_audience_restriction_audience,
    assertion_authn_statement,
    assertion_attribute_statement,
    assertion_attribute_statement_attribute,
    assertion_attribute_statement_attribute_value,
    other,
};

const ExtractState = struct {
    alloc: Allocator,
    path: Path = .root,
    other_depth: usize = 0,
    other_return: Path = .root,

    in_response_to: ?[]const u8 = null,
    status_ok: bool = false,
    issuer: ?[]const u8 = null,
    name_id: ?[]const u8 = null,
    name_id_format: ?[]const u8 = null,
    not_before: i64 = 0,
    not_on_or_after: i64 = std.math.maxInt(i64),
    audience: ?[]const u8 = null,
    session_not_on_or_after: ?i64 = null,

    cur_attr_name: ?[]const u8 = null,
    attrs: std.ArrayListUnmanaged(saml_schema.Attribute) = .empty,
    cur_vals: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn flushAttr(ctx: *ExtractState) ParseError!void {
    if (ctx.cur_attr_name) |n| {
        const vals = ctx.cur_vals.toOwnedSlice(ctx.alloc) catch return error.MalformedXml;
        ctx.attrs.append(ctx.alloc, .{ .name = n, .values = vals }) catch return error.MalformedXml;
        ctx.cur_attr_name = null;
    }
}

fn extractCallback(raw: *anyopaque, ev: Event) ParseError!void {
    const ctx: *ExtractState = @ptrCast(@alignCast(raw));
    switch (ev) {
        .element_start => |elem| {
            const n = elem.local_name;
            switch (ctx.path) {
                .root => {
                    if (std.mem.eql(u8, n, "Response")) {
                        ctx.path = .response;
                        for (elem.attrs) |a| if (std.mem.eql(u8, a.name, "InResponseTo")) {
                            ctx.in_response_to = ctx.alloc.dupe(u8, a.value) catch return error.MalformedXml;
                        };
                    }
                },
                .response => {
                    if (std.mem.eql(u8, n, "Status")) ctx.path = .response_status else if (std.mem.eql(u8, n, "Assertion")) ctx.path = .assertion else if (std.mem.eql(u8, n, "Issuer")) ctx.path = .response_issuer else {
                        ctx.other_return = .response;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .response_status => {
                    if (std.mem.eql(u8, n, "StatusCode")) {
                        ctx.path = .response_status_code;
                        for (elem.attrs) |a| if (std.mem.eql(u8, a.name, "Value")) {
                            ctx.status_ok = std.mem.endsWith(u8, a.value, ":Success");
                        };
                    } else {
                        ctx.other_return = .response_status;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion => {
                    if (std.mem.eql(u8, n, "Issuer")) ctx.path = .assertion_issuer else if (std.mem.eql(u8, n, "Subject")) ctx.path = .assertion_subject else if (std.mem.eql(u8, n, "Conditions")) {
                        ctx.path = .assertion_conditions;
                        for (elem.attrs) |a| {
                            if (std.mem.eql(u8, a.name, "NotBefore"))
                                ctx.not_before = parseIso8601(a.value) catch 0
                            else if (std.mem.eql(u8, a.name, "NotOnOrAfter"))
                                ctx.not_on_or_after = parseIso8601(a.value) catch std.math.maxInt(i64);
                        }
                    } else if (std.mem.eql(u8, n, "AuthnStatement")) {
                        ctx.path = .assertion_authn_statement;
                        for (elem.attrs) |a| if (std.mem.eql(u8, a.name, "SessionNotOnOrAfter")) {
                            ctx.session_not_on_or_after = parseIso8601(a.value) catch null;
                        };
                    } else if (std.mem.eql(u8, n, "AttributeStatement")) ctx.path = .assertion_attribute_statement else {
                        ctx.other_return = .assertion;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion_subject => {
                    if (std.mem.eql(u8, n, "NameID")) {
                        ctx.path = .assertion_subject_name_id;
                        for (elem.attrs) |a| if (std.mem.eql(u8, a.name, "Format")) {
                            ctx.name_id_format = ctx.alloc.dupe(u8, a.value) catch return error.MalformedXml;
                        };
                    } else {
                        ctx.other_return = .assertion_subject;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion_conditions => {
                    if (std.mem.eql(u8, n, "AudienceRestriction")) ctx.path = .assertion_conditions_audience_restriction else {
                        ctx.other_return = .assertion_conditions;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion_conditions_audience_restriction => {
                    if (std.mem.eql(u8, n, "Audience")) ctx.path = .assertion_conditions_audience_restriction_audience else {
                        ctx.other_return = .assertion_conditions_audience_restriction;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion_attribute_statement => {
                    if (std.mem.eql(u8, n, "Attribute")) {
                        ctx.path = .assertion_attribute_statement_attribute;
                        try flushAttr(ctx);
                        for (elem.attrs) |a| if (std.mem.eql(u8, a.name, "Name")) {
                            ctx.cur_attr_name = ctx.alloc.dupe(u8, a.value) catch return error.MalformedXml;
                        };
                    } else {
                        ctx.other_return = .assertion_attribute_statement;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .assertion_attribute_statement_attribute => {
                    if (std.mem.eql(u8, n, "AttributeValue")) ctx.path = .assertion_attribute_statement_attribute_value else {
                        ctx.other_return = .assertion_attribute_statement_attribute;
                        ctx.path = .other;
                        ctx.other_depth = 1;
                    }
                },
                .other => ctx.other_depth += 1,
                else => {},
            }
        },
        .element_end => |_| {
            switch (ctx.path) {
                .response => ctx.path = .root,
                .response_status => ctx.path = .response,
                .response_status_code => ctx.path = .response_status,
                .response_issuer => ctx.path = .response,
                .assertion_issuer => ctx.path = .assertion,
                .assertion => ctx.path = .response,
                .assertion_subject => ctx.path = .assertion,
                .assertion_subject_name_id => ctx.path = .assertion_subject,
                .assertion_conditions => ctx.path = .assertion,
                .assertion_conditions_audience_restriction => ctx.path = .assertion_conditions,
                .assertion_conditions_audience_restriction_audience => ctx.path = .assertion_conditions_audience_restriction,
                .assertion_authn_statement => ctx.path = .assertion,
                .assertion_attribute_statement => {
                    try flushAttr(ctx);
                    ctx.path = .assertion;
                },
                .assertion_attribute_statement_attribute => ctx.path = .assertion_attribute_statement,
                .assertion_attribute_statement_attribute_value => ctx.path = .assertion_attribute_statement_attribute,
                .other => {
                    if (ctx.other_depth > 0) {
                        ctx.other_depth -= 1;
                        if (ctx.other_depth == 0) ctx.path = ctx.other_return;
                    }
                },
                else => {},
            }
        },
        .text => |txt| {
            const tr = std.mem.trim(u8, txt, " \t\r\n");
            if (tr.len == 0) return;
            switch (ctx.path) {
                .response_issuer, .assertion_issuer => {
                    if (ctx.path == .assertion_issuer or ctx.issuer == null) {
                        if (ctx.issuer) |old| ctx.alloc.free(old);
                        ctx.issuer = ctx.alloc.dupe(u8, tr) catch return error.MalformedXml;
                    }
                },
                .assertion_subject_name_id => {
                    if (ctx.name_id) |old| ctx.alloc.free(old);
                    ctx.name_id = ctx.alloc.dupe(u8, tr) catch return error.MalformedXml;
                },
                .assertion_conditions_audience_restriction_audience => {
                    if (ctx.audience) |old| ctx.alloc.free(old);
                    ctx.audience = ctx.alloc.dupe(u8, tr) catch return error.MalformedXml;
                },
                .assertion_attribute_statement_attribute_value => {
                    const v = ctx.alloc.dupe(u8, tr) catch return error.MalformedXml;
                    ctx.cur_vals.append(ctx.alloc, v) catch return error.MalformedXml;
                },
                else => {},
            }
        },
    }
}

/// Parse and validate a SAMLResponse XML document.
///
/// `xml` must already be base64-decoded (raw XML bytes).
/// Does NOT verify cryptographic signature — caller's responsibility.
pub fn parseSamlResponse(
    xml: []const u8,
    expected_audience: []const u8,
    now_unix: i64,
    alloc: Allocator,
) (ParseError || SamlError)!saml_schema.ParsedAssertion {
    var state = ExtractState{ .alloc = alloc };
    try parse(xml, &state, extractCallback);

    if (!state.status_ok) return error.StatusNotSuccess;
    const issuer = state.issuer orelse return error.MissingIssuer;
    const name_id = state.name_id orelse return error.MissingNameId;
    if (now_unix < state.not_before) return error.ConditionsNotYetValid;
    if (now_unix >= state.not_on_or_after) return error.ConditionsExpired;
    const audience = state.audience orelse "";
    if (!std.mem.eql(u8, audience, expected_audience)) return error.AudienceMismatch;

    var email: ?[]const u8 = null;
    var display_name: ?[]const u8 = null;
    var given_name: ?[]const u8 = null;
    var family_name: ?[]const u8 = null;

    var final_attrs: std.ArrayListUnmanaged(saml_schema.Attribute) = .empty;
    errdefer {
        for (final_attrs.items) |a| {
            for (a.values) |v| alloc.free(v);
            alloc.free(a.values);
            alloc.free(a.name);
        }
        final_attrs.deinit(alloc);
    }

    for (state.attrs.items) |attr| {
        const nc = try alloc.dupe(u8, attr.name);
        errdefer alloc.free(nc);
        const vc = try alloc.alloc([]const u8, attr.values.len);
        errdefer alloc.free(vc);
        for (attr.values, 0..) |v, vi| vc[vi] = try alloc.dupe(u8, v);

        if (attr.values.len > 0) {
            const v0 = attr.values[0];
            if (std.mem.eql(u8, attr.name, "email") or
                std.mem.eql(u8, attr.name, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress") or
                std.mem.eql(u8, attr.name, "urn:oid:0.9.2342.19200300.100.1.3"))
            {
                if (email == null) email = try alloc.dupe(u8, v0);
            } else if (std.mem.eql(u8, attr.name, "displayName") or
                std.mem.eql(u8, attr.name, "http://schemas.microsoft.com/identity/claims/displayname"))
            {
                if (display_name == null) display_name = try alloc.dupe(u8, v0);
            } else if (std.mem.eql(u8, attr.name, "givenName") or
                std.mem.eql(u8, attr.name, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname"))
            {
                if (given_name == null) given_name = try alloc.dupe(u8, v0);
            } else if (std.mem.eql(u8, attr.name, "sn") or
                std.mem.eql(u8, attr.name, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname"))
            {
                if (family_name == null) family_name = try alloc.dupe(u8, v0);
            }
        }
        try final_attrs.append(alloc, .{ .name = nc, .values = vc });
    }

    // Free intermediate state allocations (we duped all strings above).
    for (state.attrs.items) |a| {
        for (a.values) |v| alloc.free(v);
        alloc.free(a.values);
        alloc.free(a.name);
    }
    state.attrs.deinit(alloc);
    state.cur_vals.deinit(alloc);

    return saml_schema.ParsedAssertion{
        .name_id = name_id,
        .name_id_format = state.name_id_format orelse "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
        .email = email,
        .display_name = display_name,
        .given_name = given_name,
        .family_name = family_name,
        .session_not_on_or_after = state.session_not_on_or_after,
        .not_before = state.not_before,
        .not_on_or_after = state.not_on_or_after,
        .audience = audience,
        .in_response_to = state.in_response_to,
        .issuer = issuer,
        .attributes = try final_attrs.toOwnedSlice(alloc),
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "parseIso8601 UTC positive" {
    try std.testing.expect((try parseIso8601("2024-01-15T10:30:00Z")) > 0);
}

test "parseIso8601 fractional equals integer" {
    const a = try parseIso8601("2024-01-15T10:30:00Z");
    const b = try parseIso8601("2024-01-15T10:30:00.000Z");
    try std.testing.expectEqual(a, b);
}

test "parseIso8601 negative tz offset" {
    const utc = try parseIso8601("2024-01-15T10:30:00Z");
    const neg5 = try parseIso8601("2024-01-15T05:30:00-05:00");
    try std.testing.expectEqual(utc, neg5);
}

test "stripPrefix works" {
    try std.testing.expectEqualStrings("Assertion", stripPrefix("saml:Assertion"));
    try std.testing.expectEqualStrings("Response", stripPrefix("Response"));
}

test "parse rejects oversized document" {
    var big: [65537]u8 = undefined;
    @memset(&big, 'a');
    var d: u8 = 0;
    const cb = struct {
        fn f(_: *anyopaque, _: Event) ParseError!void {}
    }.f;
    try std.testing.expectError(error.DocumentTooLarge, parse(&big, @ptrCast(&d), cb));
}

test "parse rejects DOCTYPE" {
    var d: u8 = 0;
    const cb = struct {
        fn f(_: *anyopaque, _: Event) ParseError!void {}
    }.f;
    try std.testing.expectError(error.DoctypeNotAllowed, parse("<!DOCTYPE x><r/>", @ptrCast(&d), cb));
}

test "parse counts events" {
    const Ctx = struct {
        s: usize = 0,
        e: usize = 0,
        t: usize = 0,
        fn cb(raw: *anyopaque, ev: Event) ParseError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (ev) {
                .element_start => self.s += 1,
                .element_end => self.e += 1,
                .text => self.t += 1,
            }
        }
    };
    var ctx = Ctx{};
    try parse("<root><child>hi</child></root>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 2), ctx.s);
    try std.testing.expectEqual(@as(usize, 2), ctx.e);
    try std.testing.expectEqual(@as(usize, 1), ctx.t);
}
