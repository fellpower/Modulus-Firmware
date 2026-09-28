const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const icons = @import("icons_phosphor.zig");
const tool_chrome = @import("m_panel_tool.zig");

pub const Target = enum(u8) { c6, s3, nano, node };
pub const Hit = enum { none, back, exit, target, configure, refresh };
pub const HitInfo = struct { kind: Hit = .none, target: Target = .c6 };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    cards: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    targets: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    configure: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    refresh: geom.Rect = .{},
};

fn cardGeom(enter_t: f32) geom.Rect {
    _ = enter_t;
    return .{ .x = 0, .y = 0, .w = tokens.Logical.width, .h = tokens.Logical.height };
}

fn chipBadge(logical: *fb.LogicalFb, theme: tokens.Theme, cx: i32, cy: i32, label: []const u8) void {
    const chip: geom.Rect = .{ .x = cx - 44, .y = cy - 44, .w = 88, .h = 88 };
    widgets.fillRoundRect(logical, chip, tokens.Shape.md, theme.surface_container_low);
    widgets.strokeRoundRect(logical, chip, tokens.Shape.md, theme.outline_variant, 1);
    var p: i32 = -32;
    while (p <= 32) : (p += 16) {
        logical.fillRect(.{ .x = chip.x - 10, .y = cy + p - 3, .w = 12, .h = 6 }, theme.primary);
        logical.fillRect(.{ .x = chip.x + chip.w - 2, .y = cy + p - 3, .w = 12, .h = 6 }, theme.primary);
        logical.fillRect(.{ .x = cx + p - 3, .y = chip.y - 10, .w = 6, .h = 12 }, theme.primary);
        logical.fillRect(.{ .x = cx + p - 3, .y = chip.y + chip.h - 2, .w = 6, .h = 12 }, theme.primary);
    }
    font.drawTextRole(logical, cx - @divTrunc(font.textWidthStr(label, .headline_m), 2), cy - 17, label, theme.on_surface, .headline_m);
}

fn actionButton(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, label: []const u8) void {
    widgets.drawTonalButton(logical, r, label, theme);
}

fn glowCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, theme.outline_variant, 1);
}

fn targetCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, button: geom.Rect, configure: ?geom.Rect, badge: []const u8, title: []const u8, detail: []const u8, link: []const u8, version: []const u8, online: bool) void {
    glowCard(logical, theme, r);
    chipBadge(logical, theme, r.x + @divTrunc(r.w, 2), r.y + 70, badge);
    font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(title, .headline_m), 2), r.y + 126, title, theme.on_surface, .headline_m);
    font.drawTextRole(logical, r.x + @divTrunc(r.w - font.textWidthStr(detail, .body_l), 2), r.y + 168, detail, theme.on_surface_variant, .body_l);
    const status_w = font.textWidthStr(link, .body_l);
    const sx = r.x + @divTrunc(r.w - status_w - 26, 2);
    widgets.fillRoundRect(logical, .{ .x = sx, .y = r.y + 211, .w = 18, .h = 18 }, 9, if (online) theme.primary else theme.tertiary);
    font.drawTextRole(logical, sx + 28, r.y + 202, link, if (online) theme.primary else theme.on_surface_variant, .body_l);
    const ver = if (version.len > 0) version else "Unknown";
    const prefix = "Version ";
    const vw = font.textWidthStr(prefix, .body_l) + font.textWidthStr(ver, .body_l);
    const vx = r.x + @divTrunc(r.w - vw, 2);
    font.drawTextRole(logical, vx, r.y + 238, prefix, theme.on_surface_variant, .body_l);
    font.drawTextRole(logical, vx + font.textWidthStr(prefix, .body_l), r.y + 238, ver, theme.on_surface, .body_l);
    if (configure) |cfg| actionButton(logical, theme, cfg, "Configure");
    actionButton(logical, theme, button, "Update");
}

fn nodeCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, button: geom.Rect, configure: geom.Rect, online: bool) void {
    glowCard(logical, theme, r);
    icons.drawCenteredScaled(logical, r.x + 62, r.y + @divTrunc(r.h, 2), .plugs, theme.primary, 48);
    font.drawTextRole(logical, r.x + 116, r.y + 15, "Zigbee Node", theme.on_surface, .title_l);
    font.drawTextRole(logical, r.x + 116, r.y + 54, "GPIO, relay and sensor node", theme.on_surface_variant, .body_l);
    font.drawTextRole(logical, r.x + 610, r.y + 34, if (online) "Connected via Zigbee" else "Not connected", if (online) theme.primary else theme.on_surface_variant, .body_l);
    actionButton(logical, theme, configure, "Configure");
    actionButton(logical, theme, button, "Update");
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, c6_online: bool, s3_online: bool, nano_online: bool, node_online: bool, c6_version: []const u8, s3_version: []const u8, nano_version: []const u8, usb_ready: bool, enter_t: f32) Layout {
    widgets.fillScrim(logical, theme);
    const card = cardGeom(enter_t);
    logical.fillRect(card, theme.elev(3));
    var lay: Layout = .{};
    const header: geom.Rect = .{ .x = 8, .y = 8, .w = 1264, .h = 60 };
    widgets.fillRoundRect(logical, header, tokens.Shape.md, theme.elev(3));
    lay.header = .{ .card = card, .back = .{ .x = 12, .y = 12, .w = 56, .h = 52 }, .exit = .{ .x = 1204, .y = 12, .w = 56, .h = 52 } };
    widgets.drawTonalButton(logical, lay.header.back, "<", theme);
    font.drawTextRole(logical, 94, 17, "M", theme.primary, .display_s);
    font.drawTextRole(logical, 126, 19, "Modulus", theme.on_surface, .headline_m);
    logical.fillRect(.{ .x = 260, .y = 18, .w = 2, .h = 40 }, theme.outline_variant);
    font.drawTextRole(logical, 288, 16, "Device Management", theme.on_surface, .headline_l);
    icons.drawCenteredScaled(logical, 928, 38, .usb, theme.primary, 38);
    font.drawTextRole(logical, 958, 15, if (usb_ready) "USB connected" else "USB not connected", theme.on_surface, .title_l);
    font.drawTextRole(logical, 958, 40, if (usb_ready) "FAT32 drive detected" else "Insert FAT32 drive", theme.on_surface_variant, .body_m);
    tool_chrome.paintExit(logical, theme, lay.header.exit);
    font.drawTextRole(logical, 24, 72, "Select a device", theme.on_surface, .headline_l);
    const gap: i32 = 10;
    const x: i32 = 8;
    const y: i32 = 108;
    const w: i32 = 414;
    const h: i32 = 372;
    lay.cards[0] = .{ .x = x, .y = y, .w = w, .h = h };
    lay.cards[1] = .{ .x = x + w + gap, .y = y, .w = w, .h = h };
    lay.cards[2] = .{ .x = x + (w + gap) * 2, .y = y, .w = w, .h = h };
    for (0..3) |i| lay.targets[i] = .{ .x = lay.cards[i].x + 16, .y = lay.cards[i].y + h - 68, .w = w - 32, .h = 56 };
    for (1..2) |i| {
        const row = lay.targets[i];
        const half = @divTrunc(row.w - gap, 2);
        lay.configure[i] = .{ .x = row.x, .y = row.y, .w = half, .h = row.h };
        lay.targets[i] = .{ .x = row.x + half + gap, .y = row.y, .w = row.w - half - gap, .h = row.h };
    }
    lay.cards[3] = .{ .x = x, .y = 490, .w = 1264, .h = 92 };
    lay.configure[3] = .{ .x = 906, .y = 506, .w = 161, .h = 60 };
    lay.targets[3] = .{ .x = 1077, .y = 506, .w = 167, .h = 60 };
    targetCard(logical, theme, lay.cards[0], lay.targets[0], null, "C6", "Internal C6", "Tab5 wireless controller", if (c6_online) "Connected" else "Not connected", c6_version, c6_online);
    targetCard(logical, theme, lay.cards[1], lay.targets[1], lay.configure[1], "S3", "S3 Bridge", "CNC wireless bridge", if (s3_online) "Connected via ESP-NOW" else "Not connected", s3_version, s3_online);
    targetCard(logical, theme, lay.cards[2], lay.targets[2], null, "Z", "NanoH2", "Zigbee coordinator", if (nano_online) "Connected via UART" else "Not connected", nano_version, nano_online);
    nodeCard(logical, theme, lay.cards[3], lay.targets[3], lay.configure[3], node_online);
    const info: geom.Rect = .{ .x = x, .y = 592, .w = 1264, .h = 54 };
    widgets.fillRoundRect(logical, info, tokens.Shape.md, theme.surface_container_low);
    icons.drawCenteredScaled(logical, info.x + 46, info.y + 29, .usb, theme.primary, 38);
    font.drawTextRole(logical, info.x + 86, info.y + 7, "Insert a FAT32 USB drive containing the matching OTA file.", theme.on_surface, .body_l);
    font.drawTextRole(logical, info.x + 86, info.y + 30, "The image is checked before flashing.", theme.on_surface_variant, .body_m);
    lay.refresh = .{ .x = x, .y = 654, .w = 1264, .h = 54 };
    const refresh_ink = widgets.drawButtonSurface(logical, lay.refresh, .tonal, .enabled, theme, 0, 0, 0);
    icons.drawCenteredScaled(logical, 535, 681, .broadcast, refresh_ink, 34);
    font.drawTextRole(logical, 566, 664, "Rescan USB drive", refresh_ink, .title_l);
    return lay;
}

pub fn hit(lay: Layout, x: i32, y: i32) HitInfo {
    if (tool_chrome.hitBack(lay.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(lay.header, x, y)) return .{ .kind = .exit };
    if (lay.refresh.contains(x, y)) return .{ .kind = .refresh };
    for (lay.configure, 0..) |r, i| if (!r.isEmpty() and r.contains(x, y))
        return .{ .kind = .configure, .target = @enumFromInt(i) };
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
    try @import("std").testing.expect(lay.configure[1].w >= tokens.Logical.touch_min);
    try @import("std").testing.expect(lay.configure[3].w >= tokens.Logical.touch_min);
    try @import("std").testing.expectEqual(Hit.configure, hit(lay, lay.configure[1].x + 5, lay.configure[1].y + 5).kind);
    try @import("std").testing.expectEqual(Target.s3, hit(lay, lay.configure[1].x + 5, lay.configure[1].y + 5).target);
    try @import("std").testing.expectEqual(Hit.configure, hit(lay, lay.configure[3].x + 5, lay.configure[3].y + 5).kind);
    try @import("std").testing.expectEqual(Target.node, hit(lay, lay.configure[3].x + 5, lay.configure[3].y + 5).target);
    for (lay.targets, 0..) |r, i| {
        const h = hit(lay, r.x + 5, r.y + 5);
        try @import("std").testing.expectEqual(Hit.target, h.kind);
        try @import("std").testing.expectEqual(@as(Target, @enumFromInt(i)), h.target);
    }
}
