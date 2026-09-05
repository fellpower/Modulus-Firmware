//! M-Panel S3 Update — guarded ESP-NOW OTA from USB.

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
pub const Action = enum(u8) { refresh, select, check, flash, restart, config_refresh, config_apply, config_test };
pub const View = enum(u8) { dashboard, firmware, settings, review };

pub const State = struct {
    phase: Phase = .idle,
    file_count: u8 = 0,
    selected: u8 = 0,
    progress: u8 = 0,
    s3_connected: bool = false,
    version: [32]u8 = .{0} ** 32,
    version_len: u8 = 0,
    image_version: [32]u8 = .{0} ** 32,
    image_version_len: u8 = 0,
    files: [max_files][name_len]u8 = [_][name_len]u8{.{0} ** name_len} ** max_files,
    file_lens: [max_files]u8 = .{0} ** max_files,
    status: [160]u8 = .{0} ** 160,
    status_len: u8 = 0,
    view: View = .dashboard,
    config_supported: bool = false,
    test_supported: bool = false,
    config_busy: bool = false,
    config_loaded: bool = false,
    uart_tx: i8 = -1,
    uart_rx: i8 = -1,
    uart_baud: u32 = 115200,
    draft_tx: i8 = -1,
    draft_rx: i8 = -1,
    draft_baud: u32 = 115200,

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

pub const Hit = enum { none, scrim, back, exit, detail_back, firmware, settings, refresh, row, check, flash, restart, tx_minus, tx_plus, rx_minus, rx_plus, baud, test_cnc, review, cancel, apply };
pub const HitInfo = struct { kind: Hit = .none, index: u8 = 0 };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    refresh: geom.Rect = .{},
    rows: [max_files]geom.Rect = [_]geom.Rect{.{}} ** max_files,
    row_n: u8 = 0,
    check: geom.Rect = .{},
    flash: geom.Rect = .{},
    restart: geom.Rect = .{},
    firmware: geom.Rect = .{},
    settings: geom.Rect = .{},
    detail_back: geom.Rect = .{},
    tx_minus: geom.Rect = .{},
    tx_plus: geom.Rect = .{},
    rx_minus: geom.Rect = .{},
    rx_plus: geom.Rect = .{},
    baud: geom.Rect = .{},
    test_cnc: geom.Rect = .{},
    review: geom.Rect = .{},
    cancel: geom.Rect = .{},
    apply: geom.Rect = .{},
    file_area: geom.Rect = .{},
    status_area: geom.Rect = .{},
};

fn drawValueRow(logical: *fb.LogicalFb, theme: tokens.Theme, area: geom.Rect, label: []const u8, value: i32, minus: *geom.Rect, plus: *geom.Rect) void {
    widgets.fillRoundRect(logical, area, tokens.Shape.lg, theme.surface_container_low);
    font.drawTextRole(logical, area.x + tokens.Space.lg, area.y + 12, label, theme.on_surface_variant, .label_m);
    const control_y = area.y + 43;
    minus.* = .{ .x = area.x + tokens.Space.lg, .y = control_y, .w = 72, .h = 58 };
    plus.* = .{ .x = area.x + area.w - tokens.Space.lg - 72, .y = control_y, .w = 72, .h = 58 };
    widgets.drawTonalButton(logical, minus.*, "-", theme);
    widgets.drawTonalButton(logical, plus.*, "+", theme);
    var buf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "GPIO {d}", .{value}) catch "GPIO ?";
    const tw = font.textWidthStr(txt, .title_m);
    font.drawTextRole(logical, area.x + @divTrunc(area.w - tw, 2), control_y + 14, txt, theme.primary, .title_m);
}

fn cardGeom(t0: f32) geom.Rect {
    const t = std.math.clamp(t0, 0, 1);
    const w: i32 = @intFromFloat(1220.0 * (0.92 + 0.08 * t));
    const h: i32 = @intFromFloat(650.0 * (0.92 + 0.08 * t));
    return .{ .x = @divTrunc(tokens.Logical.width - w, 2), .y = @divTrunc(tokens.Logical.height - h, 2), .w = w, .h = h };
}

fn disabled(logical: *fb.LogicalFb, r: geom.Rect, label: []const u8, theme: tokens.Theme) void {
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

fn displayFileName(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "USB: ")) text[5..] else text;
}

fn shortVersion(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        if (!std.ascii.isDigit(text[start])) continue;
        var end = start;
        var dots: u8 = 0;
        while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) : (end += 1) {
            if (text[end] == '.') dots += 1;
        }
        if (dots >= 2 and end > start and text[end - 1] != '.') {
            return text[if (start > 0 and text[start - 1] == 'v') start - 1 else start..end];
        }
    }
    return text;
}

fn drawStatusCard(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container_low);
    const dot: geom.Rect = .{ .x = r.x + tokens.Space.lg, .y = r.y + 24, .w = 18, .h = 18 };
    widgets.fillRoundRect(logical, dot, 9, if (state.s3_connected) theme.primary else theme.tertiary);
    font.drawTextRole(logical, dot.x + 34, r.y + 16, "S3 Bridge", theme.on_surface, .title_m);
    font.drawTextRole(logical, dot.x + 34, r.y + 51, if (state.s3_connected) "ESP-NOW connected" else "Waiting for ESP-NOW", theme.on_surface_variant, .body_m);
    if (state.version_len != 0) drawFittedText(logical, r.x + r.w - 300, r.y + 18, 276, shortVersion(state.versionText()), theme.on_surface_variant, .body_m);
    var uart: [64]u8 = undefined;
    const uart_text = if (state.config_loaded)
        (std.fmt.bufPrint(&uart, "TX {d}  |  RX {d}  |  {d} baud", .{ state.uart_tx, state.uart_rx, state.uart_baud }) catch "UART configuration unavailable")
    else
        "UART configuration loading...";
    drawFittedText(logical, r.x + 520, r.y + 55, r.w - 520 - tokens.Space.lg, uart_text, theme.on_surface, .body_l);
}

fn drawDashboardCard(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, icon: icons.Id, title: []const u8, detail: []const u8) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, theme.outline_variant, 1);
    icons.draw(logical, r.x + tokens.Space.lg, r.y + tokens.Space.lg, icon, theme.primary);
    font.drawTextRole(logical, r.x + 76, r.y + 25, title, theme.on_surface, .title_m);
    font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + 92, detail, theme.on_surface_variant, .body_l);
    font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + r.h - 50, "Open", theme.primary, .label_l);
    icons.draw(logical, r.x + r.w - 52, r.y + r.h - 54, .caret_right, theme.primary);
}

fn drawFirmwareCard(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, r: geom.Rect) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.lg, theme.surface_container);
    widgets.strokeRoundRect(logical, r, tokens.Shape.lg, theme.outline_variant, 1);
    icons.draw(logical, r.x + tokens.Space.lg, r.y + tokens.Space.lg, .usb, theme.primary);
    font.drawTextRole(logical, r.x + 76, r.y + 25, "Firmware Update", theme.on_surface, .title_m);
    var installed: [64]u8 = undefined;
    var selected: [64]u8 = undefined;
    const installed_text = std.fmt.bufPrint(&installed, "Installed: {s}", .{if (state.version_len != 0) shortVersion(state.versionText()) else "unknown"}) catch "Installed: unknown";
    const selected_text = std.fmt.bufPrint(&selected, "On USB: {s}", .{if (state.image_version_len != 0) shortVersion(state.imageVersionText()) else "no verified image"}) catch "On USB: unavailable";
    drawFittedText(logical, r.x + tokens.Space.lg, r.y + 92, r.w - tokens.Space.lg * 2, installed_text, theme.on_surface_variant, .body_l);
    drawFittedText(logical, r.x + tokens.Space.lg, r.y + 132, r.w - tokens.Space.lg * 2, selected_text, theme.on_surface_variant, .body_l);
    if (state.version_len != 0 and state.image_version_len != 0 and std.mem.eql(u8, state.versionText(), state.imageVersionText())) {
        font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + 178, "Already installed", theme.primary, .label_m);
    }
    font.drawTextRole(logical, r.x + tokens.Space.lg, r.y + r.h - 50, "Open", theme.primary, .label_l);
    icons.draw(logical, r.x + r.w - 52, r.y + r.h - 54, .caret_right, theme.primary);
}

fn paintDetailHeading(logical: *fb.LogicalFb, theme: tokens.Theme, lay: *Layout, card: geom.Rect, title: []const u8) i32 {
    const x = card.x + tokens.Space.lg;
    const y = lay.header.back.y + lay.header.back.h + tokens.Space.sm;
    lay.detail_back = .{ .x = x, .y = y, .w = 64, .h = 56 };
    widgets.drawTonalButton(logical, lay.detail_back, "<", theme);
    font.drawTextRole(logical, x + 84, y + 13, title, theme.on_surface, .title_m);
    return y + 72;
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, enter_t: f32) Layout {
    widgets.fillScrim(logical, theme);
    const card = cardGeom(enter_t);
    widgets.fillRoundRect(logical, card, tokens.Shape.dialog, theme.elev(3));
    var lay: Layout = .{};
    lay.header = tool_chrome.headerChrome(card);
    tool_chrome.paintBackToPanel(logical, theme, lay.header.back);
    tool_chrome.paintTitle(logical, theme, lay.header.back.x + lay.header.back.w + tokens.Space.sm, lay.header.back.y, "S3");
    tool_chrome.paintExit(logical, theme, lay.header.exit);

    const x = card.x + tokens.Space.lg;
    const right = card.x + card.w - tokens.Space.lg;

    if (state.view == .dashboard) {
        const status_card: geom.Rect = .{ .x = x, .y = lay.header.back.y + lay.header.back.h + tokens.Space.md, .w = right - x, .h = 104 };
        drawStatusCard(logical, theme, state, status_card);
        const gap = tokens.Space.lg;
        const tile_y = status_card.y + status_card.h + gap;
        const tile_w = @divTrunc(status_card.w - gap, 2);
        lay.firmware = .{ .x = x, .y = tile_y, .w = tile_w, .h = 300 };
        lay.settings = .{ .x = x + tile_w + gap, .y = tile_y, .w = tile_w, .h = 300 };
        drawFirmwareCard(logical, theme, state, lay.firmware);
        var cfg_detail: [80]u8 = undefined;
        const cfg_text = if (state.config_loaded)
            (std.fmt.bufPrint(&cfg_detail, "TX GPIO {d}  /  RX GPIO {d}  /  {d}", .{ state.uart_tx, state.uart_rx, state.uart_baud }) catch "Remote UART configuration")
        else if (state.config_supported) "Read UART settings from the S3" else "Update S3 firmware to enable settings";
        drawDashboardCard(logical, theme, lay.settings, .plugs, "UART Settings", cfg_text);
        return lay;
    }

    var y = paintDetailHeading(logical, theme, &lay, card, if (state.view == .firmware) "Firmware Update" else "UART Settings");

    if (state.view != .firmware) {
        const link = if (state.s3_connected) "Connected via ESP-NOW" else "S3 not connected";
        font.drawTextRole(logical, x, y, link, if (state.s3_connected) theme.primary else theme.on_error_container, .body_m);
        y += 42;
        if (!state.config_supported) {
            font.drawTextRole(logical, x, y, "Update the S3 firmware to enable remote UART settings.", theme.on_error_container, .body_l);
            lay.refresh = .{ .x = x, .y = y + 70, .w = 260, .h = 64 };
            widgets.drawTonalButton(logical, lay.refresh, "Retry connection", theme);
            return lay;
        }
        const gap = tokens.Space.md;
        const col_w = @divTrunc((right - x) - gap, 2);
        const tx_card: geom.Rect = .{ .x = x, .y = y, .w = col_w, .h = 116 };
        const rx_card: geom.Rect = .{ .x = x + col_w + gap, .y = y, .w = col_w, .h = 116 };
        drawValueRow(logical, theme, tx_card, "UART transmit pin", state.draft_tx, &lay.tx_minus, &lay.tx_plus);
        drawValueRow(logical, theme, rx_card, "UART receive pin", state.draft_rx, &lay.rx_minus, &lay.rx_plus);
        y += 132;
        const baud_card: geom.Rect = .{ .x = x, .y = y, .w = right - x, .h = 104 };
        widgets.fillRoundRect(logical, baud_card, tokens.Shape.lg, theme.surface_container_low);
        font.drawTextRole(logical, baud_card.x + tokens.Space.lg, baud_card.y + 13, "Baud rate", theme.on_surface_variant, .label_m);
        lay.baud = .{ .x = baud_card.x + tokens.Space.lg, .y = baud_card.y + 39, .w = baud_card.w - tokens.Space.lg * 2, .h = 54 };
        var baud_buf: [24]u8 = undefined;
        const baud_txt = std.fmt.bufPrint(&baud_buf, "{d}", .{state.draft_baud}) catch "115200";
        widgets.drawTonalButton(logical, lay.baud, baud_txt, theme);
        y += 120;
        font.drawTextRole(logical, x, y, state.statusText(), theme.on_surface_variant, .body_m);
        const action_y = card.y + card.h - 90;
        const action_w: i32 = 270;
        lay.refresh = .{ .x = x, .y = action_y, .w = action_w, .h = 64 };
        lay.test_cnc = .{ .x = x + @divTrunc((right - x) - action_w, 2), .y = action_y, .w = action_w, .h = 64 };
        lay.review = .{ .x = right - action_w, .y = action_y, .w = action_w, .h = 64 };
        if (!state.config_busy) widgets.drawTonalButton(logical, lay.refresh, "Refresh from S3", theme) else disabled(logical, lay.refresh, "Refreshing...", theme);
        if (state.test_supported and !state.config_busy)
            widgets.drawTonalButton(logical, lay.test_cnc, "Test CNC connection", theme)
        else if (state.config_busy)
            disabled(logical, lay.test_cnc, "Testing...", theme)
        else
            disabled(logical, lay.test_cnc, "Update S3 to test", theme);
        if (!state.config_busy) widgets.drawFilledButton(logical, lay.review, "Review & Apply", theme) else disabled(logical, lay.review, "Applying...", theme);
        if (state.view == .review) {
            const box: geom.Rect = .{ .x = card.x + 270, .y = card.y + 125, .w = 680, .h = 430 };
            widgets.fillRoundRect(logical, box, tokens.Shape.dialog, theme.elev(5));
            font.drawTextRole(logical, box.x + 32, box.y + 28, "Apply S3 UART settings?", theme.on_surface, .title_m);
            const labels = [_][]const u8{ "Transmit GPIO", "Receive GPIO", "Baud rate" };
            const old = [_]i64{ state.uart_tx, state.uart_rx, state.uart_baud };
            const new = [_]i64{ state.draft_tx, state.draft_rx, state.draft_baud };
            for (labels, 0..) |label, i| {
                const ry = box.y + 92 + @as(i32, @intCast(i)) * 58;
                font.drawTextRole(logical, box.x + 32, ry, label, theme.on_surface_variant, .body_m);
                var before: [24]u8 = undefined;
                var after: [24]u8 = undefined;
                const before_txt = std.fmt.bufPrint(&before, "{d}", .{old[i]}) catch "?";
                const after_txt = std.fmt.bufPrint(&after, "{d}", .{new[i]}) catch "?";
                font.drawTextRole(logical, box.x + 290, ry, before_txt, theme.on_surface_variant, .body_l);
                font.drawTextRole(logical, box.x + 405, ry, "->", theme.on_surface_variant, .body_l);
                font.drawTextRole(logical, box.x + 485, ry, after_txt, theme.primary, .body_l);
            }
            font.drawTextRole(logical, box.x + 32, box.y + 285, "UART pauses briefly; ESP-NOW remains connected.", theme.on_surface_variant, .body_m);
            lay.cancel = .{ .x = box.x + 32, .y = box.y + box.h - 88, .w = 220, .h = 60 };
            lay.apply = .{ .x = box.x + box.w - 252, .y = box.y + box.h - 88, .w = 220, .h = 60 };
            widgets.drawTonalButton(logical, lay.cancel, "Cancel", theme);
            widgets.drawFilledButton(logical, lay.apply, "Apply", theme);
        }
        return lay;
    }
    const link = if (state.s3_connected) "S3 connected via ESP-NOW" else "S3 bridge not connected";
    font.drawTextRole(logical, x, y, link, if (state.s3_connected) theme.primary else theme.on_error_container, .body_m);
    if (state.version_len != 0) {
        var version: [48]u8 = undefined;
        const version_text = std.fmt.bufPrint(&version, "Firmware: {s}", .{shortVersion(state.versionText())}) catch "Firmware version unavailable";
        drawFittedText(logical, x + 330, y, 390, version_text, theme.primary, .body_m);
    }
    lay.refresh = .{ .x = right - 190, .y = y - 10, .w = 190, .h = 60 };
    widgets.drawTonalButton(logical, lay.refresh, "Refresh USB", theme);
    y += 34;
    var installed: [64]u8 = undefined;
    var selected_version: [64]u8 = undefined;
    const installed_text = std.fmt.bufPrint(&installed, "Installed: {s}", .{if (state.version_len != 0) shortVersion(state.versionText()) else "unknown"}) catch "Installed: unknown";
    const selected_text = std.fmt.bufPrint(&selected_version, "Selected image: {s}", .{if (state.image_version_len != 0) shortVersion(state.imageVersionText()) else "none"}) catch "Selected image: none";
    drawFittedText(logical, x, y, 280, installed_text, theme.on_surface_variant, .body_m);
    drawFittedText(logical, x + 310, y, 350, selected_text, theme.on_surface_variant, .body_m);
    if (state.version_len != 0 and state.image_version_len != 0 and std.mem.eql(u8, state.versionText(), state.imageVersionText())) {
        font.drawTextRole(logical, x + 690, y, "Already installed", theme.primary, .label_m);
    }
    y += 42;

    const row_h: i32 = tokens.Logical.touch_min;
    const row_gap: i32 = tokens.Space.xs;
    lay.file_area = .{ .x = x, .y = y, .w = right - x, .h = 5 * row_h + 4 * row_gap };
    lay.row_n = @min(state.file_count, 5);
    var i: u8 = 0;
    while (i < lay.row_n) : (i += 1) {
        const r: geom.Rect = .{ .x = x, .y = y, .w = right - x, .h = row_h };
        lay.rows[i] = r;
        const selected = i == state.selected;
        widgets.fillRoundRect(logical, r, tokens.Shape.md, theme.surface_bright);
        widgets.strokeRoundRect(logical, r, tokens.Shape.md, if (selected) theme.primary else theme.outline_variant, if (selected) 2 else 1);
        drawFittedText(logical, r.x + tokens.Space.md, r.y + 13, r.w - tokens.Space.md * 2, displayFileName(state.fileText(i)), theme.on_surface, .body_m);
        y += row_h + row_gap;
    }
    if (lay.row_n == 0) font.drawTextRole(logical, x + tokens.Space.md, y + 14, "No verified ESP32-S3 app images found on USB.", theme.on_surface_variant, .body_m);

    const status_y = card.y + card.h - 150;
    lay.status_area = .{ .x = x, .y = status_y, .w = right - x, .h = 37 };
    drawFittedText(logical, x, status_y, right - x, state.statusText(), if (state.phase == .failed) theme.on_error_container else theme.on_surface_variant, .body_m);
    const bar: geom.Rect = .{ .x = x, .y = status_y + 27, .w = right - x, .h = 10 };
    widgets.fillRoundRect(logical, bar, 5, theme.surface_container_high);
    if (state.progress > 0) {
        const fill: geom.Rect = .{ .x = bar.x, .y = bar.y, .w = @divTrunc(bar.w * state.progress, 100), .h = bar.h };
        widgets.fillRoundRect(logical, fill, 5, theme.primary);
    }

    const action_h: i32 = 64;
    const action_w: i32 = 250;
    const by = card.y + card.h - tokens.Space.lg - action_h;
    lay.check = .{ .x = x, .y = by, .w = action_w, .h = action_h };
    lay.flash = .{ .x = x + action_w + tokens.Space.md, .y = by, .w = action_w, .h = action_h };
    lay.restart = .{ .x = right - action_w, .y = by, .w = action_w, .h = action_h };
    if (state.file_count > 0 and state.phase != .flashing) widgets.drawFilledButton(logical, lay.check, "1. Check S3 image", theme) else disabled(logical, lay.check, "1. Check S3 image", theme);
    if (state.phase == .armed) widgets.drawDangerButton(logical, lay.flash, "2. Flash S3", theme) else disabled(logical, lay.flash, "2. Flash S3", theme);
    if (state.phase == .success) widgets.drawFilledButton(logical, lay.restart, "3. Restart S3", theme) else disabled(logical, lay.restart, "3. Restart S3", theme);
    return lay;
}

pub fn hit(layout: Layout, x: i32, y: i32) HitInfo {
    if (tool_chrome.hitBack(layout.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(layout.header, x, y)) return .{ .kind = .exit };
    if (tool_chrome.hitScrim(layout.header, x, y)) return .{ .kind = .scrim };
    if (layout.detail_back.contains(x, y)) return .{ .kind = .detail_back };
    if (layout.refresh.contains(x, y)) return .{ .kind = .refresh };
    if (layout.firmware.contains(x, y)) return .{ .kind = .firmware };
    if (layout.settings.contains(x, y)) return .{ .kind = .settings };
    if (layout.tx_minus.contains(x, y)) return .{ .kind = .tx_minus };
    if (layout.tx_plus.contains(x, y)) return .{ .kind = .tx_plus };
    if (layout.rx_minus.contains(x, y)) return .{ .kind = .rx_minus };
    if (layout.rx_plus.contains(x, y)) return .{ .kind = .rx_plus };
    if (layout.baud.contains(x, y)) return .{ .kind = .baud };
    if (layout.test_cnc.contains(x, y)) return .{ .kind = .test_cnc };
    if (layout.review.contains(x, y)) return .{ .kind = .review };
    if (layout.cancel.contains(x, y)) return .{ .kind = .cancel };
    if (layout.apply.contains(x, y)) return .{ .kind = .apply };
    var i: u8 = 0;
    while (i < layout.row_n) : (i += 1) if (layout.rows[i].contains(x, y)) return .{ .kind = .row, .index = i };
    if (layout.check.contains(x, y)) return .{ .kind = .check };
    if (layout.flash.contains(x, y)) return .{ .kind = .flash };
    if (layout.restart.contains(x, y)) return .{ .kind = .restart };
    return .{};
}

test "S3 OTA controls meet minimum touch size" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{ .view = .firmware };
    state.file_count = 1;
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.check.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.flash.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.restart.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.file_area.y + lay.file_area.h <= lay.status_area.y);
}

test "S3 firmware view matches the C6 five-row list layout" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{ .view = .firmware, .file_count = max_files };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expectEqual(@as(u8, 5), lay.row_n);
    try std.testing.expectEqual(lay.rows[0].x, lay.rows[4].x);
    try std.testing.expectEqual(lay.rows[0].w, lay.rows[4].w);
    try std.testing.expect(lay.rows[4].y > lay.rows[0].y);
    try std.testing.expect(lay.rows[4].y + lay.rows[4].h <= lay.status_area.y);
}

test "S3 versions are shortened before rendering" {
    try std.testing.expectEqualStrings("v3.1.2", shortVersion("v3.1.2-ota-2-g41f23eb-dirty"));
    try std.testing.expectEqualStrings("v3.1.0", shortVersion("v3.1.0-10-g8166aac-dirty"));
}

test "S3 dashboard has balanced firmware and settings cards" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const state: State = .{ .view = .dashboard, .s3_connected = true, .config_loaded = true, .uart_tx = 8, .uart_rx = 7 };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expectEqual(lay.firmware.w, lay.settings.w);
    try std.testing.expectEqual(lay.firmware.h, lay.settings.h);
    try std.testing.expect(lay.firmware.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.settings.h >= tokens.Logical.touch_min);
    try std.testing.expectEqual(Hit.firmware, hit(lay, lay.firmware.x + 4, lay.firmware.y + 4).kind);
    try std.testing.expectEqual(Hit.settings, hit(lay, lay.settings.x + 4, lay.settings.y + 4).kind);
}

test "S3 settings and confirmation controls meet minimum touch size" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{ .view = .settings, .s3_connected = true, .config_supported = true, .config_loaded = true, .draft_tx = 3, .draft_rx = 4 };
    var lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.tx_minus.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.tx_plus.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.rx_minus.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.rx_plus.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.baud.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.test_cnc.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.review.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.refresh.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.detail_back.h >= tokens.Logical.touch_min);
    state.view = .review;
    lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.cancel.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.apply.h >= tokens.Logical.touch_min);
}
