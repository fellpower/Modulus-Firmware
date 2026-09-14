//! M-Panel NanoH2 Update — guarded ESP-Hosted slave OTA from USB.

const std = @import("std");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const tool_chrome = @import("m_panel_tool.zig");
const icons = @import("icons_phosphor.zig");

pub const max_files = 8;
pub const name_len = 96;

pub const Phase = enum(u8) { idle, ready, armed, flashing, success, failed };
pub const Action = enum(u8) { refresh, select, check, flash };
pub const View = enum(u8) { dashboard, firmware };

pub const State = struct {
    phase: Phase = .idle,
    file_count: u8 = 0,
    selected: u8 = 0,
    progress: u8 = 0,
    nano_connected: bool = false,
    version: [24]u8 = .{0} ** 24,
    version_len: u8 = 0,
    image_version: [32]u8 = .{0} ** 32,
    image_version_len: u8 = 0,
    files: [max_files][name_len]u8 = [_][name_len]u8{.{0} ** name_len} ** max_files,
    file_lens: [max_files]u8 = .{0} ** max_files,
    status: [160]u8 = .{0} ** 160,
    status_len: u8 = 0,
    view: View = .dashboard,

    pub fn statusText(self: *const State) []const u8 {
        return self.status[0..self.status_len];
    }
    pub fn versionText(self: *const State) []const u8 {
        return self.version[0..self.version_len];
    }
    pub fn imageVersionText(self: *const State) []const u8 {
        return self.image_version[0..self.image_version_len];
    }
    pub fn fileText(self: *const State, i: usize) []const u8 {
        if (i >= self.file_count) return "";
        return self.files[i][0..self.file_lens[i]];
    }
};

pub const Hit = enum { none, scrim, back, exit, detail_back, firmware, refresh, row, check, flash };
pub const HitInfo = struct { kind: Hit = .none, index: u8 = 0 };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    detail_back: geom.Rect = .{},
    firmware: geom.Rect = .{},
    refresh: geom.Rect = .{},
    rows: [max_files]geom.Rect = [_]geom.Rect{.{}} ** max_files,
    row_n: u8 = 0,
    check: geom.Rect = .{},
    flash: geom.Rect = .{},
};

fn cardGeom(t0: f32) geom.Rect {
    const t = std.math.clamp(t0, 0, 1);
    const w: i32 = @intFromFloat(1220.0 * (0.92 + 0.08 * t));
    const h: i32 = @intFromFloat(650.0 * (0.92 + 0.08 * t));
    return .{ .x = @divTrunc(tokens.Logical.width - w, 2), .y = @divTrunc(tokens.Logical.height - h, 2), .w = w, .h = h };
}

fn drawDisabled(logical: *fb.LogicalFb, r: geom.Rect, label: []const u8, theme: tokens.Theme) void {
    widgets.drawButton(logical, r, label, .filled, .disabled, theme);
}

fn drawFittedText(logical: *fb.LogicalFb, x: i32, y: i32, max_w: i32, text: []const u8, ink: @TypeOf(tokens.Theme.industrialTealDark().on_surface), role: tokens.TypeRole) void {
    if (max_w <= 0 or text.len == 0) return;
    if (font.textWidthStr(text, role) <= max_w) {
        font.drawTextRole(logical, x, y, text, ink, role);
        return;
    }
    const suffix = "...";
    var n = text.len;
    while (n > 0 and font.textWidthStr(text[0..n], role) + font.textWidthStr(suffix, role) > max_w) : (n -= 1) {}
    var buf: [164]u8 = undefined;
    const keep = @min(n, buf.len - suffix.len);
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep .. keep + suffix.len], suffix);
    font.drawTextRole(logical, x, y, buf[0 .. keep + suffix.len], ink, role);
}

fn drawStatusCard(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container_low);
    const dot: geom.Rect = .{ .x = r.x + tokens.Space.lg, .y = r.y + 24, .w = 18, .h = 18 };
    widgets.fillRoundRect(logical, dot, 9, if (state.nano_connected) theme.primary else theme.tertiary);
    font.drawTextRole(logical, dot.x + 34, r.y + 16, "NanoH2 Zigbee Coordinator", theme.on_surface, .title_m);
    font.drawTextRole(logical, dot.x + 34, r.y + 51, if (state.nano_connected) "UART connected" else "NanoH2 not connected", theme.on_surface_variant, .body_m);
    if (state.version_len != 0) {
        var version: [48]u8 = undefined;
        const version_text = std.fmt.bufPrint(&version, "Firmware: {s}", .{state.versionText()}) catch "Firmware version unavailable";
        drawFittedText(logical, r.x + r.w - 330, r.y + 18, 306, version_text, theme.primary, .body_m);
    }
}

fn drawDashboardCard(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, theme.outline_variant, 1);
    icons.draw(logical, r.x + tokens.Space.lg, r.y + tokens.Space.lg, .usb, theme.primary);
    font.drawTextRole(logical, r.x + 76, r.y + 25, "Firmware Update", theme.on_surface, .title_m);
    var installed: [64]u8 = undefined;
    var selected: [64]u8 = undefined;
    const installed_text = std.fmt.bufPrint(&installed, "Installed: {s}", .{if (state.version_len != 0) state.versionText() else "unknown"}) catch "Installed: unknown";
    const selected_text = std.fmt.bufPrint(&selected, "On USB: {s}", .{if (state.image_version_len != 0) state.imageVersionText() else "no verified image"}) catch "On USB: unavailable";
    drawFittedText(logical, r.x + tokens.Space.lg, r.y + 92, r.w - tokens.Space.lg * 2, installed_text, theme.on_surface_variant, .body_l);
    drawFittedText(logical, r.x + tokens.Space.lg, r.y + 132, r.w - tokens.Space.lg * 2, selected_text, theme.on_surface_variant, .body_l);
    if (state.version_len != 0 and state.image_version_len != 0 and std.mem.eql(u8, state.versionText(), state.imageVersionText())) {
        font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + 178, "Already installed", theme.primary, .label_m);
    }
    font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + r.h - 50, "Open", theme.primary, .label_l);
    icons.draw(logical, r.x + r.w - 52, r.y + r.h - 54, .caret_right, theme.primary);
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, enter_t: f32) Layout {
    widgets.fillScrim(logical, theme);
    const card = cardGeom(enter_t);
    widgets.fillRoundRect(logical, card, tokens.Shape.dialog, theme.elev(3));
    var lay: Layout = .{};
    lay.header = tool_chrome.headerChrome(card);
    tool_chrome.paintBackToPanel(logical, theme, lay.header.back);
    tool_chrome.paintTitle(logical, theme, lay.header.back.x + lay.header.back.w + tokens.Space.sm, lay.header.back.y, "NanoH2");
    tool_chrome.paintExit(logical, theme, lay.header.exit);

    const x = card.x + tokens.Space.lg;
    const right = card.x + card.w - tokens.Space.lg;
    if (state.view == .dashboard) {
        const status_card: geom.Rect = .{ .x = x, .y = lay.header.back.y + lay.header.back.h + tokens.Space.md, .w = right - x, .h = 104 };
        drawStatusCard(logical, theme, state, status_card);
        lay.firmware = .{ .x = x, .y = status_card.y + status_card.h + tokens.Space.lg, .w = right - x, .h = 300 };
        drawDashboardCard(logical, theme, state, lay.firmware);
        return lay;
    }

    var y = lay.header.back.y + lay.header.back.h + tokens.Space.sm;
    lay.detail_back = .{ .x = x, .y = y, .w = 64, .h = 56 };
    widgets.drawTonalButton(logical, lay.detail_back, "<", theme);
    font.drawTextRole(logical, x + 84, y + 13, "Firmware Update", theme.on_surface, .title_m);
    y += 72;
    const link = if (state.nano_connected) "UART connected" else "NanoH2 not connected";
    font.drawTextRole(logical, x, y, link, if (state.nano_connected) theme.primary else theme.on_error_container, .body_m);
    if (state.version_len != 0) {
        var version: [48]u8 = undefined;
        const version_text = std.fmt.bufPrint(&version, "Firmware: {s}", .{state.versionText()}) catch "Firmware version unavailable";
        drawFittedText(logical, x + 330, y, 390, version_text, theme.primary, .body_m);
    }
    lay.refresh = .{ .x = right - 190, .y = y - 10, .w = 190, .h = 60 };
    const locked = state.phase == .flashing;
    if (locked) drawDisabled(logical, lay.refresh, "Refresh USB", theme) else widgets.drawTonalButton(logical, lay.refresh, "Refresh USB", theme);
    y += 34;
    var installed: [64]u8 = undefined;
    var selected_version: [64]u8 = undefined;
    const installed_text = std.fmt.bufPrint(&installed, "Installed: {s}", .{if (state.version_len != 0) state.versionText() else "unknown"}) catch "Installed: unknown";
    const selected_text = std.fmt.bufPrint(&selected_version, "Selected image: {s}", .{if (state.image_version_len != 0) state.imageVersionText() else "none"}) catch "Selected image: none";
    font.drawTextRole(logical, x, y, installed_text, theme.on_surface_variant, .body_m);
    font.drawTextRole(logical, x + 310, y, selected_text, theme.on_surface_variant, .body_m);
    if (state.version_len != 0 and state.image_version_len != 0 and std.mem.eql(u8, state.versionText(), state.imageVersionText())) {
        font.drawTextRole(logical, x + 690, y, "Already installed", theme.primary, .label_m);
    }
    y += 42;

    const row_h: i32 = tokens.Logical.touch_min;
    const row_gap: i32 = tokens.Space.xs;
    lay.row_n = @min(state.file_count, 5);
    var i: u8 = 0;
    while (i < lay.row_n) : (i += 1) {
        const r: geom.Rect = .{ .x = x, .y = y, .w = right - x, .h = row_h };
        lay.rows[i] = r;
        const selected = i == state.selected;
        widgets.fillRoundRect(logical, r, tokens.Shape.md, if (selected) theme.secondary_container else theme.surface_container_low);
        if (!selected) widgets.strokeRoundRect(logical, r, tokens.Shape.md, theme.outline_variant, 1);
        drawFittedText(logical, r.x + tokens.Space.md, r.y + 13, r.w - tokens.Space.md * 2, state.fileText(i), if (selected) theme.on_secondary_container else theme.on_surface, .body_m);
        y += row_h + row_gap;
    }
    if (lay.row_n == 0) font.drawTextRole(logical, x, y + 8, "No verified ESP32-NanoH2 app images found on USB.", theme.on_surface_variant, .body_m);

    const status_y = card.y + card.h - 150;
    drawFittedText(logical, x, status_y, right - x, state.statusText(), if (state.phase == .failed) theme.on_error_container else theme.on_surface_variant, .body_m);
    const bar: geom.Rect = .{ .x = x, .y = status_y + 27, .w = right - x, .h = 10 };
    widgets.fillRoundRect(logical, bar, 5, theme.surface_container_high);
    if (state.progress > 0) {
        const fill: geom.Rect = .{ .x = bar.x, .y = bar.y, .w = @divTrunc(bar.w * state.progress, 100), .h = bar.h };
        widgets.fillRoundRect(logical, fill, 5, theme.primary);
    }

    const action_h: i32 = 64;
    const action_w: i32 = 230;
    const by = card.y + card.h - tokens.Space.lg - action_h;
    lay.check = .{ .x = x, .y = by, .w = action_w, .h = action_h };
    lay.flash = .{ .x = x + action_w + tokens.Space.md, .y = by, .w = action_w, .h = action_h };
    const can_check = state.file_count > 0 and !locked;
    if (can_check) widgets.drawFilledButton(logical, lay.check, "1. Check image", theme) else drawDisabled(logical, lay.check, "1. Check image", theme);
    if (state.phase == .armed) widgets.drawDangerButton(logical, lay.flash, "2. Flash NanoH2", theme) else drawDisabled(logical, lay.flash, "2. Flash NanoH2", theme);
    return lay;
}

pub fn hit(layout: Layout, x: i32, y: i32) HitInfo {
    if (tool_chrome.hitBack(layout.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(layout.header, x, y)) return .{ .kind = .exit };
    if (tool_chrome.hitScrim(layout.header, x, y)) return .{ .kind = .scrim };
    if (layout.detail_back.contains(x, y)) return .{ .kind = .detail_back };
    if (layout.firmware.contains(x, y)) return .{ .kind = .firmware };
    if (layout.refresh.contains(x, y)) return .{ .kind = .refresh };
    var i: u8 = 0;
    while (i < layout.row_n) : (i += 1) if (layout.rows[i].contains(x, y)) return .{ .kind = .row, .index = i };
    if (layout.check.contains(x, y)) return .{ .kind = .check };
    if (layout.flash.contains(x, y)) return .{ .kind = .flash };
    return .{};
}

test "NanoH2 OTA buttons meet minimum touch size" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{ .view = .firmware };
    state.file_count = 1;
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.check.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.flash.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.refresh.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.rows[0].h >= tokens.Logical.touch_min);
}

test "NanoH2 dashboard exposes one large firmware card" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const state: State = .{ .view = .dashboard, .nano_connected = true };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.firmware.h >= tokens.Logical.touch_min);
    try std.testing.expectEqual(Hit.firmware, hit(lay, lay.firmware.x + 4, lay.firmware.y + 4).kind);
}
