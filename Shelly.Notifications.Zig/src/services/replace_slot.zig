//! Remembers the notification server id of a notification that should be
//! updated in place instead of stacking a new one on every check.
//!
//! The freedesktop Notify call takes a `replaces_id`. Passing the id the
//! server returned for the previous notification makes it update that
//! notification (including its entry in the notification history). Passing
//! 0 always creates a new notification. When the previous notification no
//! longer exists, the specification requires the server to treat the call as
//! a new notification, so a stale id is harmless.

pub const ReplaceSlot = struct {
    /// Server id of the last notification sent through this slot, or 0.
    id: u32 = 0,

    /// The `replaces_id` to send. Notifications that do not replace their
    /// predecessor always get 0, so they appear on their own.
    pub fn replacesId(self: ReplaceSlot, replace_previous: bool) u32 {
        return if (replace_previous) self.id else 0;
    }

    /// Records the id the server assigned. Ids of notifications that do not
    /// replace their predecessor are not tracked, and 0 is never a valid id.
    pub fn remember(self: *ReplaceSlot, replace_previous: bool, id: u32) void {
        if (replace_previous and id != 0) self.id = id;
    }
};

const testing = @import("std").testing;

test "the first replaceable notification is new" {
    const slot: ReplaceSlot = .{};
    try testing.expectEqual(@as(u32, 0), slot.replacesId(true));
}

test "later replaceable notifications replace the last one sent" {
    var slot: ReplaceSlot = .{};
    slot.remember(true, 41);
    try testing.expectEqual(@as(u32, 41), slot.replacesId(true));

    // A server may hand out a new id, for example after the user dismissed
    // the previous notification; follow it.
    slot.remember(true, 57);
    try testing.expectEqual(@as(u32, 57), slot.replacesId(true));
}

test "other notifications appear on their own and do not disturb the slot" {
    var slot: ReplaceSlot = .{};
    slot.remember(true, 41);

    try testing.expectEqual(@as(u32, 0), slot.replacesId(false));
    slot.remember(false, 99);
    try testing.expectEqual(@as(u32, 41), slot.replacesId(true));
}

test "an invalid zero id keeps the previous notification" {
    var slot: ReplaceSlot = .{};
    slot.remember(true, 41);
    slot.remember(true, 0);
    try testing.expectEqual(@as(u32, 41), slot.replacesId(true));
}
