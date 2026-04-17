//! streaming_css.zig - CSS that streams with components
//! 
//! Problem with current approach:
//! - HTML streams first
//! - CSS is in <head> (already sent)  
//! - New components have no styles until CSS loads
//! 
//! Solution:
//! - Stream CSS inline with each component chunk
//! - Browser immediately has styles
//! - No extra requests

const std = @import("std");

/// CSS chunk that can be streamed inline
pub const CssChunk = struct {
    /// Unique ID for deduplication (browser keeps only first occurrence)
    id: []const u8,
    
    /// The CSS rules
    content: []const u8,
    
    /// Generate <style> tag that only applies once
    pub fn render(self: CssChunk, writer: anytype) !void {
        // Use data-attribute to track which CSS has been applied
        try writer.print(
            "<style data-mercss-id=\"{s}\">{s}</style>",
            .{ self.id, self.content }
        );
    }
};

/// Component that brings its own CSS
pub fn StreamingComponent(comptime config: anytype) type {
    return struct {
        pub const css_id = @typeName(@This());
        pub const css_content = comptime generateCss(config.styles);
        
        pub fn renderWithCss(writer: anytype, content: []const u8) !void {
            // Stream CSS first (deduplicated by browser)
            try CssChunk{
                .id = css_id,
                .content = css_content,
            }.render(writer);
            
            // Then stream the HTML
            try writer.writeAll(content);
        }
    };
}

/// Layout that coordinates CSS streaming
pub const StreamingLayout = struct {
    /// Critical CSS - sent in <head>
    critical_css: []const u8,
    
    /// Component CSS registry - tracks what's been sent
    sent_ids: std.StringHashMap(void),
    
    pub fn init(allocator: std.mem.Allocator, critical: []const u8) StreamingLayout {
        return .{
            .critical_css = critical,
            .sent_ids = std.StringHashMap(void).init(allocator),
        };
    }
    
    /// Stream a component - only sends CSS if not already sent
    pub fn streamComponent(
        self: *StreamingLayout,
        writer: anytype,
        comptime Component: type,
        html_content: []const u8,
    ) !void {
        // Check if we've already sent this component's CSS
        if (!self.sent_ids.contains(Component.css_id)) {
            // Send CSS inline
            try writer.writeAll("<style>");
            try writer.writeAll(Component.css_content);
            try writer.writeAll("</style>");
            
            // Mark as sent
            try self.sent_ids.put(Component.css_id, {});
        }
        
        // Send HTML
        try writer.writeAll(html_content);
    }
};

/// Alternative: CSS-in-JS-style but compile-time
/// 
/// Instead of runtime styled-components, comptime-generate classes:
/// ```zig
/// const button = css`
///   padding: 8px 16px;
///   background: ${theme.colors.primary};
/// `;
/// ```
/// 
/// Becomes at compile time:
/// ```css
/// .mercss-a7f3e { padding: 8px 16px; background: #3b82f6; }
/// ```
/// 
/// And in HTML:
/// ```html
/// <button class="mercss-a7f3e">Click me</button>
/// ```

/// Comptime CSS string interpolation
pub fn css(comptime fmt: []const u8) []const u8 {
    // In real implementation, parse the template string
    // Extract properties/values
    // Generate atomic classes
    // Return CSS
    return fmt;
}

/// EXPERIMENT: State-aware CSS
/// 
/// CSS that knows about component state and transitions
pub const StatefulStyles = struct {
    base: []const u8,
    states: []const struct {
        name: []const u8,  // hover, focus, loading, etc.
        styles: []const u8,
        transitions: ?[]const u8 = null,
    },
    
    /// Generate CSS with proper transitions
    pub fn generate(self: StatefulStyles) []const u8 {
        var result: []const u8 = self.base;
        
        for (self.states) |state| {
            result = result ++ std.fmt.allocPrint(
                std.heap.page_allocator,
                ".state-{s}{{{s}}}",
                .{ state.name, state.styles }
            ) catch "";
        }
        
        return result;
    }
};

/// Usage in page:
/// 
/// 1. Shell streams first with critical CSS
/// 2. Async component streams with its CSS inline
/// 3. Browser immediately applies styles
/// 4. No hydration flicker!

/// Example page showing the pattern:
const ExamplePage = struct {
    pub fn render(writer: anytype) !void {
        // Shell (TTFB)
        try writer.writeAll(
            \\<html>
            \\<head>
            \\\\<style>/* critical layout CSS */</style>
            \\</head>
            \\<body>
            \\\\<div id="shell">
            \\\\\\\\<header>Loading...</header>
        );
        try writer.flush();  // TTFB achieved
        
        // Async component streams with its CSS
        // (No separate CSS request!)
        try writer.writeAll(
            \\\\<style>
            \\\\\\\\.product-card{padding:16px;border:1px solid #e5e7eb}
            \\\\\\\\.product-card:hover{box-shadow:0 4px 6px rgba(0,0,0,0.1)}
            \\\\<style>
            \\\\<div class="product-card">
            \\\\\\\\<h2>Product Name</h2>
            \\\\\\\\<p>Description...</p>
            \\\\<div>
        );
        
        try writer.writeAll(
            \\\\<style>
            \\\\\\\\.reviews{margin-top:24px}
            \\\\<style>
            \\\\<div class="reviews">
            \\\\\\\\<h3>Reviews</h3>
            \\\\\\\\<div>Loading reviews...</div>
            \\\\<div>
        );
        
        try writer.writeAll(
            \\\\<script>
            \\\\\\\\/hydrate when ready
            \\\\<script>
            \\</body>
            \\</html>
        );
    }
};
