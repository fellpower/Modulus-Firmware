const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const icons = @import("icons_phosphor.zig");
const tool_chrome = @import("m_panel_tool.zig");
const color = @import("color.zig");
const bg = color.Rgb565.fromHex(0x001426);
const card_bg = color.Rgb565.fromHex(0x03233F);
const cyan = color.Rgb565.fromHex(0x18C8FF);
const white = color.Rgb565.fromHex(0xF4FAFF);
const muted = color.Rgb565.fromHex(0xA9C7E5);
const green = color.Rgb565.fromHex(0x00EE88);
const action_blue = color.Rgb565.fromHex(0x079BFF);

pub const Target = enum(u8) { c6, s3, nano, node };
pub const Hit = enum { none, back, exit, target, refresh };
pub const HitInfo = struct { kind: Hit = .none, target: Target = .c6 };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    cards: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    targets: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    refresh: geom.Rect = .{},
};

fn cardGeom(enter_t: f32) geom.Rect {
    _ = enter_t;
    return .{ .x = 20, .y = 20, .w = tokens.Logical.width - 40, .h = tokens.Logical.height - 40 };
}

fn chipBadge(logical: *fb.LogicalFb, cx: i32, cy: i32, label: []const u8) void {
    const chip: geom.Rect = .{ .x = cx - 44, .y = cy - 44, .w = 88, .h = 88 };
    widgets.fillRoundRect(logical, chip, 10, bg);
    widgets.strokeRoundRect(logical, chip, 10, color.Rgb565.fromHex(0x7EF3FF), 6);
    var p: i32 = -32;
    while (p <= 32) : (p += 16) {
        logical.fillRect(.{ .x = chip.x - 10, .y = cy + p - 3, .w = 12, .h = 6 }, color.Rgb565.fromHex(0x7EF3FF));
        logical.fillRect(.{ .x = chip.x + chip.w - 2, .y = cy + p - 3, .w = 12, .h = 6 }, color.Rgb565.fromHex(0x7EF3FF));
        logical.fillRect(.{ .x = cx + p - 3, .y = chip.y - 10, .w = 6, .h = 12 }, color.Rgb565.fromHex(0x7EF3FF));
        logical.fillRect(.{ .x = cx + p - 3, .y = chip.y + chip.h - 2, .w = 6, .h = 12 }, color.Rgb565.fromHex(0x7EF3FF));
    }
    font.drawTextRole(logical, cx - @divTrunc(font.textWidthStr(label, .headline_m), 2), cy - 17, label, white, .headline_m);
}

fn actionButton(logical: *fb.LogicalFb, r: geom.Rect, label: []const u8) void {
    widgets.fillRoundRect(logical, .{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, 16, color.Rgb565.fromHex(0x03598E));
    widgets.fillRoundRect(logical, r, 14, action_blue);
    widgets.strokeRoundRect(logical, r, 14, cyan, 2);
    font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(label, .title_l), 2), r.y + 9, label, white, .title_l);
}

fn glowCard(logical: *fb.LogicalFb, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, color.Rgb565.fromHex(0x021B33));
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, color.Rgb565.fromHex(0x075D91), 5);
    widgets.strokeRoundRect(logical, .{ .x = r.x + 3, .y = r.y + 3, .w = r.w - 6, .h = r.h - 6 }, tokens.Shape.lg - 2, cyan, 2);
}

fn targetCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, button: geom.Rect, badge: []const u8, title: []const u8, detail: []const u8, link: []const u8, version: []const u8, online: bool) void {
    glowCard(logical, r);
    chipBadge(logical, r.x + @divTrunc(r.w, 2), r.y + 70, badge);
    font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(title, .headline_m), 2), r.y + 126, title, white, .headline_m);
    font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(detail, .body_l), 2), r.y + 168, detail, muted, .body_l);
    const status_w = font.textWidthStr(link, .body_l);
    const sx = r.x + @divTrunc(r.w - status_w - 26, 2);
    widgets.fillRoundRect(logical, .{ .x = sx, .y = r.y + 211, .w = 18, .h = 18 }, 9, if (online) green else theme.error_container);
    font.drawTextRole(logical, sx + 28, r.y + 202, link, if (online) green else theme.on_error_container, .body_l);
    const ver = if (version.len > 0) version else "Unknown";
    const prefix = "Version ";
    const vw = font.textWidthStr(prefix, .body_l) + font.textWidthStr(ver, .body_l);
    const vx = r.x + @divTrunc(r.w - vw, 2);
    font.drawTextRole(logical, vx, r.y + 238, prefix, muted, .body_l);
    font.drawTextRole(logical, vx + font.textWidthStr(prefix, .body_l), r.y + 238, ver, white, .body_l);
    actionButton(logical, button, "Open update");
}

fn nodeCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, button: geom.Rect, online: bool) void {
    glowCard(logical, r);
    icons.drawCenteredScaled(logical, r.x + 62, r.y + @divTrunc(r.h, 2), .plugs, cyan, 48);
    font.drawTextRole(logical, r.x + 116, r.y + 15, "Zigbee Node", white, .title_l);
    font.drawTextRole(logical, r.x + 116, r.y + 54, "GPIO, relay and sensor node", muted, .body_l);
    font.drawTextRole(logical, r.x + r.w - 450, r.y + 34, if (online) "Connected via Zigbee" else "Not connected", if (online) green else theme.on_error_container, .body_l);
    actionButton(logical, button, "USB update");
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, c6_online: bool, s3_online: bool, nano_online: bool, node_online: bool, c6_version: []const u8, s3_version: []const u8, nano_version: []const u8, usb_ready: bool, enter_t: f32) Layout {
    logical.fillRect(.{ .x = 0, .y = 0, .w = tokens.Logical.width, .h = tokens.Logical.height }, bg);
    const card = cardGeom(enter_t);
    widgets.fillRoundRect(logical, card, tokens.Shape.dialog, bg);
    widgets.strokeRoundRect(logical, card, tokens.Shape.dialog, cyan, 1);
    var lay: Layout = .{};
    const header: geom.Rect = .{ .x = 8, .y = 8, .w = 1264, .h = 60 };
    widgets.fillRoundRect(logical, header, 12, card_bg);
    widgets.strokeRoundRect(logical, header, 12, cyan, 2);
    lay.header = .{ .card = card, .back = .{ .x = 12, .y = 12, .w = 56, .h = 52 }, .exit = .{ .x = 1204, .y = 12, .w = 56, .h = 52 } };
    widgets.fillRoundRect(logical, lay.header.back, 10, color.Rgb565.fromHex(0x052E52));
    font.drawTextRole(logical, 28, 18, "<", white, .headline_l);
    font.drawTextRole(logical, 94, 17, "M", cyan, .display_s);
    font.drawTextRole(logical, 126, 19, "Modulus", white, .headline_m);
    logical.fillRect(.{ .x = 260, .y = 18, .w = 2, .h = 40 }, cyan);
    font.drawTextRole(logical, 288, 16, "Firmware Update", white, .headline_l);
    icons.drawCenteredScaled(logical, 928, 38, .usb, cyan, 38);
    font.drawTextRole(logical, 958, 15, if (usb_ready) "USB connected" else "USB not connected", white, .title_l);
    font.drawTextRole(logical, 958, 40, if (usb_ready) "FAT32 drive detected" else "Insert FAT32 drive", muted, .body_m);
    widgets.fillRoundRect(logical, lay.header.exit, 10, color.Rgb565.fromHex(0x052E52));
    font.drawTextRole(logical, 1220, 18, "X", white, .headline_l);
    font.drawTextRole(logical, 14, 72, "Select a device", white, .headline_l);
    const gap: i32 = 10;
    const x: i32 = 8;
    const y: i32 = 108;
    const w: i32 = 414;
    const h: i32 = 372;
    lay.cards[0] = .{ .x = x, .y = y, .w = w, .h = h };
    lay.cards[1] = .{ .x = x + w + gap, .y = y, .w = w, .h = h };
    lay.cards[2] = .{ .x = x + (w + gap) * 2, .y = y, .w = w, .h = h };
    for (0..3) |i| lay.targets[i] = .{ .x = lay.cards[i].x + 16, .y = lay.cards[i].y + h - 68, .w = w - 32, .h = 56 };
    lay.cards[3] = .{ .x = x, .y = 490, .w = 1264, .h = 92 };
    lay.targets[3] = .{ .x = 1020, .y = 506, .w = 224, .h = 60 };
    targetCard(logical, theme, lay.cards[0], lay.targets[0], "C6", "Internal C6", "Tab5 wireless controller", if (c6_online) "Connected" else "Not connected", c6_version, c6_online);
    targetCard(logical, theme, lay.cards[1], lay.targets[1], "S3", "S3 Bridge", "CNC wireless bridge", if (s3_online) "Connected via ESP-NOW" else "Not connected", s3_version, s3_online);
    targetCard(logical, theme, lay.cards[2], lay.targets[2], "Z", "NanoH2", "Zigbee coordinator", if (nano_online) "Connected via UART" else "Not connected", nano_version, nano_online);
    nodeCard(logical, theme, lay.cards[3], lay.targets[3], node_online);
    const info: geom.Rect = .{ .x = x, .y = 592, .w = 1264, .h = 54 };
    widgets.fillRoundRect(logical, info, tokens.Shape.md, card_bg);
    widgets.strokeRoundRect(logical, info, tokens.Shape.md, cyan, 1);
    icons.drawCenteredScaled(logical, info.x + 46, info.y + 29, .usb, cyan, 38);
    font.drawTextRole(logical, info.x + 86, info.y + 7, "Insert a FAT32 USB drive containing the matching OTA file.", white, .body_l);
    font.drawTextRole(logical, info.x + 86, info.y + 30, "The image is checked before flashing.", muted, .body_m);
    lay.refresh = .{ .x = x, .y = 654, .w = 1264, .h = 54 };
    widgets.fillRoundRect(logical, lay.refresh, 12, card_bg);
    widgets.strokeRoundRect(logical, lay.refresh, 12, cyan, 2);
    icons.drawCenteredScaled(logical, 535, 681, .broadcast, cyan, 34);
    font.drawTextRole(logical, 566, 664, "Rescan USB drive", white, .title_l);
    return lay;
}

pub fn hit(lay: Layout, x: i32, y: i32) HitInfo {
    if (tool_chrome.hitBack(lay.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(lay.header, x, y)) return .{ .kind = .exit };
    if (lay.refresh.contains(x, y)) return .{ .kind = .refresh };
    for (lay.targets, 0..) |r, i| if (r.contains(x, y))
        return .{ .kind = .target, .target = @enumFromInt(i) };
    return .{};
}

test "firmware update touch targets are glove friendly" {
    const gpa = @import("std").testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), true, true, true, true, "2.11.4", "3.1.4", "3.1.4", true, 1);
    for (lay.targets) |r| try @import("std").testing.expect(r.h >= tokens.Logical.touch_min);
}
