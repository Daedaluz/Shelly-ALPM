//! `shelly list-updates firmware` and `shelly upgrade firmware`.
//!
//! Firmware is managed through fwupd when it is installed. It is an explicit,
//! opt-in backend: `upgrade all` and `list-updates all` never touch firmware,
//! because flashing can require AC power, a reboot, or a shutdown and should
//! never ride along with routine package upgrades.

const std = @import("std");
const diagnostics = @import("diagnostics");
const PackageManager = @import("PackageManager");
const test_support = @import("test_support.zig");
const format = @import("../output/format.zig");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const table = @import("../output/table.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");

const fwupd = PackageManager.firmware;

const list_command_path = "shelly list-updates firmware";
const devices_command_path = "shelly list firmware";
const upgrade_command_path = "shelly upgrade firmware";
pub const refresh_option = "--refresh";
pub const no_refresh_option = "--no-refresh";

const unavailable_message = "Firmware updates need fwupd, which is not installed. Install the fwupd package to manage device firmware with Shelly.";
const up_to_date_message = "All firmware is up to date.";

/// Where fwupd lives and how to run it. Tests replace both.
const Environment = struct {
    /// Absolute path to `fwupdmgr`, or null when fwupd is not installed.
    executable: ?[]const u8,
    runner: fwupd.Runner,
    /// Let fwupdmgr draw its own progress on the terminal while flashing.
    interactive_terminal: bool,
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isFirmwarePath(invocation.command.path)) return null;
    var system: fwupd.SystemRunner = .{ .io = context.io };
    return dispatchWith(context, invocation, .{
        .executable = fwupd.findExecutable(context.io, &fwupd.default_executable_candidates),
        .runner = system.runner(),
        .interactive_terminal = context.stdout_is_tty,
    });
}

fn isFirmwarePath(path: []const u8) bool {
    return std.mem.eql(u8, path, list_command_path) or
        std.mem.eql(u8, path, devices_command_path) or
        std.mem.eql(u8, path, upgrade_command_path);
}

fn dispatchWith(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    environment: Environment,
) !?u8 {
    if (std.mem.eql(u8, invocation.command.path, list_command_path))
        return try listUpdates(context, invocation, environment);
    if (std.mem.eql(u8, invocation.command.path, devices_command_path))
        return try listDevices(context, invocation, environment);
    if (std.mem.eql(u8, invocation.command.path, upgrade_command_path))
        return try upgrade(context, invocation, environment);
    return null;
}

// ---------------------------------------------------------------------------
// list-updates firmware
// ---------------------------------------------------------------------------

fn listUpdates(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    environment: Environment,
) !u8 {
    const executable = environment.executable orelse {
        try writeError(context, invocation, unavailable_message);
        return 1;
    };
    var client: fwupd.Client = .{
        .allocator = context.allocator,
        .runner = environment.runner,
        .executable = executable,
    };
    defer client.deinit();

    if (optionEnabled(invocation, refresh_option)) try refreshMetadata(context, invocation, &client);

    var updates = client.getUpdates() catch |err| {
        try writeCommandFailure(context, invocation, "Could not check for firmware updates.", err, client.last_error);
        return 1;
    };
    defer updates.deinit();

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeUpdatesJson(&payload.writer, updates.items);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeUpdatesJson(context.stdout, updates.items);
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
    } else {
        try writeUpdatesPlain(context, updates.items);
        if (updates.items.len != 0) {
            const total = try std.fmt.allocPrint(
                context.allocator,
                "Firmware Total: {d} device{s} can be updated",
                .{ updates.items.len, plural(updates.items.len) },
            );
            defer context.allocator.free(total);
            try colors.printLine(context, .warning, "{s}", .{total});
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// list firmware
// ---------------------------------------------------------------------------

/// A device with the update fwupd offers for it, if any.
const DeviceStatus = struct {
    device: fwupd.Device,
    update: ?fwupd.Update,
};

fn listDevices(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    environment: Environment,
) !u8 {
    const executable = environment.executable orelse {
        try writeError(context, invocation, unavailable_message);
        return 1;
    };
    var client: fwupd.Client = .{
        .allocator = context.allocator,
        .runner = environment.runner,
        .executable = executable,
    };
    defer client.deinit();

    var devices = client.getDevices() catch |err| {
        try writeCommandFailure(context, invocation, "Could not list firmware devices.", err, client.last_error);
        return 1;
    };
    defer devices.deinit();
    // Updates are optional here: the device list is still useful without
    // them, for example before metadata has ever been downloaded.
    var updates: ?fwupd.UpdateList = client.getUpdates() catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        break :blk null;
    };
    defer if (updates) |*list| list.deinit();

    const statuses = try context.allocator.alloc(DeviceStatus, devices.items.len);
    defer context.allocator.free(statuses);
    for (devices.items, statuses) |device, *status| {
        status.* = .{ .device = device, .update = null };
        if (updates) |list| for (list.items) |update| {
            if (std.mem.eql(u8, update.device_id, device.device_id)) status.update = update;
        };
    }

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeDevicesJson(&payload.writer, statuses);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeDevicesJson(context.stdout, statuses);
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
    } else {
        try writeDevicesPlain(context, statuses);
    }
    return 0;
}

fn writeDevicesPlain(context: *runtime.RuntimeContext, statuses: []const DeviceStatus) !void {
    if (statuses.len == 0) {
        try context.stdout.writeAll("fwupd reports no devices that can be updated.\n");
        try context.stdout.flush();
        return;
    }
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const rows = try allocator.alloc([]const []const u8, statuses.len);
    for (statuses, rows) |status, *row| {
        const cells = try allocator.alloc([]const u8, 4);
        cells[0] = status.device.name;
        cells[1] = if (status.device.vendor.len == 0) "Unknown" else status.device.vendor;
        cells[2] = if (status.device.version.len == 0) "Unknown" else status.device.version;
        cells[3] = if (status.update) |update| update.new_version else "Up to date";
        row.* = cells;
    }
    try table.write(context, &.{ "Device", "Vendor", "Version", "Update" }, rows);
}

fn writeDevicesJson(writer: *std.Io.Writer, statuses: []const DeviceStatus) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (statuses) |status| {
        try json.beginObject();
        try field(&json, "DeviceId", status.device.device_id);
        try field(&json, "Name", status.device.name);
        try field(&json, "Vendor", status.device.vendor);
        try field(&json, "Plugin", status.device.plugin);
        try field(&json, "Version", status.device.version);
        try field(&json, "Summary", status.device.summary);
        try field(&json, "UpdateVersion", if (status.update) |update| update.new_version else "");
        try field(&json, "Urgency", if (status.update) |update| update.urgency else "");
        try json.endObject();
    }
    try json.endArray();
}

// ---------------------------------------------------------------------------
// upgrade firmware
// ---------------------------------------------------------------------------

fn upgrade(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    environment: Environment,
) !u8 {
    const ui = invocation.globals.ui_mode;
    if (ui and !invocation.globals.no_confirm) {
        // The UI cannot answer the terminal prompt. It shows its own warning
        // and passes --no-confirm once the user agrees; without that, refuse
        // instead of flashing silently.
        try output.writeErrorFrame(context, "Firmware upgrades from the Shelly UI need confirmation in the UI first. Run `shelly upgrade firmware` in a terminal instead.");
        return 1;
    }
    const executable = environment.executable orelse {
        try writeError(context, invocation, unavailable_message);
        return 1;
    };
    var client: fwupd.Client = .{
        .allocator = context.allocator,
        .runner = environment.runner,
        .executable = executable,
    };
    defer client.deinit();

    if (!optionEnabled(invocation, no_refresh_option)) try refreshMetadata(context, invocation, &client);

    var updates = client.getUpdates() catch |err| {
        try writeCommandFailure(context, invocation, "Could not check for firmware updates.", err, client.last_error);
        return 1;
    };
    defer updates.deinit();

    if (updates.items.len == 0) {
        if (ui) try output.writeInfoFrame(context, up_to_date_message) else try output.writeSuccess(context, up_to_date_message);
        return 0;
    }

    if (ui) return upgradeFromUi(context, invocation, &client, updates.items);

    try context.stdout.writeAll("The following firmware updates are available:\n\n");
    try writeUpdatesPlain(context, updates.items);
    try context.stdout.writeAll(
        "\nKeep the computer plugged in and do not power it off while firmware is being installed.\n" ++
            "Some devices finish installing only after a restart.\n\n",
    );
    try context.stdout.flush();

    if (!invocation.globals.no_confirm and !try confirm(context, "Install these firmware updates?")) {
        try context.stdout.writeAll("Operation cancelled.\n");
        try context.stdout.flush();
        return 0;
    }

    // Install exactly the devices the user just reviewed, even if fwupd
    // learned about more updates in the meantime.
    const device_ids = try context.allocator.alloc([]const u8, updates.items.len);
    defer context.allocator.free(device_ids);
    for (updates.items, device_ids) |update, *device_id| device_id.* = update.device_id;

    try context.stdout.writeAll("Installing firmware updates...\n");
    try context.stdout.flush();
    const mode: fwupd.Mode = if (environment.interactive_terminal and !invocation.globals.json) .passthrough else .capture;
    client.update(device_ids, mode) catch |err| {
        try writeCommandFailure(context, invocation, "Could not complete the firmware upgrade.", err, client.last_error);
        return 1;
    };

    try output.writeSuccess(context, "Firmware upgrade complete.");
    // Failing to read restart flags must not turn a successful flash into a
    // failure; the user simply gets no restart hint.
    const pending = client.pendingRestart() catch .none;
    switch (pending) {
        .none => {},
        .reboot => try output.writeWarning(context, "Restart the computer to finish installing the firmware updates."),
        .shutdown => try output.writeWarning(context, "Shut down the computer to finish installing the firmware updates."),
    }
    return 0;
}

/// UI-driven install, after the user confirmed in the Shelly UI. Reports
/// per-device progress as frames the transaction page understands: each
/// device row is keyed by its name.
fn upgradeFromUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    client: *fwupd.Client,
    updates: []const fwupd.Update,
) !u8 {
    const device_ids = try context.allocator.alloc([]const u8, updates.len);
    defer context.allocator.free(device_ids);
    for (updates, device_ids) |update, *device_id| {
        device_id.* = update.device_id;
        const message = try std.fmt.allocPrint(context.allocator, "Installing firmware {s} for {s}", .{ update.new_version, update.name });
        defer context.allocator.free(message);
        try output.writeAlpmPackageInfoFrame(context, "Installing", message, update.name);
    }

    client.update(device_ids, .capture) catch |err| {
        try writeCommandFailure(context, invocation, "Could not complete the firmware upgrade.", err, client.last_error);
        return 1;
    };

    for (updates) |update| {
        const message = try std.fmt.allocPrint(context.allocator, "Updated {s} firmware to {s}", .{ update.name, update.new_version });
        defer context.allocator.free(message);
        try output.writeAlpmPackageInfoFrame(context, "PackageUpgraded", message, update.name);
    }
    switch (client.pendingRestart() catch .none) {
        .none => {},
        .reboot => try output.writeWarningFrame(context, "Restart the computer to finish installing the firmware updates."),
        .shutdown => try output.writeWarningFrame(context, "Shut down the computer to finish installing the firmware updates."),
    }
    return 0;
}

fn refreshMetadata(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    client: *fwupd.Client,
) !void {
    if (invocation.globals.ui_mode) {
        try output.writeInfoFrame(context, "Refreshing firmware metadata...");
    } else if (!invocation.globals.json) {
        try context.stdout.writeAll("Refreshing firmware metadata...\n");
        try context.stdout.flush();
    }
    _ = client.refresh() catch |err| {
        if (err == error.OutOfMemory) return err;
        // Offline or a misconfigured remote should not hide cached results.
        const detail = client.last_error orelse @errorName(err);
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Could not refresh firmware metadata; using cached metadata instead. {s}",
            .{detail},
        );
        defer context.allocator.free(message);
        try writeWarningMessage(context, invocation, message);
    };
}

fn confirm(context: *runtime.RuntimeContext, prompt: []const u8) !bool {
    const reader = context.stdin orelse return false;
    while (true) {
        // Firmware defaults to "no": an accidental Enter must not flash.
        try context.stdout.print("{s} (y/N) ", .{prompt});
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return false;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "n") or
            std.ascii.eqlIgnoreCase(answer, "no")) return false;
        if (std.ascii.eqlIgnoreCase(answer, "y") or
            std.ascii.eqlIgnoreCase(answer, "yes")) return true;
        try context.stdout.writeAll("Please answer 'y' or 'n'.\n");
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn writeUpdatesPlain(context: *runtime.RuntimeContext, updates: []const fwupd.Update) !void {
    if (updates.len == 0) return output.writeSuccess(context, up_to_date_message);

    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const size_display = try format.loadSizeDisplay(context);
    const sorted = try sortedByName(allocator, updates);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    for (sorted, rows) |update, *row| {
        const cells = try allocator.alloc([]const u8, 5);
        cells[0] = update.name;
        cells[1] = if (update.vendor.len == 0) "Unknown" else update.vendor;
        cells[2] = if (update.current_version.len == 0) "Unknown" else update.current_version;
        cells[3] = if (update.urgency.len == 0)
            update.new_version
        else
            try std.fmt.allocPrint(allocator, "{s} ({s})", .{ update.new_version, update.urgency });
        cells[4] = if (update.size == 0) "Unknown" else try format.formatSignedSize(allocator, size_display, update.size);
        row.* = cells;
    }
    try table.write(context, &.{ "Device", "Vendor", "Current Version", "New Version", "Download Size" }, rows);
}

fn writeUpdatesJson(writer: *std.Io.Writer, updates: []const fwupd.Update) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (updates) |update| {
        try json.beginObject();
        try field(&json, "DeviceId", update.device_id);
        try field(&json, "Name", update.name);
        try field(&json, "Vendor", update.vendor);
        try field(&json, "Plugin", update.plugin);
        try field(&json, "CurrentVersion", update.current_version);
        try field(&json, "NewVersion", update.new_version);
        try field(&json, "Summary", update.summary);
        try field(&json, "DownloadSize", update.size);
        try field(&json, "Urgency", update.urgency);
        try json.endObject();
    }
    try json.endArray();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn sortedByName(allocator: std.mem.Allocator, updates: []const fwupd.Update) ![]fwupd.Update {
    const sorted = try allocator.dupe(fwupd.Update, updates);
    std.mem.sort(fwupd.Update, sorted, {}, struct {
        fn lessThan(_: void, left: fwupd.Update, right: fwupd.Update) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return sorted;
}

fn writeCommandFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    summary: []const u8,
    err: anyerror,
    detail: ?[]const u8,
) !void {
    const message = if (err == error.FwupdUnavailable)
        try context.allocator.dupe(u8, unavailable_message)
    else if (detail) |text|
        try std.fmt.allocPrint(context.allocator, "{s} fwupd reported: {s}", .{ summary, text })
    else
        try std.fmt.allocPrint(
            context.allocator,
            "{0s} {1s}\n\nTechnical details: {2s}",
            .{ summary, diagnostics.cause(err), @errorName(err) },
        );
    defer context.allocator.free(message);
    try writeError(context, invocation, message);
}

fn writeError(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !void {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else if (invocation.globals.json) {
        // Keep stdout parseable for scripts.
        try context.stderr.print("{s}\n", .{message});
        try context.stderr.flush();
    } else {
        try output.writeFailure(context, message);
    }
}

fn writeWarningMessage(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !void {
    if (invocation.globals.ui_mode) {
        try output.writeWarningFrame(context, message);
    } else if (invocation.globals.json) {
        try context.stderr.print("{s}\n", .{message});
        try context.stderr.flush();
    } else {
        try output.writeWarning(context, message);
    }
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const shortcodes = @import("../cli/shortcodes.zig");

const two_updates_json =
    \\{"Devices":[
    \\  {"Name":"Thunderbolt Dock","DeviceId":"dock-id","Vendor":"Dell Inc.","Version":"20.00",
    \\   "Releases":[{"Version":"21.00","Summary":"Dock firmware"}]},
    \\  {"Name":"System Firmware","DeviceId":"uefi-id","Vendor":"LENOVO","Plugin":"uefi_capsule","Version":"0.1.48",
    \\   "Releases":[{"Version":"0.1.49","Size":1048576,"Urgency":"high","Summary":"BIOS update"}]}
    \\]}
;

/// Replays recorded fwupdmgr responses and records each argv and mode.
const Script = struct {
    const Response = struct {
        exit_code: ?u8 = 0,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
    };

    responses: []const Response,
    next: usize = 0,
    calls: std.ArrayList([]const u8) = .empty,
    modes: std.ArrayList(fwupd.Mode) = .empty,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator),

    fn deinit(self: *Script) void {
        self.arena.deinit();
    }

    fn environment(self: *Script, installed: bool) Environment {
        return .{
            .executable = if (installed) "/usr/bin/fwupdmgr" else null,
            .runner = .{ .context = self, .run_fn = run },
            .interactive_terminal = false,
        };
    }

    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, mode: fwupd.Mode) anyerror!fwupd.Output {
        const self: *Script = @ptrCast(@alignCast(context.?));
        const arena = self.arena.allocator();
        try self.calls.append(arena, try std.mem.join(arena, " ", argv[1..]));
        try self.modes.append(arena, mode);
        if (self.next >= self.responses.len) return error.UnexpectedCall;
        const response = self.responses[self.next];
        self.next += 1;
        return .{
            .exit_code = response.exit_code,
            .stdout = try allocator.dupe(u8, response.stdout),
            .stderr = try allocator.dupe(u8, response.stderr),
        };
    }

    /// Subcommand (first word) of every fwupdmgr call, in order.
    fn subcommands(self: *Script) ![]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        for (self.calls.items, 0..) |call, index| {
            if (index != 0) try joined.append(self.arena.allocator(), ',');
            const end = std.mem.indexOfScalar(u8, call, ' ') orelse call.len;
            try joined.appendSlice(self.arena.allocator(), call[0..end]);
        }
        return joined.items;
    }
};

fn parse(tc: *test_support.TestContext, arguments: []const []const u8) !parser.Invocation {
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const translation = try shortcodes.translate(tc.arena.allocator(), &manifest, arguments);
    const translated = translation.arguments() orelse return error.ShortcodeTranslationFailed;
    const manifest_copy = try tc.arena.allocator().create(spec.Manifest);
    manifest_copy.* = manifest;
    const outcome = try parser.parse(tc.arena.allocator(), manifest_copy, translated);
    if (outcome != .dispatch) return error.ParseFailed;
    return outcome.dispatch;
}

fn stdout(tc: *test_support.TestContext) []const u8 {
    return tc.stdout.writer.buffered();
}

/// Warnings follow the CLI convention of `warning: ...` lines on stderr.
fn stderr(tc: *test_support.TestContext) []const u8 {
    return tc.stderr.writer.buffered();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "firmware commands are registered with long names and shortcodes" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    try testing.expectEqualStrings(list_command_path, (try parse(&tc, &.{ "list-updates", "firmware" })).command.path);
    try testing.expectEqualStrings(list_command_path, (try parse(&tc, &.{"-Pw"})).command.path);
    try testing.expectEqualStrings(upgrade_command_path, (try parse(&tc, &.{ "upgrade", "firmware" })).command.path);
    try testing.expectEqualStrings(upgrade_command_path, (try parse(&tc, &.{"-Uw"})).command.path);

    // Other commands are left to their own dispatchers.
    var script: Script = .{ .responses = &.{} };
    defer script.deinit();
    const other = try parse(&tc, &.{ "list-updates", "flatpak" });
    try testing.expectEqual(@as(?u8, null), try dispatchWith(&tc.context, &other, script.environment(true)));
    try testing.expectEqual(@as(usize, 0), script.calls.items.len);
}

test "list firmware merges devices with available updates" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout =
        \\{"Devices":[
        \\  {"Name":"System Firmware","DeviceId":"uefi-id","Vendor":"LENOVO","Version":"0.1.48","Flags":["updatable"]},
        \\  {"Name":"NVMe SSD","DeviceId":"nvme-id","Vendor":"Samsung","Version":"3B2QGXA7","Flags":["updatable"]},
        \\  {"Name":"CPU","DeviceId":"cpu-id","Flags":["internal"]}
        \\]}
        },
        .{ .stdout = two_updates_json },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list", "firmware", "--json" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("get-devices,get-updates", try script.subcommands());

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, stdout(&tc), .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("0.1.49", items[0].object.get("UpdateVersion").?.string);
    try testing.expectEqualStrings("high", items[0].object.get("Urgency").?.string);
    try testing.expectEqualStrings("", items[1].object.get("UpdateVersion").?.string);
}

test "list firmware still lists devices when update metadata is unavailable" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout = "{\"Devices\":[{\"Name\":\"Disk\",\"DeviceId\":\"d\",\"Version\":\"1\",\"Flags\":[\"updatable\"]}]}" },
        .{ .exit_code = 1, .stderr = "no metadata" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list", "firmware" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try expectContains(stdout(&tc), "Disk");
    try expectContains(stdout(&tc), "Up to date");
}

test "list-updates firmware explains how to enable fwupd when it is missing" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list-updates", "firmware" });
    try testing.expectEqual(@as(?u8, 1), try dispatchWith(&tc.context, &invocation, script.environment(false)));
    try expectContains(stdout(&tc), "Install the fwupd package");
    try testing.expectEqual(@as(usize, 0), script.calls.items.len);
}

test "list-updates firmware renders a sorted table and total" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{.{ .stdout = two_updates_json }} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list-updates", "firmware" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));

    const rendered = stdout(&tc);
    const system = std.mem.indexOf(u8, rendered, "System Firmware") orelse return error.MissingSystem;
    const dock = std.mem.indexOf(u8, rendered, "Thunderbolt Dock") orelse return error.MissingDock;
    try testing.expect(system < dock);
    try expectContains(rendered, "0.1.49 (high)");
    try expectContains(rendered, "Firmware Total: 2 devices can be updated");
    // Listing does not refresh metadata unless asked to.
    try testing.expectEqualStrings("get-updates", try script.subcommands());
}

test "list-updates firmware --refresh refreshes first and survives a failed refresh" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .exit_code = 1, .stderr = "Failed to download: network unreachable" },
        .{ .exit_code = 2, .stdout = "No updatable devices" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list-updates", "firmware", "--refresh" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("refresh,get-updates", try script.subcommands());
    try expectContains(stderr(&tc), "warning: Could not refresh firmware metadata; using cached metadata instead. Failed to download: network unreachable");
    try expectContains(stdout(&tc), up_to_date_message);
}

test "list-updates firmware --json writes a stable array on stdout only" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{.{ .stdout = two_updates_json }} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list-updates", "firmware", "--json" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, stdout(&tc), .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("dock-id", items[0].object.get("DeviceId").?.string);
    try testing.expectEqualStrings("uefi-id", items[1].object.get("DeviceId").?.string);
    try testing.expectEqualStrings("uefi_capsule", items[1].object.get("Plugin").?.string);
    try testing.expectEqual(@as(i64, 1048576), items[1].object.get("DownloadSize").?.integer);
    try testing.expectEqualStrings("high", items[1].object.get("Urgency").?.string);
}

test "list-updates firmware --json reports failures on stderr" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{.{ .exit_code = 1, .stderr = "failed to connect to daemon" }} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "list-updates", "firmware", "--json" });
    try testing.expectEqual(@as(?u8, 1), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("", stdout(&tc));
    try expectContains(tc.stderr.writer.buffered(), "fwupd reported: failed to connect to daemon");
}

test "upgrade firmware is a no-op when everything is current" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{ .{ .exit_code = 2 }, .{ .exit_code = 2 } } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("refresh,get-updates", try script.subcommands());
    try expectContains(stdout(&tc), up_to_date_message);
}

test "upgrade firmware defaults to no at the confirmation prompt" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var input = std.Io.Reader.fixed("\n");
    tc.context.stdin = &input;
    var script: Script = .{ .responses = &.{ .{ .exit_code = 0 }, .{ .stdout = two_updates_json } } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try expectContains(stdout(&tc), "Install these firmware updates? (y/N)");
    try expectContains(stdout(&tc), "Operation cancelled.");
    // Nothing was flashed.
    try testing.expectEqualStrings("refresh,get-updates", try script.subcommands());
}

test "upgrade firmware without a terminal never installs" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{.{ .stdout = two_updates_json }} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--no-refresh" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("get-updates", try script.subcommands());
    try expectContains(stdout(&tc), "Operation cancelled.");
}

test "upgrade firmware installs the reviewed devices and reports a pending reboot" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var input = std.Io.Reader.fixed("maybe\ny\n");
    tc.context.stdin = &input;
    var script: Script = .{ .responses = &.{
        .{ .exit_code = 0 },
        .{ .stdout = two_updates_json },
        .{ .exit_code = 0 },
        .{ .stdout = "{\"Devices\":[{\"DeviceId\":\"uefi-id\",\"Flags\":[\"needs-reboot\"]}]}" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("refresh,get-updates,update,get-devices", try script.subcommands());

    const update_call = script.calls.items[2];
    try testing.expect(std.mem.endsWith(u8, update_call, " dock-id uefi-id"));
    try expectContains(update_call, "--assume-yes");
    try expectContains(update_call, "--no-reboot-check");
    // No terminal attached: output is captured rather than streamed.
    try testing.expectEqual(fwupd.Mode.capture, script.modes.items[2]);

    const rendered = stdout(&tc);
    try expectContains(rendered, "Please answer 'y' or 'n'.");
    try expectContains(rendered, "Keep the computer plugged in");
    try expectContains(rendered, "Firmware upgrade complete.");
    try expectContains(stderr(&tc), "warning: Restart the computer to finish installing the firmware updates.");
}

test "upgrade firmware --no-confirm streams fwupdmgr output on a terminal" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout = two_updates_json },
        .{ .exit_code = 0 },
        .{ .stdout = "{\"Devices\":[{\"Flags\":[\"needs-shutdown\"]}]}" },
    } };
    defer script.deinit();
    var environment = script.environment(true);
    environment.interactive_terminal = true;

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--no-refresh", "--no-confirm" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, environment));
    try testing.expectEqualStrings("get-updates,update,get-devices", try script.subcommands());
    try testing.expectEqual(fwupd.Mode.passthrough, script.modes.items[1]);
    try expectContains(stderr(&tc), "warning: Shut down the computer to finish installing the firmware updates.");
}

test "upgrade firmware reports fwupd's reason when flashing fails" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout = two_updates_json },
        .{ .exit_code = 1, .stderr = "System requires external power source" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--no-refresh", "--no-confirm" });
    try testing.expectEqual(@as(?u8, 1), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try expectContains(stdout(&tc), "Could not complete the firmware upgrade. fwupd reported: System requires external power source");
    try testing.expect(std.mem.indexOf(u8, stdout(&tc), "Firmware upgrade complete.") == null);
}

test "upgrade firmware still succeeds when restart flags cannot be read" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout = two_updates_json },
        .{ .exit_code = 0 },
        .{ .exit_code = 1, .stderr = "daemon restarted" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--no-refresh", "--no-confirm" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try expectContains(stdout(&tc), "Firmware upgrade complete.");
    // No restart hint is invented when the flags are unknown.
    try testing.expectEqualStrings("", stderr(&tc));
}

test "upgrade firmware from the Shelly UI requires the UI's confirmation" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--ui-mode" });
    try testing.expectEqual(@as(?u8, 1), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqual(@as(usize, 0), script.calls.items.len);
}

test "upgrade firmware from the Shelly UI reports each device as a frame" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{
        .{ .stdout = two_updates_json },
        .{ .exit_code = 0 },
        .{ .stdout = "{\"Devices\":[{\"Flags\":[\"needs-reboot\"]}]}" },
    } };
    defer script.deinit();

    const invocation = try parse(&tc, &.{ "upgrade", "firmware", "--ui-mode", "--no-confirm", "--no-refresh" });
    try testing.expectEqual(@as(?u8, 0), try dispatchWith(&tc.context, &invocation, script.environment(true)));
    try testing.expectEqualStrings("get-updates,update,get-devices", try script.subcommands());
    // Never stream fwupdmgr's own output into the frame protocol.
    try testing.expectEqual(fwupd.Mode.capture, script.modes.items[1]);

    // Decode every frame and check the per-device events the transaction
    // page keys its rows on.
    var installing: usize = 0;
    var upgraded: usize = 0;
    var restart_warning = false;
    var frames = std.mem.splitSequence(u8, stdout(&tc), "[JSON]");
    _ = frames.next();
    while (frames.next()) |chunk| {
        const end = std.mem.indexOf(u8, chunk, "[/JSON]") orelse continue;
        const decoder = std.base64.standard.Decoder;
        const json = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(chunk[0..end]));
        defer testing.allocator.free(json);
        try decoder.decode(json, chunk[0..end]);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const event = object.get("EventType").?.string;
        if (std.mem.eql(u8, event, "Installing")) installing += 1;
        if (std.mem.eql(u8, event, "PackageUpgraded")) {
            upgraded += 1;
            const name = object.get("PackageName").?.string;
            try testing.expect(std.mem.eql(u8, name, "Thunderbolt Dock") or std.mem.eql(u8, name, "System Firmware"));
        }
        if (std.mem.indexOf(u8, object.get("Message").?.string, "Restart the computer") != null) restart_warning = true;
    }
    try testing.expectEqual(@as(usize, 2), installing);
    try testing.expectEqual(@as(usize, 2), upgraded);
    try testing.expect(restart_warning);
}

test "upgrade firmware explains how to enable fwupd when it is missing" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var script: Script = .{ .responses = &.{} };
    defer script.deinit();

    const invocation = try parse(&tc, &.{"-Uw"});
    try testing.expectEqual(@as(?u8, 1), try dispatchWith(&tc.context, &invocation, script.environment(false)));
    try expectContains(stdout(&tc), "Install the fwupd package");
}
