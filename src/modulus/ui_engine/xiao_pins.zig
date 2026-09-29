//! Seeed XIAO ESP32-S3 digital pin mapping shared by existing UI flows.

const std = @import("std");

const digital_to_gpio = [_]u8{ 1, 2, 3, 4, 5, 6, 43, 44, 7, 8, 9 };

pub fn digitalPinToGpio(pin: u32) ?u32 {
    if (pin >= digital_to_gpio.len) return null;
    return digital_to_gpio[pin];
}

pub fn gpioToDigitalPin(gpio: i8) ?u32 {
    for (digital_to_gpio, 0..) |candidate, pin| if (gpio == candidate) return @intCast(pin);
    return null;
}

test "XIAO D0-D10 mapping round trips" {
    for (digital_to_gpio, 0..) |gpio, pin| {
        try std.testing.expectEqual(@as(?u32, @intCast(gpio)), digitalPinToGpio(@intCast(pin)));
        try std.testing.expectEqual(@as(?u32, @intCast(pin)), gpioToDigitalPin(@intCast(gpio)));
    }
    try std.testing.expect(digitalPinToGpio(11) == null);
    try std.testing.expectEqual(@as(?u32, 8), gpioToDigitalPin(7));
    try std.testing.expectEqual(@as(?u32, 9), gpioToDigitalPin(8));
}
