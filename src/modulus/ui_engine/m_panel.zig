//! M-Panel — MD3 launcher grid from the override FAB (5×2 viewport, scrollable).
//! Append one `tools` entry per feature; each opens its own full-screen tool window.

const std = @import("std");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const icons_phosphor = @import("icons_phosphor.zig");
const color = @import("color.zig");
const panel_bg = color.Rgb565.fromHex(0x001426);
const panel_card = color.Rgb565.fromHex(0x03233F);
const panel_card_hi = color.Rgb565.fromHex(0x07345A);
const panel_cyan = color.Rgb565.fromHex(0x18C8FF);
const panel_text = color.Rgb565.fromHex(0xF4FAFF);
const panel_muted = color.Rgb565.fromHex(0xA9C7E5);

pub const ToolId = enum(u8) {
    terminal = 0,
    usb = 1,
    probe = 2,
    sd = 3,
    zigbee = 4,
    controls = 5,
    firmware_update = 6,
    c6_update = 7,
    s3_update = 8,
    nano_update = 9,
};

pub const Tool = struct {
    label: []const u8,
    icon: icons_phosphor.Id,
    requires_usb: bool = false,
};

/// ponytail: add one row per tool window as features land.
pub const tools = [_]Tool{
    .{ .label = "Terminal", .icon = .clipboard_text },
    .{ .label = "USB Drive", .icon = .usb, .requires_usb = true },
    .{ .label = "Probe", .icon = .arrow_down },
    .{ .label = "SD Card", .icon = .hard_drives },
    .{ .label = "Zigbee", .icon = .broadcast },
    .{ .label = "All controls", .icon = .plugs },
    .{ .label = "Firmware Update", .icon = .arrow_down },
};

pub fn toolEnabled(index: u8, usb_host: bool) bool {
    if (index >= tools.len) return false;
    return !tools[index].requires_usb or usb_host;
}

pub const cols: i32 = 3;
pub const visible_rows: i32 = 2;
const icon_px: i32 = 32;
const tile_h: i32 = 132;
const gap: i32 = tokens.Space.sm;
const close_sz: i32 = tokens.Logical.touch_min;
const card_w: i32 = tokens.Logical.width - 32;
const card_h: i32 = tokens.Logical.height - 28;
const title_h: i32 = 84;

pub const Hit = enum {
    none,
    scrim,
    close,
    tile,
    favorite,
};

pub const HitInfo = struct {
    kind: Hit = .none,
    /// Tool index when `kind == .tile`.
    index: u8 = 0,
    channel: u8 = 0,
};

pub const Layout = struct {
    card: geom.Rect = .{},
    close: geom.Rect = .{},
    view: geom.Rect = .{},
    tiles: [32]geom.Rect = [_]geom.Rect{.{}} ** 32,
    tool_indices: [32]u8 = [_]u8{0xff} ** 32,
    quick: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    tile_n: u8 = 0,
    favorite_channels: [3]u8 = .{ 0xff, 0xff, 0xff },
    scroll_max: i32 = 0,
};

pub const ToolLayout = struct {
    card: geom.Rect = .{},
    back: geom.Rect = .{},
};

fn cardGeom(enter_t: f32) geom.Rect {
    const t = std.math.clamp(enter_t, 0, 1);
    const w: i32 = @intFromFloat(@as(f32, @floatFromInt(card_w)) * (0.88 + 0.12 * t));
    const h: i32 = @intFromFloat(@as(f32, @floatFromInt(card_h)) * (0.88 + 0.12 * t));
    return .{
        .x = @divTrunc(tokens.Logical.width - w, 2),
        .y = @divTrunc(tokens.Logical.height - h, 2),
        .w = w,
        .h = h,
    };
}

fn tileW(card: geom.Rect) i32 {
    const pad = tokens.Space.lg;
    const avail = card.w - pad * 2 - gap * (cols - 1);
    return @divTrunc(avail, cols);
}

fn rowCount() i32 {
    const n = tools.len - 1;
    if (n == 0) return visible_rows;
    return @divTrunc(n + @as(usize, @intCast(cols)) - 1, @as(usize, @intCast(cols)));
}

pub fn contentH() i32 {
    return rowCount() * (tile_h + gap) - gap;
}

pub fn viewH(card: geom.Rect) i32 {
    return card.h - 418;
}

pub fn scrollMax(card: geom.Rect) i32 {
    return @max(0, contentH() - viewH(card));
}

fn tileRect(card: geom.Rect, col: i32, row: i32, scroll: i32) geom.Rect {
    const pad = tokens.Space.lg;
    const tw = tileW(card);
    const y0 = card.y + 418;
    return .{
        .x = card.x + pad + col * (tw + gap),
        .y = y0 + row * (tile_h + gap) - scroll,
        .w = tw,
        .h = tile_h,
    };
}

/// MD3 expressive tint — warm left → cool right (reference launcher strip).
fn tileFill(theme: tokens.Theme, col: i32) color.Rgb565 {
    const t: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(cols - 1)) * 255.0));
    return color.blendRgb565(theme.tertiary_container, theme.secondary_container, t);
}

fn paintClose(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect) void {
    widgets.drawTonalCloseButton(logical, r, theme);
}

fn paintLargeSwitch(logical: *fb.LogicalFb, r: geom.Rect, on: bool) void {
    widgets.fillRoundRect(logical, r, @divTrunc(r.h, 2), if (on) color.Rgb565.fromHex(0x079DFF) else color.Rgb565.fromHex(0x173B60));
    widgets.strokeRoundRect(logical, r, @divTrunc(r.h, 2), panel_cyan, 1);
    const d = r.h - 10;
    const x = if (on) r.x + r.w - d - 5 else r.x + 5;
    widgets.fillRoundRect(logical, .{ .x = x, .y = r.y + 5, .w = d, .h = d }, @divTrunc(d, 2), panel_text);
}

fn paintTile(
    logical: *fb.LogicalFb,
    r: geom.Rect,
    icon: icons_phosphor.Id,
    label: []const u8,
    fill: color.Rgb565,
    theme: tokens.Theme,
    enabled: bool,
) void {
    _ = fill;
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, if (enabled) panel_card else theme.surface_container_low);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, if (enabled) panel_cyan else theme.outline_variant, 2);
    const ink = if (enabled) panel_text else theme.on_surface_variant;
    icons_phosphor.draw(logical, r.x + 30, r.y + @divTrunc(r.h - icon_px, 2), icon, ink);
    if (label.len != 0) {
        font.drawTextRole(logical, r.x + 86, r.y + @divTrunc(r.h - font.faceHeight(font.faceForRole(.title_m)), 2), label, ink, .title_m);
    }
}

fn paintEmptySlot(logical: *fb.LogicalFb, r: geom.Rect, theme: tokens.Theme) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container_low);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, theme.outline_variant, 1);
}

pub fn paint(
    logical: *fb.LogicalFb,
    theme: tokens.Theme,
    scroll_px: i32,
    enter_t: f32,
    usb_host: bool,
    channels: *const [12]@import("settings_prefs.zig").WirelessPrefs.ZbNodeChannel,
    channel_count: u8,
    espnow_connected: bool,
    zigbee_online: u8,
) Layout {
    logical.fillRect(.{ .x = 0, .y = 0, .w = tokens.Logical.width, .h = tokens.Logical.height }, panel_bg);
    const card = cardGeom(enter_t);
    widgets.fillRoundRect(logical, card, tokens.Shape.dialog, panel_bg);
    widgets.strokeRoundRect(logical, card, tokens.Shape.dialog, panel_cyan, 1);

    var lay: Layout = .{ .card = card };
    const title_y = card.y + tokens.Space.md;
    font.drawTextRole(logical, card.x + tokens.Space.lg, title_y, "Modulus   |   M-Panel", panel_text, .title_l);
    font.drawTextRole(logical, card.x + 430, title_y, "Ready", color.Rgb565.fromHex(0x00EE88), .title_m);
    font.drawTextRole(logical, card.x + 620, title_y, if (espnow_connected) "ESP-NOW Connected" else "ESP-NOW Offline", if (espnow_connected) panel_cyan else panel_muted, .title_m);
    var zb_buf: [24]u8 = undefined;
    const zb_text = std.fmt.bufPrint(&zb_buf, "Zigbee {d} online", .{zigbee_online}) catch "Zigbee";
    font.drawTextRole(logical, card.x + 930, title_y, zb_text, if (zigbee_online > 0) panel_cyan else panel_muted, .title_m);
    const th = font.faceHeight(font.faceForRole(.title_l));
    lay.close = .{
        .x = card.x + card.w - close_sz - tokens.Space.md,
        .y = title_y + @divTrunc(th - close_sz, 2),
        .w = close_sz,
        .h = close_sz,
    };
    paintClose(logical, theme, lay.close);

    const y0 = card.y + 418;
    lay.view = .{
        .x = card.x + tokens.Space.lg,
        .y = y0,
        .w = card.w - tokens.Space.lg * 2,
        .h = card.y + card.h - y0 - tokens.Space.md,
    };
    lay.scroll_max = scrollMax(card);
    const scroll = std.math.clamp(scroll_px, 0, lay.scroll_max);

    logical.setClip(card);
    defer logical.setClip(null);

    if (tools.len == 0) {
        var row: i32 = 0;
        while (row < visible_rows) : (row += 1) {
            var col: i32 = 0;
            while (col < cols) : (col += 1) {
                const r = tileRect(card, col, row, scroll);
                if (row == 0 and col == 2) {
                    const hint = "Tools appear here";
                    paintTile(logical, r, .cards_three, hint, theme.surface_container, theme, true);
                } else {
                    paintEmptySlot(logical, r, theme);
                }
            }
        }
        return lay;
    }

    font.drawTextRole(logical, card.x + tokens.Space.lg, card.y + 82, "Quick controls", panel_text, .title_l);
    const quick_y = card.y + 128;
    const quick_h: i32 = 238;
    const quick_gap: i32 = 16;
    const quick_w = @divTrunc(card.w - tokens.Space.lg * 2 - quick_gap * 3, 4);
    var pos: usize = 0;
    while (pos < 4) : (pos += 1) {
        const r: geom.Rect = .{ .x = card.x + tokens.Space.lg + @as(i32, @intCast(pos)) * (quick_w + quick_gap), .y = quick_y, .w = quick_w, .h = quick_h };
        lay.quick[pos] = r;
        if (pos == 3) {
            widgets.fillRoundRect(logical, r, tokens.Shape.lg, panel_card_hi);
            widgets.strokeRoundRect(logical, r, tokens.Shape.lg, panel_cyan, 2);
            icons_phosphor.draw(logical, r.x + 32, r.y + 36, .cards_three, panel_cyan);
            font.drawTextRole(logical, r.x + 92, r.y + 30, "All controls", panel_text, .title_l);
            font.drawTextRole(logical, r.x + 92, r.y + 86, "8 channels  |  2 pages", panel_muted, .body_m);
            widgets.drawFilledButton(logical, .{ .x = r.x + 32, .y = r.y + 150, .w = r.w - 64, .h = 64 }, "Open controls", theme);
            continue;
        }
        var found: u8 = 0xff;
        var ci: u8 = 0;
        while (ci < @min(channel_count, 8)) : (ci += 1) if (channels[ci].favorite == pos + 1) { found = ci; break; };
        lay.favorite_channels[pos] = found;
        if (found == 0xff) {
            widgets.fillRoundRect(logical, r, tokens.Shape.lg, panel_card);
            widgets.strokeRoundRect(logical, r, tokens.Shape.lg, panel_cyan, 2);
            const plus: geom.Rect = .{ .x = r.x + @divTrunc(r.w - 88, 2), .y = r.y + 24, .w = 88, .h = 88 };
            widgets.fillRoundRect(logical, plus, 44, color.Rgb565.fromHex(0x079DFF));
            logical.fillRect(.{ .x = plus.x + 20, .y = plus.y + 40, .w = 48, .h = 8 }, panel_text);
            logical.fillRect(.{ .x = plus.x + 40, .y = plus.y + 20, .w = 8, .h = 48 }, panel_text);
            const add = "Add quick control";
            font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(add, .title_m), 2), r.y + 126, add, panel_text, .title_m);
            const hint = "Tap to choose";
            font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(hint, .body_m), 2), r.y + 176, hint, panel_muted, .body_m);
        } else {
            const ch = channels[found];
            var fallback: [20]u8 = undefined;
            const saved = std.mem.sliceTo(&ch.name, 0);
            const label = if (saved.len != 0) saved else std.fmt.bufPrint(&fallback, "Channel {d}", .{found + 1}) catch "Channel";
            widgets.fillRoundRect(logical, r, tokens.Shape.lg, panel_card);
            widgets.strokeRoundRect(logical, r, tokens.Shape.lg, if (ch.temp_alarm_active) theme.err else panel_cyan, 2);
            icons_phosphor.draw(logical, r.x + 32, r.y + 36, if (ch.typ == 4) .thermometer_simple else .plugs, if (ch.temp_alarm_active) theme.err else panel_cyan);
            font.drawTextRole(logical, r.x + 92, r.y + 30, label, panel_text, .title_l);
            var state_buf: [24]u8 = undefined;
            const state = if (ch.typ == 4 and ch.temperature_state == 1) std.fmt.bufPrint(&state_buf, "{d:.1} C", .{@as(f32, @floatFromInt(ch.temperature_centi_c)) / 100.0}) catch "" else if (ch.digital_value) "ON" else "OFF";
            font.drawTextRole(logical, r.x + 92, r.y + 86, state, if (ch.temp_alarm_active) theme.err else theme.primary, .title_m);
            if (ch.typ == 1 or ch.typ == 2) paintLargeSwitch(logical, .{ .x = r.x + 32, .y = r.y + 150, .w = r.w - 64, .h = 64 }, ch.digital_value);
        }
    }

    font.drawTextRole(logical, card.x + tokens.Space.lg, card.y + 378, "Tools", panel_text, .title_l);
    var i: usize = 0;
    while (i < tools.len and lay.tile_n < lay.tiles.len) : (i += 1) {
        if (i == @intFromEnum(ToolId.controls)) continue;
        const visual = lay.tile_n;
        const row: i32 = @intCast(@divTrunc(visual, @as(usize, @intCast(cols))));
        const col: i32 = @intCast(@rem(visual, @as(usize, @intCast(cols))));
        const r = tileRect(card, col, row, scroll);
        lay.tiles[lay.tile_n] = r;
        lay.tool_indices[lay.tile_n] = @intCast(i);
        lay.tile_n += 1;
        const tool = tools[i];
        const enabled = toolEnabled(@intCast(i), usb_host);
        paintTile(logical, r, tool.icon, tool.label, tileFill(theme, col), theme, enabled);
    }
    return lay;
}

pub fn hit(layout: Layout, x: i32, y: i32, usb_host: bool) HitInfo {
    if (layout.close.contains(x, y)) return .{ .kind = .close };
    if (!layout.card.contains(x, y)) return .{ .kind = .scrim };
    for (layout.quick, 0..) |r, qi| if (r.contains(x, y)) {
        if (qi == 3) return .{ .kind = .tile, .index = @intFromEnum(ToolId.controls) };
        return .{ .kind = .favorite, .index = @intCast(qi), .channel = layout.favorite_channels[qi] };
    };
    if (!layout.view.contains(x, y)) return .{ .kind = .none };
    var i: u8 = 0;
    while (i < layout.tile_n) : (i += 1) {
        if (layout.tiles[i].contains(x, y)) {
            const tool_index = layout.tool_indices[i];
            if (!toolEnabled(tool_index, usb_host)) return .{ .kind = .none };
            return .{ .kind = .tile, .index = tool_index };
        }
    }
    return .{ .kind = .none };
}

fn toolCardGeom(enter_t: f32) geom.Rect {
    const t = std.math.clamp(enter_t, 0, 1);
    const base_h = card_h + 80;
    const w: i32 = @intFromFloat(@as(f32, @floatFromInt(card_w)) * (0.92 + 0.08 * t));
    const h: i32 = @intFromFloat(@as(f32, @floatFromInt(base_h)) * (0.92 + 0.08 * t));
    return .{
        .x = @divTrunc(tokens.Logical.width - w, 2),
        .y = @divTrunc(tokens.Logical.height - h, 2),
        .w = w,
        .h = h,
    };
}

pub fn paintTool(
    logical: *fb.LogicalFb,
    theme: tokens.Theme,
    tool_index: usize,
    enter_t: f32,
) ToolLayout {
    widgets.fillScrim(logical, theme);
    const card2 = toolCardGeom(enter_t);
    widgets.fillRoundRect(logical, card2, tokens.Shape.dialog, theme.elev(3));

    var lay: ToolLayout = .{ .card = card2 };
    const title_y = card2.y + tokens.Space.md;
    const label = if (tool_index < tools.len) tools[tool_index].label else "Tool";
    lay.back = .{
        .x = card2.x + tokens.Space.md,
        .y = title_y,
        .w = close_sz,
        .h = close_sz,
    };
    widgets.drawTonalCloseButton(logical, lay.back, theme);
    font.drawTextRole(
        logical,
        card2.x + tokens.Space.lg + close_sz,
        title_y + @divTrunc(close_sz - font.faceHeight(font.faceForRole(.title_l)), 2),
        label,
        theme.on_surface,
        .title_l,
    );
    const body_y = title_y + close_sz + tokens.Space.lg;
    font.drawTextRole(
        logical,
        card2.x + tokens.Space.lg,
        body_y,
        "Tool window scaffold - add feature UI here.",
        theme.on_surface_variant,
        .body_m,
    );
    return lay;
}

pub fn hitTool(layout: ToolLayout, x: i32, y: i32) bool {
    return layout.back.contains(x, y) or !layout.card.contains(x, y);
}

test "m-panel grid is 5 columns" {
    const bounds: geom.Rect = .{ .x = 0, .y = 0, .w = card_w, .h = card_h };
    const tw = tileW(bounds);
    const r0 = tileRect(bounds, 0, 0, 0);
    const r1 = tileRect(bounds, 1, 0, 0);
    try std.testing.expectEqual(r0.w, tw);
    try std.testing.expectEqual(r1.x - r0.x, tw + gap);
}

test "launcher tools fit without scrolling" {
    const card = cardGeom(1);
    try std.testing.expectEqual(@as(i32, 0), scrollMax(card));
}

test "hit tile index" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const theme = tokens.Theme.industrialTealDark();
    const prefs = @import("settings_prefs.zig");
    var channels = [_]prefs.WirelessPrefs.ZbNodeChannel{.{}} ** 12;
    const lay = paint(&logical, theme, 0, 1, true, &channels, 0, false, 0);
    if (lay.tile_n > 3) {
        const r = lay.tiles[3];
        const h = hit(lay, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2), true);
        try std.testing.expect(h.kind == .tile);
        try std.testing.expectEqual(@as(u8, 3), h.index);
    }
}
