//! Eight Node controls, four large cards per page.
const std = @import("std");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const icons = @import("icons_phosphor.zig");
const prefs = @import("settings_prefs.zig");
const chrome = @import("m_panel_tool.zig");
const color = @import("color.zig");
const panel_bg = color.Rgb565.fromHex(0x001426);
const panel_card = color.Rgb565.fromHex(0x03233F);
const panel_cyan = color.Rgb565.fromHex(0x18C8FF);
const panel_text = color.Rgb565.fromHex(0xF4FAFF);
const panel_muted = color.Rgb565.fromHex(0xA9C7E5);

pub const Layout = struct { header: chrome.Header = .{}, cards: [4]geom.Rect = [_]geom.Rect{.{}} ** 4, toggles: [4]geom.Rect = [_]geom.Rect{.{}} ** 4, prev: geom.Rect = .{}, next: geom.Rect = .{} };
pub const Kind = enum { none, back, exit, configure, toggle, prev, next };
pub const Hit = struct { kind: Kind = .none, channel: u8 = 0 };

fn iconFor(ch: prefs.WirelessPrefs.ZbNodeChannel) icons.Id {
    if (ch.icon != 0 and ch.icon <= @intFromEnum(icons.Id.hand_withdraw)) return @enumFromInt(ch.icon);
    return switch (ch.typ) {
        3 => .hand_withdraw,
        4 => .thermometer_simple,
        1, 2 => .plugs,
        else => .gear,
    };
}

fn channelName(ch: *const prefs.WirelessPrefs.ZbNodeChannel, index: u8, buf: *[24]u8) []const u8 {
    const saved = std.mem.sliceTo(&ch.name, 0);
    if (saved.len != 0) return saved;
    return std.fmt.bufPrint(buf, "Channel {d}", .{index + 1}) catch "Channel";
}

fn paintLargeSwitch(logical: *fb.LogicalFb, r: geom.Rect, on: bool) void {
    widgets.fillRoundRect(logical, r, @divTrunc(r.h, 2), if (on) color.Rgb565.fromHex(0x079DFF) else color.Rgb565.fromHex(0x173B60));
    widgets.strokeRoundRect(logical, r, @divTrunc(r.h, 2), panel_cyan, 1);
    const d = r.h - 10;
    const x = if (on) r.x + r.w - d - 5 else r.x + 5;
    widgets.fillRoundRect(logical, .{ .x = x, .y = r.y + 5, .w = d, .h = d }, @divTrunc(d, 2), panel_text);
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, channels: *const [12]prefs.WirelessPrefs.ZbNodeChannel, count: u8, page: u8, quick_slot: u8, enter_t: f32) Layout {
    _ = enter_t;
    logical.fillRect(.{ .x = 0, .y = 0, .w = tokens.Logical.width, .h = tokens.Logical.height }, panel_bg);
    const shell: geom.Rect = .{ .x = 20, .y = 20, .w = tokens.Logical.width - 40, .h = tokens.Logical.height - 40 };
    widgets.fillRoundRect(logical, shell, tokens.Shape.dialog, panel_bg);
    widgets.strokeRoundRect(logical, shell, tokens.Shape.dialog, panel_cyan, 1);
    var lay: Layout = .{};
    lay.header = chrome.headerChrome(shell);
    chrome.paintBackToPanel(logical, theme, lay.header.back);
    chrome.paintTitle(logical, theme, lay.header.back.x + lay.header.back.w + tokens.Space.sm, lay.header.back.y, if (quick_slot < 3) "Choose quick control" else "All controls");
    chrome.paintExit(logical, theme, lay.header.exit);
    if (quick_slot < 3) {
        var prompt_buf: [96]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Tap a channel to place it in quick control {d}.", .{quick_slot + 1}) catch "Tap a channel to add it.";
        font.drawTextRole(logical, shell.x + 28, shell.y + 73, prompt, panel_muted, .body_m);
    }
    const gap: i32 = 18;
    const x0 = shell.x + 28;
    const y0 = shell.y + 102;
    const cw = @divTrunc(shell.w - 56 - gap, 2);
    const chh: i32 = 238;
    const first: u8 = @as(u8, @min(page, 1)) * 4;
    for (0..4) |slot| {
        const col: i32 = @intCast(slot % 2);
        const row: i32 = @intCast(slot / 2);
        const r: geom.Rect = .{ .x = x0 + col * (cw + gap), .y = y0 + row * (chh + gap), .w = cw, .h = chh };
        lay.cards[slot] = r;
        widgets.fillRoundRect(logical, r, tokens.Shape.lg, panel_card);
        widgets.strokeRoundRect(logical, r, tokens.Shape.lg, panel_cyan, 2);
        const idx: u8 = first + @as(u8, @intCast(slot));
        if (idx >= @min(count, 8)) {
            font.drawTextRole(logical, r.x + 28, r.y + 92, "Not configured", panel_muted, .title_m);
            continue;
        }
        const c = channels[idx];
        icons.draw(logical, r.x + 30, r.y + 30, iconFor(c), if (c.temp_alarm_active) theme.err else theme.primary);
        var name_buf: [24]u8 = undefined;
        font.drawTextRole(logical, r.x + 92, r.y + 28, channelName(&c, idx, &name_buf), panel_text, .title_l);
        var value_buf: [32]u8 = undefined;
        const value: []const u8 = if (c.typ == 4 and c.temperature_state == 1)
            std.fmt.bufPrint(&value_buf, "{d:.1} C", .{@as(f32, @floatFromInt(c.temperature_centi_c)) / 100.0}) catch "Temperature"
        else if (c.typ == 3 and c.digital_state == 1) (if (c.digital_value) "HIGH" else "LOW") else if (c.typ == 1 or c.typ == 2) (if (c.digital_value) "ON" else "OFF") else "Unavailable";
        font.drawTextRole(logical, r.x + 92, r.y + 82, value, if (c.temp_alarm_active) theme.err else panel_cyan, .title_m);
        if (c.typ == 1 or c.typ == 2) {
            lay.toggles[slot] = .{ .x = r.x + r.w - 190, .y = r.y + 138, .w = 150, .h = 72 };
            paintLargeSwitch(logical, lay.toggles[slot], c.digital_value);
        } else {
            font.drawTextRole(logical, r.x + 92, r.y + 154, "Tap card to configure", panel_muted, .body_m);
        }
    }
    lay.prev = .{ .x = shell.x + 28, .y = shell.y + shell.h - 66, .w = 180, .h = 52 };
    lay.next = .{ .x = shell.x + shell.w - 208, .y = lay.prev.y, .w = 180, .h = 52 };
    widgets.drawTonalButton(logical, lay.prev, "Previous", theme);
    widgets.drawTonalButton(logical, lay.next, "Next", theme);
    var pbuf: [20]u8 = undefined;
    const ptxt = std.fmt.bufPrint(&pbuf, "Page {d} of 2", .{@min(page, 1) + 1}) catch "Page";
    const tw = font.textWidthStr(ptxt, .body_m);
    font.drawTextRole(logical, shell.x + @divTrunc(shell.w - tw, 2), lay.prev.y + 14, ptxt, panel_muted, .body_m);
    return lay;
}

pub fn hit(lay: Layout, page: u8, x: i32, y: i32) Hit {
    if (chrome.hitBack(lay.header, x, y)) return .{ .kind = .back };
    if (chrome.hitExit(lay.header, x, y)) return .{ .kind = .exit };
    if (lay.prev.contains(x, y)) return .{ .kind = .prev };
    if (lay.next.contains(x, y)) return .{ .kind = .next };
    for (0..4) |i| {
        const channel: u8 = @as(u8, @min(page, 1)) * 4 + @as(u8, @intCast(i));
        if (lay.toggles[i].contains(x, y)) return .{ .kind = .toggle, .channel = channel };
        if (lay.cards[i].contains(x, y)) return .{ .kind = .configure, .channel = channel };
    }
    return .{};
}
