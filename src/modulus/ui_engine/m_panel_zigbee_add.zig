//! Guided Zigbee device onboarding for the M panel.

const std = @import("std");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const tool_chrome = @import("m_panel_tool.zig");

pub const Stage = enum { choose, connect, found };
pub const DeviceType = enum { node, other };

pub const State = struct {
    stage: Stage = .choose,
    device_type: DeviceType = .node,
    devices_before: u8 = 0,
    pairing_started: bool = false,
};

pub const Kind = enum { none, back, exit, node, other, retry, finish };
pub const Hit = struct { kind: Kind = .none };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    node: geom.Rect = .{},
    other: geom.Rect = .{},
    retry: geom.Rect = .{},
    finish: geom.Rect = .{},
};

fn centeredText(logical: *fb.LogicalFb, r: geom.Rect, text: []const u8, role: tokens.TypeRole, c: @import("color.zig").Rgb565) void {
    const tw = font.textWidthStr(text, role);
    const th = font.faceHeight(font.faceForRole(role));
    font.drawTextRole(logical, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - th, 2), text, c, role);
}

fn card(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, accent: @import("color.zig").Rgb565, title: []const u8, line1: []const u8, line2: []const u8, button: geom.Rect, button_text: []const u8) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.elev(2));
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, accent, 3);
    centeredText(logical, .{ .x = r.x + 20, .y = r.y + 32, .w = r.w - 40, .h = 52 }, title, .title_l, theme.on_surface);
    centeredText(logical, .{ .x = r.x + 24, .y = r.y + 112, .w = r.w - 48, .h = 34 }, line1, .body_m, theme.on_surface_variant);
    centeredText(logical, .{ .x = r.x + 24, .y = r.y + 150, .w = r.w - 48, .h = 34 }, line2, .body_m, theme.on_surface_variant);
    widgets.drawFilledButton(logical, button, button_text, theme);
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, state: State, hub_ready: bool, joined: bool, device_count: u8, enter_t: f32) Layout {
    widgets.fillScrim(logical, theme);
    _ = enter_t;
    const shell: geom.Rect = .{ .x = 20, .y = 20, .w = tokens.Logical.width - 40, .h = tokens.Logical.height - 40 };
    widgets.fillRoundRect(logical, shell, tokens.Shape.dialog, theme.elev(3));
    widgets.strokeRoundRect(logical, shell, tokens.Shape.dialog, theme.outline_variant, 1);
    var lay: Layout = .{};
    lay.header = tool_chrome.headerChrome(shell);
    tool_chrome.paintBackToPanel(logical, theme, lay.header.back);
    tool_chrome.paintTitle(logical, theme, lay.header.back.x + lay.header.back.w + tokens.Space.sm, lay.header.back.y, "Add Zigbee device");
    tool_chrome.paintExit(logical, theme, lay.header.exit);

    const x = shell.x + 32;
    const y = lay.header.back.y + lay.header.back.h + 28;
    const width = shell.w - 64;
    if (state.stage == .choose) {
        centeredText(logical, .{ .x = x, .y = y, .w = width, .h = 54 }, "What would you like to add?", .headline_s, theme.on_surface);
        centeredText(logical, .{ .x = x, .y = y + 54, .w = width, .h = 34 }, "Tab5 guides you through the next steps.", .body_m, theme.on_surface_variant);
        const gap: i32 = 24;
        const cw = @divTrunc(width - gap, 2);
        const cy = y + 108;
        const ch: i32 = 430;
        const left: geom.Rect = .{ .x = x, .y = cy, .w = cw, .h = ch };
        const right: geom.Rect = .{ .x = x + cw + gap, .y = cy, .w = cw, .h = ch };
        lay.node = .{ .x = left.x + 24, .y = left.y + left.h - 92, .w = left.w - 48, .h = 68 };
        lay.other = .{ .x = right.x + 24, .y = right.y + right.h - 92, .w = right.w - 48, .h = 68 };
        card(logical, theme, left, theme.primary, "Modulus Node", "Just switch it on.", "Tab5 finds and connects it automatically.", lay.node, "Add Node");
        card(logical, theme, right, theme.tertiary, "Other Zigbee device", "Smart plugs, lights and sensors.", "Tab5 helps you start pairing.", lay.other, "Add Zigbee device");
    } else if (state.stage == .connect) {
        const node = state.device_type == .node;
        centeredText(logical, .{ .x = x, .y = y + 12, .w = width, .h = 58 }, if (node) "Switch on the Modulus Node" else "Put the device in pairing mode", .headline_s, theme.on_surface);
        centeredText(logical, .{ .x = x + 80, .y = y + 82, .w = width - 160, .h = 40 }, if (node) "No button is needed. Tab5 handles the connection automatically." else "Use the pairing instructions supplied with your Zigbee device.", .body_m, theme.on_surface_variant);
        const status: geom.Rect = .{ .x = x + 100, .y = y + 160, .w = width - 200, .h = 230 };
        widgets.fillRoundRect(logical, status, tokens.Shape.lg, theme.elev(2));
        centeredText(logical, .{ .x = status.x + 20, .y = status.y + 28, .w = status.w - 40, .h = 48 }, if (!hub_ready) "Connecting to NanoH2 hub..." else if (!joined) "Creating Zigbee network..." else "Searching for Zigbee devices...", .title_l, theme.on_surface);
        centeredText(logical, .{ .x = status.x + 20, .y = status.y + 94, .w = status.w - 40, .h = 40 }, "Hub, network and device list are checked automatically.", .body_m, theme.on_surface_variant);
        var count_buf: [48]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "Devices found: {d}", .{device_count -| state.devices_before}) catch "Searching...";
        centeredText(logical, .{ .x = status.x + 20, .y = status.y + 150, .w = status.w - 40, .h = 42 }, count, .title_m, theme.primary);
        lay.retry = .{ .x = x + @divTrunc(width - 420, 2), .y = y + 430, .w = 420, .h = 72 };
        widgets.drawTonalButton(logical, lay.retry, "Search again", theme);
    } else {
        centeredText(logical, .{ .x = x, .y = y + 70, .w = width, .h = 64 }, "Device found", .headline_s, theme.on_surface);
        centeredText(logical, .{ .x = x, .y = y + 154, .w = width, .h = 42 }, "The Zigbee device is connected and ready to set up.", .title_m, theme.on_surface_variant);
        lay.finish = .{ .x = x + @divTrunc(width - 520, 2), .y = y + 280, .w = 520, .h = 78 };
        widgets.drawFilledButton(logical, lay.finish, "Set up device", theme);
    }
    return lay;
}

pub fn hit(layout: Layout, x: i32, y: i32) Hit {
    if (tool_chrome.hitBack(layout.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(layout.header, x, y)) return .{ .kind = .exit };
    if (layout.node.contains(x, y)) return .{ .kind = .node };
    if (layout.other.contains(x, y)) return .{ .kind = .other };
    if (layout.retry.contains(x, y)) return .{ .kind = .retry };
    if (layout.finish.contains(x, y)) return .{ .kind = .finish };
    return .{};
}

test "wizard actions are glove friendly" {
    var logical = try fb.LogicalFb.alloc(std.testing.allocator);
    defer logical.deinit(std.testing.allocator);
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), .{}, false, false, 0, 1);
    try std.testing.expect(lay.node.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.other.h >= tokens.Logical.touch_min);
}
