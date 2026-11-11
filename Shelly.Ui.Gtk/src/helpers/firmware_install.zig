//! Confirm-then-install flow for firmware updates, shared by the Updates
//! and Firmware pages.

const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const translations = @import("translations.zig");

pub const CompleteFn = *const fn (ctx: *anyopaque, success: bool) void;

/// Arguments for the transaction. --no-confirm carries the user's answer
/// to the dialog; --no-refresh keeps the install to the devices shown.
pub const argv = [_][]const u8{ "upgrade", "firmware", "--no-confirm", "--no-refresh" };

const Pending = struct {
    window: *ShellyWindow,
    /// Device names, shown as transaction rows. Owned.
    names: [][]const u8,
    on_complete: CompleteFn,
    ctx: *anyopaque,

    fn destroy(self: *Pending) void {
        for (self.names) |name| std.heap.c_allocator.free(name);
        std.heap.c_allocator.free(self.names);
        std.heap.c_allocator.destroy(self);
    }
};

/// Shows the firmware warning and, if the user agrees, installs the updates
/// for `names` through the transaction page.
pub fn confirmAndInstall(
    window: *ShellyWindow,
    names: []const []const u8,
    on_complete: CompleteFn,
    ctx: *anyopaque,
) void {
    if (names.len == 0) return;
    const pending = std.heap.c_allocator.create(Pending) catch return;
    const owned = std.heap.c_allocator.alloc([]const u8, names.len) catch {
        std.heap.c_allocator.destroy(pending);
        return;
    };
    var copied: usize = 0;
    for (names, owned) |name, *slot| {
        slot.* = std.heap.c_allocator.dupe(u8, name) catch {
            for (owned[0..copied]) |done| std.heap.c_allocator.free(done);
            std.heap.c_allocator.free(owned);
            std.heap.c_allocator.destroy(pending);
            return;
        };
        copied += 1;
    }
    pending.* = .{ .window = window, .names = owned, .on_complete = on_complete, .ctx = ctx };

    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buf, "{s}\n\n{s}", .{
        translations._("Shelly will install the firmware updates listed under Firmware."),
        translations._("Keep the computer plugged in and do not power it off while firmware is being installed. Some devices finish installing only after a restart."),
    }, 0) catch translations._("Install firmware updates?");
    const dialog = ConfirmDialog.new(translations._("Install firmware updates?"), message, &onResponse, pending);
    dialog.setButtons(translations._("Update Firmware"), translations._("Cancel"));
    window.showLockout(dialog.as(gtk.Widget));
}

fn onResponse(ctx: ?*anyopaque, confirmed: bool) void {
    const pending: *Pending = @ptrCast(@alignCast(ctx.?));
    defer pending.destroy();
    pending.window.hideLockout();
    if (!confirmed) return;

    // The transaction page copies argv and the row names.
    pending.window.startTransaction(.{
        .title = translations._("Updating firmware"),
        .argv = &argv,
        .packages = pending.names,
        .on_complete = pending.on_complete,
        .privileged = true,
        .ctx = pending.ctx,
    });
}
