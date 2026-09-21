//! M-Panel Zigbee — full zigbee2mqtt-style device cards + permit join.

const std = @import("std");
const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const icons_phosphor = @import("icons_phosphor.zig");
const color = @import("color.zig");
const settings_prefs = @import("settings_prefs.zig");
const zb_purpose = @import("zb_purpose.zig");
const zb_exposes = @import("zb_exposes.zig");
const tool_chrome = @import("m_panel_tool.zig");
const expr = @import("widgets_expressive.zig");

pub const max_devices: usize = 8;
const card_w: i32 = 1180;
const card_h: i32 = 600;
const grid_gap: i32 = tokens.Space.md;
const min_tile_w: i32 = 520;
const max_grid_cols: i32 = 2;
const btn_size = tokens.ButtonSize.m;
const row_h: i32 = zb_exposes.row_h;

pub const Ctx = struct {
    wireless: *const settings_prefs.WirelessPrefs,
    scroll_px: i32 = 0,
    /// Frame phase 0..1 for indeterminate affordances (permit join bar).
    anim_t: f32 = 0,
    /// Open dropdown: dev index + field; dev=0xff closed.
    menu_dev: u8 = 0xff,
    menu_field: zb_exposes.Field = .none,
};

pub const HitSlot = struct {
    field: zb_exposes.Field = .none,
    rect: geom.Rect = .{},
    aux: u16 = 0,
};

pub const CardLayout = struct {
    outer: geom.Rect = .{},
    slots: [28]HitSlot = [_]HitSlot{.{}} ** 28,
    slot_n: u8 = 0,
    exposes_link: geom.Rect = .{},
    identify: geom.Rect = .{},
    remove: geom.Rect = .{},
    configure: geom.Rect = .{},
    rename: geom.Rect = .{},
};

pub const Hit = struct {
    kind: Kind = .none,
    dev: u8 = 0,
    field: zb_exposes.Field = .none,
    aux: u16 = 0,
};

pub const Kind = enum {
    none,
    scrim,
    back,
    exit,
    radio_toggle,
    permit_join,
    refresh,
    join_hub,
    add_device,
    toggle,
    slider,
    child_lock,
    dropdown,
    color_xy,
    cover,
    identify,
    remove,
    configure,
    rename,
    node_name,
    node_channel_name,
    node_type,
    node_gpio,
    node_polarity,
    node_pullup,
    node_poll,
    node_favorite,
    node_start,
    node_alarm_enabled,
    node_alarm_high,
    node_alarm_low,
    node_alarm_hysteresis,
    node_alarm_action,
    node_alarm_output,
    node_led_gpio,
    node_led_polarity,
    node_apply,
    node_close,
    node_prev,
    node_next,
    exposes,
};

pub const Layout = struct {
    header: tool_chrome.Header = .{},
    permit: geom.Rect = .{},
    refresh: geom.Rect = .{},
    join: geom.Rect = .{},
    add: geom.Rect = .{},
    radio: geom.Rect = .{},
    view: geom.Rect = .{},
    cards: [max_devices]CardLayout = [_]CardLayout{.{}} ** max_devices,
    card_n: u8 = 0,
    scroll_max: i32 = 0,
    grid_cols: u8 = 2,
    menu_anchor: geom.Rect = .{},
    node_name: geom.Rect = .{},
    node_led_gpio: geom.Rect = .{},
    node_led_polarity: geom.Rect = .{},
    node_type: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_channel_name: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_gpio: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_poll: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_favorite: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_start: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_enabled: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_high: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_low: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_hysteresis: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_action: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_alarm_output: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_pullup: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_polarity: [4]geom.Rect = [_]geom.Rect{.{}} ** 4,
    node_apply: geom.Rect = .{},
    node_close: geom.Rect = .{},
    node_prev: geom.Rect = .{},
    node_next: geom.Rect = .{},
    node_page_start: u8 = 0,
};

fn xiaoDigitalPin(gpio: i8) ?u8 {
    const pins = [_]u8{ 0, 1, 2, 21, 22, 23, 16, 17, 19, 20, 18 };
    for (pins, 0..) |candidate, pin| if (gpio == candidate) return @intCast(pin);
    return null;
}

fn gridCols(view_w: i32, device_count: u8) i32 {
    const cols = @divTrunc(view_w + grid_gap, min_tile_w + grid_gap);
    return @max(1, @min(@as(i32, @intCast(device_count)), @min(max_grid_cols, cols)));
}

fn gridRows(card_n: u8, cols: i32) i32 {
    return @divTrunc(@as(i32, @intCast(card_n)) + cols - 1, cols);
}

fn accumulateRowHeights(w: *const settings_prefs.WirelessPrefs, card_n: u8, cols: i32, row_heights: *[4]i32) void {
    @memset(row_heights, 0);
    var i: u8 = 0;
    while (i < card_n) : (i += 1) {
        const rh = zb_exposes.cardBodyHeight(w.zbSnap(i));
        const gr: usize = @intCast(@divTrunc(@as(i32, @intCast(i)), cols));
        if (gr < 4 and rh > row_heights[gr]) row_heights[gr] = rh;
    }
}

fn cardGeom(enter_t: f32) geom.Rect {
    const t = std.math.clamp(enter_t, 0, 1);
    const w: i32 = @intFromFloat(@as(f32, @floatFromInt(card_w)) * (0.92 + 0.08 * t));
    const h: i32 = @intFromFloat(@as(f32, @floatFromInt(card_h)) * (0.92 + 0.08 * t));
    return .{
        .x = @divTrunc(tokens.Logical.width - w, 2),
        .y = @divTrunc(tokens.Logical.height - h, 2),
        .w = w,
        .h = h,
    };
}

fn btnWidth(label: []const u8) i32 {
    const tw = font.textWidthStr(label, .label_l);
    return @max(tokens.Logical.touch_min, tw + btn_size.padX() * 2);
}

fn dsBusOrdinal(w: *const settings_prefs.WirelessPrefs, channel_idx: usize) u8 {
    if (channel_idx >= w.zb_node_channels.len) return 0;
    const selected = w.zb_node_channels[channel_idx];
    if (selected.typ != 4 or selected.gpio < 0) return 0;
    var ordinal: u8 = 1;
    for (w.zb_node_channels[0..channel_idx]) |prior| {
        if (prior.typ == 4 and prior.gpio == selected.gpio) ordinal += 1;
    }
    return ordinal;
}

pub fn devCount(w: *const settings_prefs.WirelessPrefs) u8 {
    return @intCast(@min(if (w.live_zb_n > 0) w.live_zb_n else w.zb_dev_n, max_devices));
}

fn pushSlot(lay: *CardLayout, field: zb_exposes.Field, r: geom.Rect, aux: u16) void {
    if (lay.slot_n >= lay.slots.len) return;
    lay.slots[lay.slot_n] = .{ .field = field, .rect = r, .aux = aux };
    lay.slot_n += 1;
}

fn sliderPct(row: geom.Rect, x: i32) u8 {
    const inset = tokens.Space.sm;
    const tx = row.x + inset;
    const tw: i32 = @max(1, row.w - inset * 2);
    const t: i32 = std.math.clamp(x - tx, 0, tw);
    return @intCast(@min(100, @divTrunc(t * 100, tw)));
}

fn paintToggleRow(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, label: []const u8, on: bool) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.sm, theme.surface_container_high);
    widgets.strokeRoundRect(logical, r, tokens.Shape.sm, theme.outline_variant, 1);
    const lh = font.faceHeight(font.faceForRole(.label_m));
    font.drawTextRole(logical, r.x + tokens.Space.md, r.y + @divTrunc(r.h - lh, 2), label, theme.primary, .label_m);
    widgets.drawSwitchBool(logical, r.x + r.w - 60, r.y + @divTrunc(r.h - 28, 2), on, theme);
}

fn paintDropdownRow(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, label: []const u8, value: []const u8) void {
    widgets.fillRoundRect(logical, r, tokens.Shape.sm, theme.surface_container_high);
    widgets.strokeRoundRect(logical, r, tokens.Shape.sm, theme.outline_variant, 1);
    const lh = font.faceHeight(font.faceForRole(.label_m));
    const label_y = r.y + @divTrunc(r.h - lh, 2);
    font.drawTextRole(logical, r.x + tokens.Space.md, label_y, label, theme.primary, .label_m);
    const val_x = r.x + @divTrunc(r.w, 3);
    const box_h = r.h - tokens.Space.md;
    const box_y = r.y + @divTrunc(r.h - box_h, 2);
    widgets.fillRoundRect(logical, .{ .x = val_x, .y = box_y, .w = r.w - val_x + r.x - tokens.Space.sm, .h = box_h }, tokens.Shape.sm, theme.surface_container_highest);
    widgets.strokeRoundRect(logical, .{ .x = val_x, .y = box_y, .w = r.w - val_x + r.x - tokens.Space.sm, .h = box_h }, tokens.Shape.sm, theme.outline_variant, 1);
    const vh = font.faceHeight(font.faceForRole(.body_m));
    font.drawTextRole(logical, val_x + tokens.Space.sm, box_y + @divTrunc(box_h - vh, 2), value, theme.on_surface, .body_m);
    widgets.drawChevronDown(logical, r.x + r.w - tokens.Space.lg, r.y + @divTrunc(r.h, 2), 5, theme.on_surface_variant);
}

fn paintReadonly(logical: *fb.LogicalFb, theme: tokens.Theme, r: geom.Rect, label: []const u8, value: []const u8, value_c: color.Rgb565) void {
    const lh = font.faceHeight(font.faceForRole(.label_m));
    const ty = r.y + @divTrunc(r.h - lh, 2);
    font.drawTextRole(logical, r.x, ty, label, theme.on_surface_variant, .label_m);
    const lw = font.textWidthStr(label, .label_m);
    font.drawTextRole(logical, r.x + lw + tokens.Space.sm, ty, value, value_c, .body_m);
}

fn paintDevCard(
    logical: *fb.LogicalFb,
    theme: tokens.Theme,
    w: *const settings_prefs.WirelessPrefs,
    idx: u8,
    outer: geom.Rect,
    lay: *CardLayout,
) void {
    lay.* = .{ .outer = outer };
    const name = w.zbDevLabel(idx);
    const snap = w.zbSnap(idx);
    const ex = zb_exposes.active(snap);
    const purpose = zb_purpose.classifySnap(name, snap);
    const icon = zb_purpose.icon(purpose);
    const pad = tokens.Space.md;
    widgets.fillRoundRect(logical, outer, tokens.Shape.md, theme.surface_container);
    widgets.strokeRoundRect(logical, outer, tokens.Shape.md, theme.outline_variant, 1);

    icons_phosphor.draw(logical, outer.x + pad, outer.y + pad, icon, theme.primary);
    const th = font.faceHeight(font.faceForRole(.title_m));
    lay.rename = .{ .x = outer.x + pad + icons_phosphor.size + tokens.Space.sm, .y = outer.y + pad, .w = outer.w - pad * 2 - icons_phosphor.size - tokens.Space.sm, .h = icons_phosphor.size };
    font.drawTextRole(logical, lay.rename.x, outer.y + pad + @divTrunc(th, 4), name, theme.on_surface, .title_m);

    var y = outer.y + pad + icons_phosphor.size + tokens.Space.sm;
    const inner_w = outer.w - pad * 2;
    const E = zb_exposes.E;

    if (zb_exposes.has(ex, E.state)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const on = idx < w.zb_dev_on.len and w.zb_dev_on[idx];
        pushSlot(lay, .state, row, 0);
        paintToggleRow(logical, theme, row, "State", on);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.brightness)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const pct = zb_exposes.sliderPctFromLevel(snap.level);
        var vbuf: [8]u8 = undefined;
        const vt = std.fmt.bufPrint(&vbuf, "{d}", .{snap.level}) catch null;
        pushSlot(lay, .brightness, row, pct);
        zb_exposes.paintSliderRow(logical, theme, row, "Brightness", pct, vt);
        y += row_h + zb_exposes.slider_extra;
    }

    if (zb_exposes.has(ex, E.color_temp)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const pct = zb_exposes.colorTempPct(snap.color_temp_mireds);
        var vbuf: [8]u8 = undefined;
        const vt = std.fmt.bufPrint(&vbuf, "{d}", .{snap.color_temp_mireds}) catch null;
        pushSlot(lay, .color_temp, row, pct);
        zb_exposes.paintSliderRow(logical, theme, row, "Color temp", pct, vt);
        y += row_h + zb_exposes.slider_extra;
    }

    if (zb_exposes.has(ex, E.color_xy)) {
        font.drawTextRole(logical, outer.x + pad, y, "Color XY", theme.on_surface_variant, .label_m);
        const color_row_y = y + zb_exposes.color_label_h + tokens.Space.xs;
        const color_row: geom.Rect = .{ .x = outer.x + pad, .y = color_row_y, .w = inner_w, .h = row_h };
        pushSlot(lay, .color_xy, color_row, 0);
        const bar_y = color_row_y + @divTrunc(row_h - zb_exposes.color_bar_visual_h, 2);
        zb_exposes.paintColorBar(logical, .{ .x = outer.x + pad, .y = bar_y, .w = inner_w, .h = zb_exposes.color_bar_visual_h }, snap, theme);
        y += zb_exposes.color_bar_h;
    }

    if (zb_exposes.has(ex, E.effect)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        pushSlot(lay, .effect, row, 0);
        paintDropdownRow(logical, theme, row, "Effect", zb_exposes.dropdownValue(snap, .effect));
        y += row_h;
    }

    if (zb_exposes.has(ex, E.min_brightness)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const pct = zb_exposes.sliderPctFromLevel(snap.min_level);
        pushSlot(lay, .min_brightness, row, pct);
        zb_exposes.paintSliderRow(logical, theme, row, "Min brightness", pct, null);
        y += row_h + zb_exposes.slider_extra;
    }

    if (zb_exposes.has(ex, E.max_brightness)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const pct = zb_exposes.sliderPctFromLevel(snap.max_level);
        pushSlot(lay, .max_brightness, row, pct);
        zb_exposes.paintSliderRow(logical, theme, row, "Max brightness", pct, null);
        y += row_h + zb_exposes.slider_extra;
    }

    if (zb_exposes.has(ex, E.light_type)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        pushSlot(lay, .light_type, row, 0);
        paintDropdownRow(logical, theme, row, "Light type", zb_exposes.dropdownValue(snap, .light_type));
        y += row_h;
    }

    if (zb_exposes.has(ex, E.countdown)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        const pct = zb_exposes.countdownPct(snap.countdown_s);
        var vbuf: [12]u8 = undefined;
        const vt = std.fmt.bufPrint(&vbuf, "{d}", .{snap.countdown_s}) catch null;
        pushSlot(lay, .countdown, row, pct);
        zb_exposes.paintSliderRow(logical, theme, row, "Countdown", pct, vt);
        y += row_h + zb_exposes.slider_extra;
    }

    if (zb_exposes.has(ex, E.power) or zb_exposes.has(ex, E.current) or zb_exposes.has(ex, E.voltage) or zb_exposes.has(ex, E.energy)) {
        var pbuf: [96]u8 = undefined;
        const line = zb_exposes.formatPowerBlock(snap, &pbuf);
        font.drawTextRole(logical, outer.x + pad, y, line, theme.on_surface_variant, .body_m);
        y += zb_exposes.power_block_h;
    }

    if (zb_exposes.has(ex, E.child_lock)) {
        const row: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        pushSlot(lay, .child_lock, row, 0);
        paintToggleRow(logical, theme, row, "Child lock", snap.child_lock);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.contact)) {
        const open = (snap.zone_status & 0x0001) != 0;
        const val: []const u8 = if (open) "Open" else "Closed";
        const rr: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        paintReadonly(logical, theme, rr, "Contact", val, if (open) theme.err else theme.on_surface_variant);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.device_temperature)) {
        var tbuf: [16]u8 = undefined;
        const val = std.fmt.bufPrint(&tbuf, "{d}.{d} C", .{
            @divTrunc(snap.device_temp_c_x10, 10),
            @mod(snap.device_temp_c_x10, 10),
        }) catch "?";
        const rr: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        paintReadonly(logical, theme, rr, "Device temperature", val, theme.on_surface_variant);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.power_outage_count)) {
        var cbuf: [12]u8 = undefined;
        const val = std.fmt.bufPrint(&cbuf, "{d}", .{snap.power_outage_count}) catch "?";
        const rr: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        paintReadonly(logical, theme, rr, "Power outage count", val, theme.on_surface_variant);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.trigger_count)) {
        var cbuf: [12]u8 = undefined;
        const val = std.fmt.bufPrint(&cbuf, "{d}", .{snap.trigger_count}) catch "?";
        const rr: geom.Rect = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
        paintReadonly(logical, theme, rr, "Trigger count", val, theme.on_surface_variant);
        y += row_h;
    }

    if (zb_exposes.has(ex, E.cover)) {
        const labels = [_][]const u8{ "Open", "Close", "Stop" };
        var ci: u8 = 0;
        const chip_w = @divTrunc(inner_w - tokens.Space.sm * 2, 3);
        while (ci < 3) : (ci += 1) {
            const cr: geom.Rect = .{
                .x = outer.x + pad + @as(i32, @intCast(ci)) * (chip_w + tokens.Space.sm),
                .y = y,
                .w = chip_w,
                .h = row_h,
            };
            pushSlot(lay, .cover, cr, ci);
            widgets.drawTonalButton(logical, cr, labels[ci], theme);
        }
        y += row_h;
    }

    lay.exposes_link = .{ .x = outer.x + pad, .y = y, .w = inner_w, .h = row_h };
    const link_lh = font.faceHeight(font.faceForRole(.label_m));
    font.drawTextRole(logical, lay.exposes_link.x, y + @divTrunc(row_h - link_lh, 2), "Device details >", theme.primary, .label_m);
    y += row_h;

    const foot_y = outer.y + outer.h - pad - row_h;
    var lqi_buf: [16]u8 = undefined;
    const lqi = if (snap.lqi == 0) "Signal pending" else std.fmt.bufPrint(&lqi_buf, "Link quality {d}", .{snap.lqi}) catch "Link quality";
    const foot_mid = foot_y + @divTrunc(row_h, 2);
    icons_phosphor.draw(logical, outer.x + pad, foot_y + @divTrunc(row_h - icons_phosphor.size, 2), .rss_simple, theme.on_surface_variant);
    const foot_lh = font.faceHeight(font.faceForRole(.label_m));
    font.drawTextRole(logical, outer.x + pad + icons_phosphor.size + tokens.Space.xs, foot_mid - @divTrunc(foot_lh, 2), lqi, theme.on_surface_variant, .label_m);

    if (zb_exposes.has(ex, E.battery) and snap.battery_pct != 255) {
        var bbuf: [12]u8 = undefined;
        const bat = std.fmt.bufPrint(&bbuf, "{d}%", .{snap.battery_pct}) catch "?";
        const bx = outer.x + @divTrunc(inner_w, 2);
        icons_phosphor.draw(logical, bx, foot_y + @divTrunc(row_h - icons_phosphor.size, 2), .battery_medium, theme.on_surface_variant);
        font.drawTextRole(logical, bx + icons_phosphor.size + tokens.Space.xs, foot_mid - @divTrunc(foot_lh, 2), bat, theme.on_surface_variant, .label_m);
    }

    const cfg_w = btnWidth("Configure");
    const id_w = btnWidth("Identify");
    const del_w = btnWidth("Remove");
    lay.remove = .{ .x = outer.x + outer.w - pad - del_w, .y = foot_y, .w = del_w, .h = row_h };
    lay.identify = .{ .x = lay.remove.x - tokens.Space.sm - id_w, .y = foot_y, .w = id_w, .h = row_h };
    lay.configure = .{ .x = lay.identify.x - tokens.Space.sm - cfg_w, .y = foot_y, .w = cfg_w, .h = row_h };
    widgets.drawFilledButton(logical, lay.configure, "Configure", theme);
    widgets.drawTonalButton(logical, lay.identify, "Identify", theme);
    widgets.drawDangerTonalButton(logical, lay.remove, "Remove", theme);
}

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme, ctx: Ctx, enter_t: f32) Layout {
    widgets.fillScrim(logical, theme);
    const shell = cardGeom(enter_t);
    widgets.fillRoundRect(logical, shell, tokens.Shape.dialog, theme.elev(3));
    widgets.strokeRoundRect(logical, shell, tokens.Shape.dialog, theme.outline_variant, 1);

    var lay: Layout = .{};
    lay.header = tool_chrome.headerChrome(shell);
    tool_chrome.paintBackToPanel(logical, theme, lay.header.back);
    const title_x = lay.header.back.x + lay.header.back.w + tokens.Space.sm;
    tool_chrome.paintTitle(logical, theme, title_x, lay.header.back.y, "Zigbee");
    tool_chrome.paintExit(logical, theme, lay.header.exit);

    const pad = tokens.Space.lg;
    const w = ctx.wireless;
    const status_y = lay.header.back.y + lay.header.back.h + tokens.Space.sm;
    const bar_y = status_y - 10;
    if (!w.zb_node_open) {
        lay.radio = .{ .x = shell.x + shell.w - pad - 250, .y = status_y - 10, .w = 250, .h = 52 };
        paintToggleRow(logical, theme, lay.radio, "Zigbee radio", w.zigbee);
        lay.add = .{ .x = shell.x + pad, .y = bar_y, .w = 260, .h = 64 };
        widgets.drawFilledButton(logical, lay.add, "Add device", theme);
    }

    const footer_h = if (w.zb_node_open) 0 else btn_size.height() + tokens.Space.md;
    const body_top = if (w.zb_node_open)
        lay.header.back.y + lay.header.back.h + tokens.Space.sm
    else
        bar_y + lay.add.h + tokens.Space.md;
    lay.view = .{
        .x = shell.x + pad,
        .y = body_top,
        .w = shell.w - pad * 2,
        .h = shell.y + shell.h - pad - footer_h - body_top,
    };
    if (w.zb_node_open) {
        // Configuration owns the whole body. Cover the network toolbar drawn
        // during the transition so all four fixed channels fit without a
        // laggy scrolling surface.
        logical.fillRect(lay.view, theme.elev(3));
        const node_gap = tokens.Space.sm;
        lay.scroll_max = 0;
        const node_scroll: i32 = 0;
        logical.setClip(lay.view);
        var y = lay.view.y - node_scroll;
        const full_w = lay.view.w;
        if (!w.zb_node_ready) {
            font.drawTextRole(logical, lay.view.x, y, "Reading Node configuration...", theme.on_surface_variant, .title_m);
        } else {
            const count: usize = @min(@as(usize, w.zb_node_channel_count), w.zb_node_channels.len);
            const pages: usize = count + 1;
            const page: usize = @min(@as(usize, w.zb_node_page), pages - 1);
            const first: usize = page -| 1;
            const last: usize = @min(first + 1, count);
            // Simple channel types have few controls. Let them use the screen
            // instead of compressing their touch targets into the top half.
            // Temperature pages contain more rows and retain the compact size.
            const active_type: u8 = if (page > 0 and first < count) w.zb_node_channels[first].typ else 0;
            const row: i32 = if (page == 0)
                78
            else switch (active_type) {
                1, 2 => 84,
                3 => 70,
                4 => 52,
                else => 78,
            };
            lay.node_page_start = @intCast(first);
            font.drawTextRole(logical, lay.view.x, y, "Modulus Zigbee Node", theme.on_surface, .title_l);
            y += 52;
            var page_buf: [40]u8 = undefined;
            const page_text = if (page == 0) "STATUS LED SETTINGS" else std.fmt.bufPrint(&page_buf, "CHANNEL {d} SETTINGS", .{first + 1}) catch "CHANNEL SETTINGS";
            const section: geom.Rect = .{ .x = lay.view.x, .y = y, .w = full_w, .h = 58 };
            widgets.fillRoundRect(logical, section, tokens.Shape.md, theme.primary_container);
            const page_w = font.textWidthStr(page_text, .title_m);
            const page_h = font.faceHeight(font.faceForRole(.title_m));
            font.drawTextRole(logical, section.x + @divTrunc(section.w - page_w, 2), section.y + @divTrunc(section.h - page_h, 2), page_text, theme.on_primary_container, .title_m);
            y += section.h + node_gap;
            const types = [_][]const u8{ "Disabled", "Switch", "Digital output", "Digital input", "DS18B20" };
            if (page == 0) {
                lay.node_name = .{ .x = lay.view.x, .y = y, .w = full_w, .h = row };
                paintDropdownRow(logical, theme, lay.node_name, "Device name", std.mem.sliceTo(&w.zb_node_name, 0));
                y += row + node_gap;
                var led_gpio: [12]u8 = undefined;
                lay.node_led_gpio = .{ .x = lay.view.x, .y = y, .w = full_w, .h = row };
                const led_text = if (w.zb_node_led_gpio < 0) "None" else std.fmt.bufPrint(&led_gpio, "GPIO {d}", .{w.zb_node_led_gpio}) catch "?";
                paintDropdownRow(logical, theme, lay.node_led_gpio, "Status LED pin", led_text);
                y += row + node_gap;
                lay.node_led_polarity = .{ .x = lay.view.x, .y = y, .w = full_w, .h = row };
                paintToggleRow(logical, theme, lay.node_led_polarity, "LED active low", (w.zb_node_led_flags & 1) != 0);
                y += row + node_gap;
            } else {
                var i: usize = 0;
                while (i < last - first) : (i += 1) {
                    const channel_idx = first + i;
                    var gpio: [12]u8 = undefined;
                    const ch = &w.zb_node_channels[channel_idx];
                    const half = @divTrunc(full_w - node_gap, 2);
                    lay.node_channel_name[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                    paintDropdownRow(logical, theme, lay.node_channel_name[i], "Name", std.mem.sliceTo(&ch.name, 0));
                    lay.node_type[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                    paintDropdownRow(logical, theme, lay.node_type[i], "Function", types[@min(@as(usize, ch.typ), types.len - 1)]);
                    y += row + node_gap;
                    lay.node_gpio[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                    const gpio_text = if (ch.gpio < 0)
                        "None"
                    else if (xiaoDigitalPin(ch.gpio)) |pin|
                        std.fmt.bufPrint(&gpio, "D{d} (GPIO {d})", .{ pin, ch.gpio }) catch "?"
                    else
                        std.fmt.bufPrint(&gpio, "Invalid GPIO {d}", .{ch.gpio}) catch "?";
                    paintDropdownRow(logical, theme, lay.node_gpio[i], "Pin", gpio_text);
                    lay.node_favorite[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                    const favorites = [_][]const u8{ "Not shown", "Position 1", "Position 2", "Position 3" };
                    paintDropdownRow(logical, theme, lay.node_favorite[i], "Quick access", favorites[@min(@as(usize, ch.favorite), 3)]);
                    y += row + node_gap;
                    if (ch.typ == 4) {
                        var period: [80]u8 = undefined;
                        const sensor_no = dsBusOrdinal(w, channel_idx);
                        var rom_assigned = false;
                        for (ch.sensor_rom) |b| rom_assigned = rom_assigned or b != 0;
                        const poll_diag: []const u8 = if (ch.gpio < 0)
                            "Select GPIO"
                        else switch (ch.temperature_state) {
                            1 => if (rom_assigned) std.fmt.bufPrint(&period, "S#{d} {d:.1}C | ID {X:0>2}{X:0>2}", .{
                                sensor_no,
                                @as(f32, @floatFromInt(ch.temperature_centi_c)) / 100.0,
                                ch.sensor_rom[6], ch.sensor_rom[7],
                            }) catch "Live" else std.fmt.bufPrint(&period, "{d}s | S#{d} {d:.1}C binding", .{
                                ch.poll_interval_s, sensor_no,
                                @as(f32, @floatFromInt(ch.temperature_centi_c)) / 100.0,
                            }) catch "Binding",
                            2 => std.fmt.bufPrint(&period, "{d}s | S#{d} sensor/CRC error", .{ ch.poll_interval_s, sensor_no }) catch "Sensor error",
                            3 => std.fmt.bufPrint(&period, "{d}s | S#{d} node stale", .{ ch.poll_interval_s, sensor_no }) catch "Node stale",
                            4 => std.fmt.bufPrint(&period, "{d}s | S#{d} restart required", .{ ch.poll_interval_s, sensor_no }) catch "Restart required",
                            else => std.fmt.bufPrint(&period, "{d}s | S#{d} waiting", .{ ch.poll_interval_s, sensor_no }) catch "Waiting",
                        };
                        lay.node_poll[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                        paintDropdownRow(logical, theme, lay.node_poll[i], "Diagnostics", poll_diag);
                        lay.node_alarm_enabled[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                        paintToggleRow(logical, theme, lay.node_alarm_enabled[i], "Temperature alarm", ch.temp_alarm_enabled);
                        y += row + node_gap;
                        var low: [24]u8 = undefined;
                        var high: [24]u8 = undefined;
                        lay.node_alarm_low[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                        paintDropdownRow(logical, theme, lay.node_alarm_low[i], "Low alarm", std.fmt.bufPrint(&low, "{d:.1} C", .{@as(f32, @floatFromInt(ch.temp_alarm_low_centi_c)) / 100.0}) catch "?");
                        lay.node_alarm_high[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                        paintDropdownRow(logical, theme, lay.node_alarm_high[i], "High alarm", std.fmt.bufPrint(&high, "{d:.1} C", .{@as(f32, @floatFromInt(ch.temp_alarm_high_centi_c)) / 100.0}) catch "?");
                        y += row + node_gap;
                        var hyst: [24]u8 = undefined;
                        lay.node_alarm_hysteresis[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                        paintDropdownRow(logical, theme, lay.node_alarm_hysteresis[i], "Hysteresis", std.fmt.bufPrint(&hyst, "{d:.1} C", .{@as(f32, @floatFromInt(ch.temp_alarm_hysteresis_centi_c)) / 100.0}) catch "?");
                        const alarm_actions = [_][]const u8{ "Notification only", "CNC feed hold", "Turn output off" };
                        if (ch.temp_alarm_action == 2) {
                            const action_x = lay.view.x + half + node_gap;
                            const action_half = @divTrunc(half - node_gap, 2);
                            lay.node_alarm_action[i] = .{ .x = action_x, .y = y, .w = action_half, .h = row };
                            paintDropdownRow(logical, theme, lay.node_alarm_action[i], "Action", alarm_actions[2]);
                            lay.node_alarm_output[i] = .{ .x = action_x + action_half + node_gap, .y = y, .w = action_half, .h = row };
                            var target_buf: [32]u8 = undefined;
                            const target: []const u8 = if (ch.temp_alarm_output_channel < w.zb_node_channel_count and
                                (w.zb_node_channels[ch.temp_alarm_output_channel].typ == 1 or w.zb_node_channels[ch.temp_alarm_output_channel].typ == 2))
                            blk: {
                                const target_ch = &w.zb_node_channels[ch.temp_alarm_output_channel];
                                const saved = std.mem.sliceTo(&target_ch.name, 0);
                                break :blk if (saved.len != 0) saved else std.fmt.bufPrint(&target_buf, "Channel {d}", .{ch.temp_alarm_output_channel + 1}) catch "Output";
                            } else "Select output";
                            paintDropdownRow(logical, theme, lay.node_alarm_output[i], "Target", target);
                        } else {
                            lay.node_alarm_action[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                            paintDropdownRow(logical, theme, lay.node_alarm_action[i], "Alarm action", alarm_actions[@min(@as(usize, ch.temp_alarm_action), alarm_actions.len - 1)]);
                        }
                        y += row + node_gap;
                    } else if (ch.typ == 3) {
                        lay.node_polarity[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                        paintToggleRow(logical, theme, lay.node_polarity[i], "Active low", (ch.flags & 1) != 0);
                        lay.node_pullup[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                        paintToggleRow(logical, theme, lay.node_pullup[i], "Internal pull-up", (ch.flags & 2) != 0);
                        y += row + node_gap;
                        const state = if (ch.gpio < 0) "Select a GPIO" else switch (ch.digital_state) {
                            1 => if (ch.digital_value) "ON" else "OFF",
                            2 => "No recent state",
                            3 => "Apply and restart required",
                            else => "Waiting for state",
                        };
                        paintReadonly(logical, theme, .{ .x = lay.view.x, .y = y, .w = full_w, .h = row }, "Input", state, theme.on_surface_variant);
                        y += row + node_gap;
                    } else if (ch.typ == 1 or ch.typ == 2) {
                        lay.node_polarity[i] = .{ .x = lay.view.x, .y = y, .w = half, .h = row };
                        paintToggleRow(logical, theme, lay.node_polarity[i], "Active low", (ch.flags & 1) != 0);
                        lay.node_start[i] = .{ .x = lay.view.x + half + node_gap, .y = y, .w = half, .h = row };
                        paintDropdownRow(logical, theme, lay.node_start[i], "After restart", if (ch.start_mode == 1) "On" else "Off");
                        y += row + node_gap;
                    }
                }
            }
            const action_h: i32 = 72;
            const action_y = lay.view.y + lay.view.h - action_h;
            const apply_w = @divTrunc(full_w * 30, 100);
            const close_w = @divTrunc(full_w * 18, 100);
            lay.node_apply = .{ .x = lay.view.x, .y = action_y, .w = apply_w, .h = action_h };
            lay.node_close = .{ .x = lay.node_apply.x + lay.node_apply.w + tokens.Space.md, .y = action_y, .w = close_w, .h = action_h };
            if (count > 1) {
                const nav_w = @divTrunc(full_w * 18, 100);
                lay.node_next = .{ .x = lay.view.x + full_w - nav_w, .y = action_y, .w = nav_w, .h = action_h };
                lay.node_prev = .{ .x = lay.node_next.x - nav_w - tokens.Space.md, .y = action_y, .w = nav_w, .h = action_h };
            }
            widgets.drawFilledButton(logical, lay.node_apply, "Apply and restart", theme);
            widgets.drawTonalButton(logical, lay.node_close, "Close", theme);
            if (count > 1) {
                if (page > 0) widgets.drawTonalButton(logical, lay.node_prev, "Previous", theme) else widgets.drawButton(logical, lay.node_prev, "Previous", .tonal, .disabled, theme);
                if (page + 1 < pages) widgets.drawFilledButton(logical, lay.node_next, "Next", theme) else if (count < w.zb_node_channels.len) widgets.drawFilledButton(logical, lay.node_next, "Add channel", theme) else widgets.drawButton(logical, lay.node_next, "Next", .filled, .disabled, theme);
            }
        }
        logical.setClip(null);
        return lay;
    }
    lay.card_n = devCount(w);
    const cols = gridCols(lay.view.w, lay.card_n);
    lay.grid_cols = @intCast(cols);
    lay.scroll_max = scrollMax(w, lay.view.w, lay.view.h);
    const scroll = std.math.clamp(ctx.scroll_px, 0, lay.scroll_max);

    logical.setClip(lay.view);
    // NOT defer — that releases at function exit, leaving the footer
    // controls below the list clipped away and invisible.

    if (!w.zigbee) {
        font.drawTextRole(logical, lay.view.x, lay.view.y, "Switch on the Zigbee radio above to search for devices.", theme.on_surface_variant, .body_m);
        logical.setClip(null);
        return lay;
    }
    if (!w.zb_joined) {
        font.drawTextRole(logical, lay.view.x, lay.view.y, "Starting Zigbee...", theme.on_surface_variant, .body_m);
        logical.setClip(null);
        return lay;
    }
    if (lay.card_n == 0) {
        font.drawTextRole(logical, lay.view.x, lay.view.y, "No devices yet - tap Add device.", theme.on_surface_variant, .body_m);
        logical.setClip(null);
        return lay;
    }

    const tile_w = if (cols > 1)
        @divTrunc(lay.view.w - grid_gap * (cols - 1), cols)
    else
        lay.view.w;
    var row_heights: [4]i32 = .{0} ** 4;
    accumulateRowHeights(w, lay.card_n, cols, &row_heights);

    var y_off: i32 = lay.view.y - scroll;
    const rows = gridRows(lay.card_n, cols);
    var row: i32 = 0;
    while (row < rows and row < 4) : (row += 1) {
        const rh = row_heights[@intCast(row)];
        var col: i32 = 0;
        while (col < cols) : (col += 1) {
            const idx = @as(u8, @intCast(row * cols + col));
            if (idx >= lay.card_n) break;
            const x = lay.view.x + col * (tile_w + grid_gap);
            const outer: geom.Rect = .{ .x = x, .y = y_off, .w = tile_w, .h = rh };
            if (!geom.Rect.intersect(outer, lay.view).isEmpty()) {
                paintDevCard(logical, theme, w, idx, outer, &lay.cards[idx]);
            }
        }
        y_off += rh + grid_gap;
    }

    if (ctx.menu_dev != 0xff) {
        const snap = w.zbSnap(ctx.menu_dev);
        const labs = zb_exposes.dropdownLabels(ctx.menu_field);
        if (labs.len > 0) {
            for (lay.cards[ctx.menu_dev].slots) |slot| {
                if (slot.field == ctx.menu_field) {
                    lay.menu_anchor = slot.rect;
                    break;
                }
            }
        }
        _ = snap;
    }
    logical.setClip(null); // release before returning — clip is global state
    return lay;
}

pub fn scrollMax(w: *const settings_prefs.WirelessPrefs, view_w: i32, view_h: i32) i32 {
    const n = devCount(w);
    if (n == 0) return 0;
    const cols = gridCols(view_w, n);
    var row_heights: [4]i32 = .{0} ** 4;
    accumulateRowHeights(w, n, cols, &row_heights);
    const rows = gridRows(n, cols);
    var total: i32 = 0;
    var r: i32 = 0;
    while (r < rows) : (r += 1) {
        total += row_heights[@intCast(r)] + grid_gap;
    }
    return @max(0, total - grid_gap - view_h);
}

fn cardHitAt(c: CardLayout, dev: u8, x: i32, y: i32) Hit {
    if (c.outer.isEmpty() or !c.outer.contains(x, y)) return .{};
    if (c.exposes_link.contains(x, y)) return .{ .kind = .exposes, .dev = dev };
    if (c.identify.contains(x, y)) return .{ .kind = .identify, .dev = dev };
    if (c.remove.contains(x, y)) return .{ .kind = .remove, .dev = dev };
    if (c.configure.contains(x, y)) return .{ .kind = .configure, .dev = dev };
    if (c.rename.contains(x, y)) return .{ .kind = .rename, .dev = dev };
    var si: u8 = 0;
    while (si < c.slot_n) : (si += 1) {
        const slot = c.slots[si];
        if (!slot.rect.contains(x, y)) continue;
        return switch (slot.field) {
            .state => .{ .kind = .toggle, .dev = dev, .field = .state },
            .child_lock => .{ .kind = .child_lock, .dev = dev },
            .effect, .light_type => .{ .kind = .dropdown, .dev = dev, .field = slot.field },
            .brightness, .color_temp, .countdown, .min_brightness, .max_brightness => .{
                .kind = .slider,
                .dev = dev,
                .field = slot.field,
                .aux = sliderPct(slot.rect, x),
            },
            .color_xy => blk: {
                const rel_y = std.math.clamp(y - slot.rect.y, 0, slot.rect.h);
                const y_pct: u8 = @intCast(@min(100, @divTrunc(rel_y * 100, @max(1, slot.rect.h))));
                break :blk .{
                    .kind = .color_xy,
                    .dev = dev,
                    .aux = (@as(u16, sliderPct(slot.rect, x)) << 8) | y_pct,
                };
            },
            .cover => .{ .kind = .cover, .dev = dev, .aux = slot.aux },
            else => .{},
        };
    }
    return .{};
}

test "zigbee grid uses three columns on tab5 width" {
    try std.testing.expectEqual(@as(i32, 1), gridCols(1132, 1));
    try std.testing.expectEqual(@as(i32, 2), gridCols(1132, 2));
    try std.testing.expectEqual(@as(i32, 1), gridCols(760, 2));
}

pub fn layoutMenu(layout: Layout, dev: u8, field: zb_exposes.Field) geom.Rect {
    var anchor: geom.Rect = .{};
    if (dev < layout.card_n) {
        for (layout.cards[dev].slots) |slot| {
            if (slot.field == field) {
                anchor = slot.rect;
                break;
            }
        }
    }
    const labs = zb_exposes.dropdownLabels(field);
    const visible = @min(labs.len, expr.menu_max_visible);
    const mw = expr.menuPopupWidth(anchor.w, labs);
    const mh = @as(i32, @intCast(visible)) * expr.menu_item_h + expr.menu_pad * 2;
    var mx = anchor.x;
    var my = anchor.y + anchor.h + tokens.Space.xs;
    if (my + mh > tokens.Logical.height - tokens.Space.sm) my = anchor.y - mh - tokens.Space.xs;
    if (mx + mw > tokens.Logical.width - tokens.Space.sm) mx = tokens.Logical.width - mw - tokens.Space.sm;
    if (mx < tokens.Space.sm) mx = tokens.Space.sm;
    if (my < tokens.Space.sm) my = tokens.Space.sm;
    return .{ .x = mx, .y = my, .w = mw, .h = mh };
}

pub fn paintMenu(
    logical: *fb.LogicalFb,
    theme: tokens.Theme,
    rect: geom.Rect,
    field: zb_exposes.Field,
    selected: usize,
    scroll: usize,
) void {
    const labs = zb_exposes.dropdownLabels(field);
    if (labs.len == 0) return;
    expr.drawMenuScrolled(logical, rect, labs, selected, scroll, theme);
}

pub fn hit(layout: Layout, x: i32, y: i32) Hit {
    if (tool_chrome.hitBack(layout.header, x, y)) return .{ .kind = .back };
    if (tool_chrome.hitExit(layout.header, x, y)) return .{ .kind = .exit };
    if (tool_chrome.hitScrim(layout.header, x, y)) return .{ .kind = .scrim };
    if (layout.radio.contains(x, y)) return .{ .kind = .radio_toggle };
    if (layout.permit.contains(x, y)) return .{ .kind = .permit_join };
    if (layout.refresh.contains(x, y)) return .{ .kind = .refresh };
    if (!layout.join.isEmpty() and layout.join.contains(x, y)) return .{ .kind = .join_hub };
    if (layout.add.contains(x, y)) return .{ .kind = .add_device };
    if (layout.node_name.contains(x, y)) return .{ .kind = .node_name };
    if (layout.node_led_gpio.contains(x, y)) return .{ .kind = .node_led_gpio };
    if (layout.node_led_polarity.contains(x, y)) return .{ .kind = .node_led_polarity };
    if (layout.node_apply.contains(x, y)) return .{ .kind = .node_apply };
    if (layout.node_close.contains(x, y)) return .{ .kind = .node_close };
    if (layout.node_prev.contains(x, y)) return .{ .kind = .node_prev };
    if (layout.node_next.contains(x, y)) return .{ .kind = .node_next };
    for (0..4) |i| {
        const channel: u8 = layout.node_page_start + @as(u8, @intCast(i));
        if (layout.node_type[i].contains(x, y)) return .{ .kind = .node_type, .dev = channel };
        if (layout.node_channel_name[i].contains(x, y)) return .{ .kind = .node_channel_name, .dev = channel };
        if (layout.node_gpio[i].contains(x, y)) return .{ .kind = .node_gpio, .dev = channel };
        if (layout.node_poll[i].contains(x, y)) return .{ .kind = .node_poll, .dev = channel };
        if (layout.node_favorite[i].contains(x, y)) return .{ .kind = .node_favorite, .dev = channel };
        if (layout.node_start[i].contains(x, y)) return .{ .kind = .node_start, .dev = channel };
        if (layout.node_alarm_enabled[i].contains(x, y)) return .{ .kind = .node_alarm_enabled, .dev = channel };
        if (layout.node_alarm_high[i].contains(x, y)) return .{ .kind = .node_alarm_high, .dev = channel };
        if (layout.node_alarm_low[i].contains(x, y)) return .{ .kind = .node_alarm_low, .dev = channel };
        if (layout.node_alarm_hysteresis[i].contains(x, y)) return .{ .kind = .node_alarm_hysteresis, .dev = channel };
        if (layout.node_alarm_action[i].contains(x, y)) return .{ .kind = .node_alarm_action, .dev = channel };
        if (layout.node_alarm_output[i].contains(x, y)) return .{ .kind = .node_alarm_output, .dev = channel };
        if (layout.node_pullup[i].contains(x, y)) return .{ .kind = .node_pullup, .dev = channel };
        if (layout.node_polarity[i].contains(x, y)) return .{ .kind = .node_polarity, .dev = channel };
    }
    var i: u8 = 0;
    while (i < layout.card_n) : (i += 1) {
        const h = cardHitAt(layout.cards[i], i, x, y);
        if (h.kind != .none) return h;
    }
    return .{};
}

test "zigbee panel chrome meets touch_min" {
    const gpa = std.testing.allocator;
    var logical = try fb.LogicalFb.alloc(gpa);
    defer logical.deinit(gpa);
    var wl: settings_prefs.WirelessPrefs = .{};
    wl.zigbee = true;
    wl.zb_joined = true;
    wl.joinZigbee();
    const lay = paint(&logical, tokens.Theme.industrialTealDark(), .{ .wireless = &wl }, 1);
    try std.testing.expect(lay.header.exit.w >= tokens.Logical.touch_min);
    try std.testing.expect(lay.add.h >= tokens.Logical.touch_min);
    try std.testing.expect(lay.card_n >= 3);
    try std.testing.expectEqual(@as(u8, 2), lay.grid_cols);
    if (lay.card_n > 0) {
        try std.testing.expect(lay.cards[0].identify.h >= tokens.Logical.touch_min);
        try std.testing.expect(lay.cards[0].remove.h >= tokens.Logical.touch_min);
        try std.testing.expect(lay.cards[0].exposes_link.h >= tokens.Logical.touch_min);
    }
}

test "DS18B20 page fits and poll hit selects the correct channel" {
    var logical = try fb.LogicalFb.alloc(std.testing.allocator);
    defer logical.deinit(std.testing.allocator);
    var w: settings_prefs.WirelessPrefs = .{};
    w.zb_node_open = true;
    w.zb_node_ready = true;
    w.zb_node_channel_count = 12;
    w.zb_node_page = 12;
    w.zb_node_channels[0].typ = 2;
    @memcpy(w.zb_node_channels[0].name[0..3], "Fan");
    w.zb_node_channels[11].typ = 4;
    w.zb_node_channels[11].gpio = 22;
    w.zb_node_channels[11].temperature_state = 1;
    w.zb_node_channels[11].temperature_centi_c = -125;
    w.zb_node_channels[11].temp_alarm_action = 2;
    w.zb_node_channels[11].temp_alarm_output_channel = 0;
    const layout = paint(&logical, tokens.Theme.industrialTealDark(), .{ .wireless = &w }, 1.0);
    try std.testing.expect(layout.node_apply.y + layout.node_apply.h <= layout.view.y + layout.view.h);
    const r = layout.node_poll[0];
    try std.testing.expect(r.h >= 48);
    const selected = hit(layout, r.x + 10, r.y + 10);
    try std.testing.expectEqual(Kind.node_poll, selected.kind);
    try std.testing.expectEqual(@as(u8, 11), selected.dev);
    try std.testing.expect(!layout.node_alarm_action[0].isEmpty());
    try std.testing.expect(!layout.node_alarm_output[0].isEmpty());
    try std.testing.expect(layout.node_polarity[0].isEmpty());
}

test "shared DS18B20 GPIO receives deterministic bus ordinals" {
    var w: settings_prefs.WirelessPrefs = .{};
    w.zb_node_channels[0] = .{ .typ = 4, .gpio = 22 };
    w.zb_node_channels[1] = .{ .typ = 2, .gpio = 20 };
    w.zb_node_channels[2] = .{ .typ = 4, .gpio = 22 };
    w.zb_node_channels[3] = .{ .typ = 4, .gpio = 22 };
    try std.testing.expectEqual(@as(u8, 1), dsBusOrdinal(&w, 0));
    try std.testing.expectEqual(@as(u8, 2), dsBusOrdinal(&w, 2));
    try std.testing.expectEqual(@as(u8, 3), dsBusOrdinal(&w, 3));
}
