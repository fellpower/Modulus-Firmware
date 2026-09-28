//! Zigbee Node update guidance. Firmware transfer remains USB-only.

const geom = @import("geom.zig");
const tokens = @import("tokens.zig");
const fb = @import("fb.zig");
const font = @import("font.zig");
const widgets = @import("widgets.zig");
const tool_chrome = @import("m_panel_tool.zig");

pub const Hit = enum { none, back, exit };
pub const Layout = struct { header: tool_chrome.Header = .{} };

pub fn paint(logical: *fb.LogicalFb, theme: tokens.Theme) Layout {
    widgets.fillScrim(logical, theme);
    const card: geom.Rect = .{ .x = 30, .y = 34, .w = tokens.Logical.width - 60, .h = tokens.Logical.height - 68 };
    widgets.fillRoundRect(logical, card, tokens.Shape.dialog, theme.elev(3));
    const header = tool_chrome.headerChrome(card);
    tool_chrome.paintBackTo(logical, theme, header.back, "Devices");
    tool_chrome.paintTitle(logical, theme, header.back.x + header.back.w + tokens.Space.sm, header.back.y, "Zigbee Node Update");
    tool_chrome.paintExit(logical, theme, header.exit);

    const x = card.x + tokens.Space.lg;
    const y = header.back.y + header.back.h + tokens.Space.lg;
    const info: geom.Rect = .{ .x = x, .y = y, .w = card.w - tokens.Space.lg * 2, .h = 180 };
    widgets.fillRoundRect(logical, info, tokens.Shape.lg, theme.surface_container);
    widgets.strokeRoundRect(logical, info, tokens.Shape.lg, theme.outline_variant, 1);
    font.drawTextRole(logical, info.x + tokens.Space.lg, info.y + 24, "USB connection required", theme.on_surface, .title_l);
    font.drawTextRole(logical, info.x + tokens.Space.lg, info.y + 78, "Connect the Zigbee Node to your computer via USB.", theme.on_surface_variant, .body_l);
    font.drawTextRole(logical, info.x + tokens.Space.lg, info.y + 118, "Updating this device from the Tab5 is not available yet.", theme.on_surface_variant, .body_l);
    return .{ .header = header };
}

pub fn hit(layout: Layout, x: i32, y: i32) Hit {
    if (tool_chrome.hitBack(layout.header, x, y) or tool_chrome.hitScrim(layout.header, x, y)) return .back;
    if (tool_chrome.hitExit(layout.header, x, y)) return .exit;
    return .none;
}
