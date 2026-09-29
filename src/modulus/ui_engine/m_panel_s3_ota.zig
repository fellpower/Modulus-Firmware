//! M-Panel S3 Update — guarded ESP-NOW OTA from USB.

const std = @import("std");
const color = @import("color.zig");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const tool_chrome = @import("m_panel_tool.zig");
const xiao_pins = @import("xiao_pins.zig");

pub const max_files = 8;
pub const name_len = 96;
pub const Phase = enum(u8) { idle, ready, armed, flashing, success, failed };
pub const Action = enum(u8) { refresh, select, check, flash, restart, config_refresh, config_apply, config_test };
pub const View = enum(u8) { firmware, settings, review };
pub const PinSelectTarget = enum(u8) { none, tx, rx };

pub const board_profile_xiao: u8 = 7;
const gpio_max: u8 = 48;
const pin_grid_columns: i32 = 7;
const pin_grid_cell_w: i32 = 112;
const pin_grid_cell_h: i32 = 56;
const pin_grid_gap: i32 = 8;

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
    /// Render-time mirror of the central WirelessPrefs ESP-NOW enable state.
    espnow_enabled: bool = true,
    view: View = .firmware,
    config_supported: bool = false,
    test_supported: bool = false,
    config_busy: bool = false,
    config_loaded: bool = false,
    uart_pin_options_available: bool = false,
    board_profile_id: u8 = 0,
    uart_tx_gpio_mask: u64 = 0,
    uart_rx_gpio_mask: u64 = 0,
    pin_select_target: PinSelectTarget = .none,
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

pub fn shouldInitializeDraft(
    config_supported: bool,
    config_busy: bool,
    config_loaded: bool,
    previous_profile_id: u8,
    reply_profile_id: u8,
) bool {
    const profile_became_known = previous_profile_id == 0 and reply_profile_id != 0;
    return config_supported and !config_busy and (!config_loaded or profile_became_known);
}

pub const Hit = enum { none, scrim, back, exit, detail_back, refresh, enable_espnow, row, check, flash, restart, tx_pin, rx_pin, pin_option, pin_select_close, pin_select_outside, baud, test_cnc, review, cancel, apply };
pub const HitInfo = struct { kind: Hit = .none, index: u8 = 0 };
pub const Layout = struct {
    header: tool_chrome.Header = .{},
    refresh: geom.Rect = .{},
    enable_espnow: geom.Rect = .{},
    rows: [max_files]geom.Rect = [_]geom.Rect{.{}} ** max_files,
    row_n: u8 = 0,
    check: geom.Rect = .{},
    flash: geom.Rect = .{},
    restart: geom.Rect = .{},
    detail_back: geom.Rect = .{},
    tx_pin: geom.Rect = .{},
    rx_pin: geom.Rect = .{},
    pin_selector_active: bool = false,
    pin_selector_close: geom.Rect = .{},
    pin_options: [49]geom.Rect = [_]geom.Rect{.{}} ** 49,
    baud: geom.Rect = .{},
    test_cnc: geom.Rect = .{},
    review: geom.Rect = .{},
    cancel: geom.Rect = .{},
    apply: geom.Rect = .{},
    file_area: geom.Rect = .{},
    status_area: geom.Rect = .{},
};

fn gpioToXiaoDigitalPin(gpio: u8) ?u8 {
    if (xiao_pins.gpioToDigitalPin(@intCast(gpio))) |pin| return @intCast(pin);
    return null;
}

fn pinAllowed(state: *const State, target: PinSelectTarget, gpio: u8) bool {
    if (gpio > gpio_max) return false;
    const mask = if (target == .tx) state.uart_tx_gpio_mask else if (target == .rx) state.uart_rx_gpio_mask else 0;
    return (mask & (@as(u64, 1) << @intCast(gpio))) != 0;
}

fn pinValueLabel(buf: []u8, state: *const State, value: i32) []const u8 {
    if (value < 0 or value > gpio_max) return "GPIO ?";
    const gpio: u8 = @intCast(value);
    if (state.board_profile_id == board_profile_xiao) {
        if (gpioToXiaoDigitalPin(gpio)) |digital_pin| return std.fmt.bufPrint(buf, "D{d}", .{digital_pin}) catch "D?";
    }
    return std.fmt.bufPrint(buf, "GPIO{d}", .{gpio}) catch "GPIO?";
}

fn settingsPinLabel(buf: *[16]u8, state: *const State, target: PinSelectTarget) []const u8 {
    const value = if (target == .tx) state.draft_tx else state.draft_rx;
    return pinValueLabel(buf, state, value);
}

fn drawValueRow(logical: *fb.LogicalFb, theme: tokens.Theme, area: geom.Rect, label: []const u8, state: *const State, target: PinSelectTarget, hit_rect: *geom.Rect) void {
    widgets.fillRoundRect(logical, area, tokens.Shape.lg, theme.surface_container_low);
    font.drawTextRole(logical, area.x + tokens.Space.lg, area.y + 12, label, theme.on_surface_variant, .label_m);
    hit_rect.* = .{ .x = area.x + tokens.Space.lg, .y = area.y + 43, .w = area.w - tokens.Space.lg * 2, .h = 58 };
    var buf: [16]u8 = undefined;
    widgets.drawTonalButton(logical, hit_rect.*, settingsPinLabel(&buf, state, target), theme);
}

fn paintPinSelector(logical: *fb.LogicalFb, theme: tokens.Theme, state: *const State, lay: *Layout) void {
    if (state.pin_select_target == .none) return;
    lay.pin_selector_active = true;
    widgets.paintScrimOver(logical, .{ .x = 0, .y = 0, .w = tokens.Logical.width, .h = tokens.Logical.height }, theme);
    const box: geom.Rect = .{ .x = 180, .y = 72, .w = 920, .h = 576 };
    widgets.fillRoundRect(logical, box, tokens.Shape.dialog, theme.elev(5));
    const target_name = if (state.pin_select_target == .tx) "UART transmit pin" else "UART receive pin";
    font.drawTextRole(logical, box.x + 32, box.y + 22, target_name, theme.on_surface, .title_m);
    font.drawTextRole(logical, box.x + 32, box.y + 66, "Select an allowed pin", theme.on_surface_variant, .body_m);
    lay.pin_selector_close = .{ .x = box.x + box.w - 132, .y = box.y + 16, .w = 100, .h = 56 };
    widgets.drawTonalButton(logical, lay.pin_selector_close, "Cancel", theme);

    const start_x = box.x + 32;
    const start_y = box.y + 112;
    var gpio: u8 = 0;
    while (gpio <= gpio_max) : (gpio += 1) {
        if (!pinAllowed(state, state.pin_select_target, gpio)) continue;
        if (state.board_profile_id == board_profile_xiao and gpioToXiaoDigitalPin(gpio) == null) continue;
        const choice_index: i32 = @intCast(@popCount((if (state.pin_select_target == .tx) state.uart_tx_gpio_mask else state.uart_rx_gpio_mask) & ((@as(u64, 1) << @intCast(gpio)) - 1)));
        // XIAO options are displayed in D0..D10 order, matching the board header.
        const index: i32 = if (state.board_profile_id == board_profile_xiao)
            @intCast(gpioToXiaoDigitalPin(gpio).?)
        else
            choice_index;
        const col = @mod(index, pin_grid_columns);
        const row = @divTrunc(index, pin_grid_columns);
        const rect: geom.Rect = .{
            .x = start_x + col * (pin_grid_cell_w + pin_grid_gap),
            .y = start_y + row * (pin_grid_cell_h + pin_grid_gap),
            .w = pin_grid_cell_w,
            .h = pin_grid_cell_h,
        };
        lay.pin_options[gpio] = rect;
        var label_buf: [16]u8 = undefined;
        widgets.drawTonalButton(logical, rect, pinValueLabel(&label_buf, state, gpio), theme);
    }
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
    tool_chrome.paintBackTo(logical, theme, lay.header.back, "Devices");
    tool_chrome.paintTitle(logical, theme, lay.header.back.x + lay.header.back.w + tokens.Space.sm, lay.header.back.y, "S3");
    tool_chrome.paintExit(logical, theme, lay.header.exit);

    const x = card.x + tokens.Space.lg;
    const right = card.x + card.w - tokens.Space.lg;

    var y = paintDetailHeading(logical, theme, &lay, card, if (state.view == .firmware) "Firmware Update" else "UART Settings");

    if (!state.espnow_enabled) {
        font.drawTextRole(logical, x, y + 26, "ESP-NOW is disabled.", theme.on_surface, .title_m);
        font.drawTextRole(logical, x, y + 88, "Enable ESP-NOW to configure or update the S3.", theme.on_surface_variant, .body_l);
        lay.enable_espnow = .{ .x = x, .y = y + 168, .w = 300, .h = 64 };
        widgets.drawFilledButton(logical, lay.enable_espnow, "Enable ESP-NOW", theme);
        return lay;
    }

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
        drawValueRow(logical, theme, tx_card, "UART transmit pin", state, .tx, &lay.tx_pin);
        drawValueRow(logical, theme, rx_card, "UART receive pin", state, .rx, &lay.rx_pin);
        y += 132;
        if (!state.uart_pin_options_available) {
            font.drawTextRole(logical, x, y, "Update S3 firmware to enable safe UART pin selection.", theme.on_error_container, .body_m);
            y += 34;
        }
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
                const before_txt = if (i < 2)
                    pinValueLabel(&before, state, @intCast(old[i]))
                else
                    std.fmt.bufPrint(&before, "{d}", .{old[i]}) catch "?";
                const after_txt = if (i < 2)
                    pinValueLabel(&after, state, @intCast(new[i]))
                else
                    std.fmt.bufPrint(&after, "{d}", .{new[i]}) catch "?";
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
        paintPinSelector(logical, theme, state, &lay);
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
    if (layout.pin_selector_active) {
        if (layout.pin_selector_close.contains(x, y)) return .{ .kind = .pin_select_close };
        var gpio: u8 = 0;
        while (gpio <= gpio_max) : (gpio += 1) {
            if (layout.pin_options[gpio].contains(x, y)) return .{ .kind = .pin_option, .index = gpio };
        }
        return .{ .kind = .pin_select_outside };
    }
    if (tool_chrome.hitBack(layout.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(layout.header, x, y)) return .{ .kind = .exit };
    if (tool_chrome.hitScrim(layout.header, x, y)) return .{ .kind = .scrim };
    if (layout.detail_back.contains(x, y)) return .{ .kind = .detail_back };
    if (layout.enable_espnow.contains(x, y)) return .{ .kind = .enable_espnow };
    if (layout.refresh.contains(x, y)) return .{ .kind = .refresh };
    if (layout.tx_pin.contains(x, y)) return .{ .kind = .tx_pin };
    if (layout.rx_pin.contains(x, y)) return .{ .kind = .rx_pin };
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

test "S3 settings and confirmation controls meet minimum touch size" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{ .view = .settings, .s3_connected = true, .config_supported = true, .config_loaded = true, .draft_tx = 3, .draft_rx = 4 };
    var lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.tx_pin.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.rx_pin.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.baud.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.test_cnc.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.review.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.refresh.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.detail_back.h >= tokens.Logical.touch_min);
    try std.testing.expectEqual(Hit.tx_pin, hit(lay, lay.tx_pin.x + 2, lay.tx_pin.y + 2).kind);
    try std.testing.expectEqual(Hit.rx_pin, hit(lay, lay.rx_pin.x + 2, lay.rx_pin.y + 2).kind);
    state.view = .review;
    lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.cancel.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.apply.h >= tokens.Logical.touch_min);
}

test "XIAO labels reuse the D0-D10 GPIO map" {
    const expected = [_]u8{ 1, 2, 3, 4, 5, 6, 43, 44, 7, 8, 9 };
    for (expected, 0..) |gpio, pin| {
        try std.testing.expectEqual(@as(?u32, @intCast(pin)), xiao_pins.gpioToDigitalPin(@intCast(gpio)));
    }
    try std.testing.expectEqual(@as(?u8, 8), gpioToXiaoDigitalPin(7));
    try std.testing.expectEqual(@as(?u8, 9), gpioToXiaoDigitalPin(8));
}

test "settings show current XIAO TX/RX pins using D labels" {
    var label_buf: [16]u8 = undefined;
    const state: State = .{
        .board_profile_id = board_profile_xiao,
        .draft_tx = 7,
        .draft_rx = 8,
    };
    try std.testing.expectEqualStrings("D8", settingsPinLabel(&label_buf, &state, .tx));
    try std.testing.expectEqualStrings("D9", settingsPinLabel(&label_buf, &state, .rx));
}

test "settings show current Generic TX/RX pins using GPIO labels" {
    var label_buf: [16]u8 = undefined;
    const state: State = .{
        .board_profile_id = 3,
        .draft_tx = 7,
        .draft_rx = 8,
    };
    try std.testing.expectEqualStrings("GPIO7", settingsPinLabel(&label_buf, &state, .tx));
    try std.testing.expectEqualStrings("GPIO8", settingsPinLabel(&label_buf, &state, .rx));
}

fn expectRenderedButtonLabel(logical: *const fb.LogicalFb, rect: geom.Rect, label: []const u8, theme: tokens.Theme) !void {
    const gpa = std.testing.allocator;
    var expected = try fb.LogicalFb.alloc(gpa);
    defer expected.deinit(gpa);
    widgets.drawTonalButton(&expected, rect, label, theme);
    var y = rect.y + 14;
    while (y < rect.y + rect.h - 14) : (y += 1) {
        var x = rect.x + 14;
        while (x < rect.x + rect.w - 14) : (x += 1) {
            try std.testing.expectEqual(expected.get(x, y).toU16(), logical.get(x, y).toU16());
        }
    }
}

test "real settings render path displays XIAO D pins and Generic GPIO values" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const theme = tokens.Theme.industrialTealDark();
    var state: State = .{
        .view = .settings,
        .config_supported = true,
        .s3_connected = true,
        .board_profile_id = board_profile_xiao,
        .draft_tx = 7,
        .draft_rx = 8,
    };
    var layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.tx_pin, "D8", theme);
    try expectRenderedButtonLabel(&logical, layout.rx_pin, "D9", theme);

    state.board_profile_id = 3;
    layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.tx_pin, "GPIO7", theme);
    try expectRenderedButtonLabel(&logical, layout.rx_pin, "GPIO8", theme);

    state.uart_tx_gpio_mask = (@as(u64, 1) << 7) | (@as(u64, 1) << 8) | (@as(u64, 1) << 43);
    state.uart_rx_gpio_mask = (@as(u64, 1) << 7) | (@as(u64, 1) << 8) | (@as(u64, 1) << 44);
    state.pin_select_target = .tx;
    state.board_profile_id = board_profile_xiao;
    layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.pin_options[7], "D8", theme);
    try expectRenderedButtonLabel(&logical, layout.pin_options[8], "D9", theme);
    try std.testing.expect(layout.pin_options[43].w > 0); // D6 = GPIO43.

    state.board_profile_id = 3;
    layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.pin_options[7], "GPIO7", theme);
    try expectRenderedButtonLabel(&logical, layout.pin_options[8], "GPIO8", theme);
}

fn expectRenderedReviewValue(logical: *const fb.LogicalFb, x: i32, y: i32, width: i32, label: []const u8, ink: color.Rgb565, theme: tokens.Theme) !void {
    const gpa = std.testing.allocator;
    var expected = try fb.LogicalFb.alloc(gpa);
    defer expected.deinit(gpa);
    const region: geom.Rect = .{ .x = x, .y = y, .w = width, .h = 42 };
    expected.fillRect(region, theme.elev(5));
    font.drawTextRole(&expected, x, y, label, ink, .body_l);
    var py = region.y;
    while (py < region.y + region.h) : (py += 1) {
        var px = region.x;
        while (px < region.x + region.w) : (px += 1) {
            try std.testing.expectEqual(expected.get(px, py).toU16(), logical.get(px, py).toU16());
        }
    }
}

test "real Review and Apply render path uses profile-aware labels" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const theme = tokens.Theme.industrialTealDark();
    var state: State = .{
        .view = .review,
        .config_supported = true,
        .board_profile_id = board_profile_xiao,
        .uart_tx = 7,
        .uart_rx = 8,
        .draft_tx = 7,
        .draft_rx = 8,
    };
    _ = paint(&logical, theme, &state, 1);
    const card = cardGeom(1);
    const box_x = card.x + 270;
    const box_y = card.y + 125;
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 92, 100, "D8", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 92, 150, "D8", theme.primary, theme);
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 150, 100, "D9", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 150, 150, "D9", theme.primary, theme);

    state.board_profile_id = 3;
    _ = paint(&logical, theme, &state, 1);
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 92, 100, "GPIO7", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 92, 150, "GPIO7", theme.primary, theme);
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 150, 100, "GPIO8", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 150, 150, "GPIO8", theme.primary, theme);
}

test "config drafts initialize after refresh or when a previously unknown board profile arrives" {
    try std.testing.expect(!shouldInitializeDraft(true, true, false, 0, board_profile_xiao));
    try std.testing.expect(!shouldInitializeDraft(true, false, true, board_profile_xiao, board_profile_xiao));
    try std.testing.expect(shouldInitializeDraft(true, false, false, 0, board_profile_xiao));
    try std.testing.expect(shouldInitializeDraft(true, false, true, 0, board_profile_xiao));
    try std.testing.expect(!shouldInitializeDraft(true, false, true, 3, board_profile_xiao));
    try std.testing.expect(!shouldInitializeDraft(false, false, false, 0, board_profile_xiao));
}

test "late XIAO profile reply repaints initial Settings and Review labels without a pin selection" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const theme = tokens.Theme.industrialTealDark();
    var state: State = .{
        .view = .settings,
        .config_supported = true,
        .config_loaded = false,
        .board_profile_id = 0,
        .uart_tx = 7,
        .uart_rx = 8,
        .draft_tx = 7,
        .draft_rx = 8,
    };

    var layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.tx_pin, "GPIO7", theme);
    try expectRenderedButtonLabel(&logical, layout.rx_pin, "GPIO8", theme);

    try std.testing.expect(shouldInitializeDraft(
        state.config_supported,
        state.config_busy,
        state.config_loaded,
        state.board_profile_id,
        board_profile_xiao,
    ));
    state.board_profile_id = board_profile_xiao;
    state.draft_tx = state.uart_tx;
    state.draft_rx = state.uart_rx;
    layout = paint(&logical, theme, &state, 1);
    try expectRenderedButtonLabel(&logical, layout.tx_pin, "D8", theme);
    try expectRenderedButtonLabel(&logical, layout.rx_pin, "D9", theme);

    state.view = .review;
    _ = paint(&logical, theme, &state, 1);
    const card = cardGeom(1);
    const box_x = card.x + 270;
    const box_y = card.y + 125;
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 92, 100, "D8", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 92, 150, "D8", theme.primary, theme);
    try expectRenderedReviewValue(&logical, box_x + 290, box_y + 150, 100, "D9", theme.on_surface_variant, theme);
    try expectRenderedReviewValue(&logical, box_x + 485, box_y + 150, 150, "D9", theme.primary, theme);
}

test "pin selector exposes only S3 masks and uses board-specific labels" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{
        .view = .settings,
        .config_supported = true,
        .uart_pin_options_available = true,
        .board_profile_id = board_profile_xiao,
        .uart_tx_gpio_mask = (@as(u64, 1) << 1) | (@as(u64, 1) << 7) | (@as(u64, 1) << 8) | (@as(u64, 1) << 43),
        .pin_select_target = .tx,
    };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.pin_selector_active);
    try std.testing.expectEqual(@as(i32, 0), lay.pin_options[0].w);
    try std.testing.expect(lay.pin_options[1].w > 0);
    try std.testing.expect(lay.pin_options[7].w > 0);
    try std.testing.expect(lay.pin_options[8].w > 0);
    try std.testing.expect(lay.pin_options[43].w > 0); // D6 = GPIO43.
    try std.testing.expect(lay.pin_options[22].w == 0);
    var label_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("D8", pinValueLabel(&label_buf, &state, 7));
    try std.testing.expectEqualStrings("D9", pinValueLabel(&label_buf, &state, 8));
    try std.testing.expectEqual(Hit.pin_option, hit(lay, lay.pin_options[7].x + 3, lay.pin_options[7].y + 3).kind);

    state.board_profile_id = 11;
    state.uart_tx_gpio_mask = (@as(u64, 1) << 7) | (@as(u64, 1) << 43);
    const generic = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(generic.pin_options[7].w > 0);
    try std.testing.expect(generic.pin_options[43].w > 0);
    try std.testing.expectEqualStrings("GPIO7", pinValueLabel(&label_buf, &state, 7));
}

test "real XIAO mask exposes D1-D10 except the HALT pin D0" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const xiao_mask: u64 = 0x00019fc00007fffc;
    var state: State = .{
        .view = .settings,
        .config_supported = true,
        .uart_pin_options_available = true,
        .board_profile_id = board_profile_xiao,
        .uart_tx_gpio_mask = xiao_mask,
        .uart_rx_gpio_mask = xiao_mask,
        .pin_select_target = .tx,
    };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(lay.pin_options[1].w == 0); // D0 = GPIO1 is reserved for HALT.
    for ([_]u8{ 2, 3, 4, 5, 6, 43, 44, 7, 8, 9 }) |gpio| {
        try std.testing.expect(lay.pin_options[gpio].w > 0);
    }
    var label_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("D8", pinValueLabel(&label_buf, &state, 7));
    try std.testing.expectEqualStrings("D9", pinValueLabel(&label_buf, &state, 8));
}

test "legacy S3 config has no selectable pin fallback" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    const state: State = .{ .view = .settings, .config_supported = true, .draft_tx = 43, .draft_rx = 44 };
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(!lay.pin_selector_active);
    try std.testing.expect(lay.tx_pin.w > 0);
}

test "S3 management page exposes only explicit ESP-NOW enable while radio is off" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var state: State = .{
        .espnow_enabled = false,
        .view = .settings,
        .config_supported = true,
        .test_supported = true,
        .file_count = 1,
        .phase = .armed,
    };
    const settings = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(settings.enable_espnow.w > 0);
    try std.testing.expect(settings.refresh.w == 0);
    try std.testing.expect(settings.test_cnc.w == 0);
    try std.testing.expect(settings.tx_pin.w == 0);
    try std.testing.expectEqual(Hit.enable_espnow, hit(settings, settings.enable_espnow.x + 3, settings.enable_espnow.y + 3).kind);

    state.view = .firmware;
    const firmware = paint(&logical, tokens.Theme.industrialTealDark(), &state, 1);
    try std.testing.expect(firmware.enable_espnow.w > 0);
    try std.testing.expect(firmware.refresh.w == 0);
    try std.testing.expect(firmware.check.w == 0);
    try std.testing.expect(firmware.flash.w == 0);
}
