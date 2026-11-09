//! Optional firmware update support through fwupd.
//!
//! Shelly does not link against libfwupd. It drives the `fwupdmgr` command
//! line client in its documented `--json` mode, so fwupd stays an optional
//! runtime dependency: when `fwupdmgr` is not installed every entry point
//! reports `error.FwupdUnavailable` and callers stay quiet about firmware.
//!
//! All process execution goes through `Runner`, which lets tests replay
//! recorded fwupdmgr output without a daemon, hardware, or network access.

const std = @import("std");

/// Fixed install locations for `fwupdmgr`. Shelly may run elevated, so the
/// client is never resolved through `$PATH`, which the invoking user controls.
pub const default_executable_candidates = [_][]const u8{
    "/usr/bin/fwupdmgr",
    "/usr/local/bin/fwupdmgr",
};

/// fwupdmgr exit status for "the command ran but had nothing to do", for
/// example `get-updates` with no available updates or `refresh` with
/// metadata that is already current.
pub const exit_nothing_to_do: u8 = 2;

pub const Error = error{
    /// `fwupdmgr` is not installed in any of the trusted locations.
    FwupdUnavailable,
    /// `fwupdmgr` exited with a failure status or was terminated.
    FwupdCommandFailed,
    /// `fwupdmgr` printed output that is not the documented JSON shape.
    InvalidFwupdOutput,
    OutOfMemory,
};

/// How a command's standard streams are connected.
pub const Mode = enum {
    /// Capture stdout and stderr so they can be parsed or reported.
    capture,
    /// Inherit the caller's terminal so fwupdmgr can show its own progress.
    /// Returned stdout and stderr are empty.
    passthrough,
};

pub const Output = struct {
    /// Exit status, or null when the process was terminated by a signal.
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    fn succeeded(self: Output) bool {
        return self.exit_code != null and self.exit_code.? == 0;
    }

    fn nothingToDo(self: Output) bool {
        return self.exit_code != null and self.exit_code.? == exit_nothing_to_do;
    }
};

/// Process execution seam. Production code uses `SystemRunner`; tests use a
/// scripted runner that returns recorded output.
pub const Runner = struct {
    context: ?*anyopaque,
    run_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        mode: Mode,
    ) anyerror!Output,

    pub fn run(
        self: Runner,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        mode: Mode,
    ) anyerror!Output {
        return self.run_fn(self.context, allocator, argv, mode);
    }
};

/// Runs real processes through `std.process`.
pub const SystemRunner = struct {
    io: std.Io,

    /// Largest stdout or stderr accepted from fwupdmgr in capture mode.
    pub const max_output_bytes = 16 * 1024 * 1024;

    pub fn runner(self: *SystemRunner) Runner {
        return .{ .context = self, .run_fn = runErased };
    }

    fn runErased(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        mode: Mode,
    ) anyerror!Output {
        const self: *SystemRunner = @ptrCast(@alignCast(context.?));
        return switch (mode) {
            .capture => self.runCaptured(allocator, argv),
            .passthrough => self.runPassthrough(allocator, argv),
        };
    }

    fn runCaptured(
        self: *SystemRunner,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
    ) !Output {
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(max_output_bytes),
            .stderr_limit = .limited(max_output_bytes),
        });
        return .{
            .exit_code = exitCode(result.term),
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn runPassthrough(
        self: *SystemRunner,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
    ) !Output {
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(self.io);
        const term = try child.wait(self.io);
        return .{
            .exit_code = exitCode(term),
            .stdout = try allocator.alloc(u8, 0),
            .stderr = try allocator.alloc(u8, 0),
        };
    }

    fn exitCode(term: std.process.Child.Term) ?u8 {
        return switch (term) {
            .exited => |code| code,
            else => null,
        };
    }
};

/// Returns the first trusted `fwupdmgr` location that exists, or null when
/// fwupd is not installed.
pub fn findExecutable(io: std.Io, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// One device with a newer firmware release available.
pub const Update = struct {
    device_id: []const u8,
    name: []const u8,
    vendor: []const u8,
    plugin: []const u8,
    current_version: []const u8,
    new_version: []const u8,
    summary: []const u8,
    /// Release payload size in bytes, or 0 when fwupd does not report it.
    size: u64,
    /// fwupd urgency label ("low", "medium", "high", "critical"), or empty.
    urgency: []const u8,
};

/// Owned list of available updates. Every string lives in `arena`.
pub const UpdateList = struct {
    items: []const Update,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *UpdateList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Restart needed before installed firmware takes effect.
pub const PendingRestart = enum {
    none,
    reboot,
    shutdown,
};

pub const RefreshOutcome = enum {
    refreshed,
    already_current,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    runner: Runner,
    /// Absolute path to `fwupdmgr`, normally from `findExecutable`.
    executable: []const u8,
    /// Captured stderr of the most recent failed command, owned by the
    /// client. Callers include it in error reports.
    last_error: ?[]u8 = null,

    pub fn deinit(self: *Client) void {
        self.clearLastError();
        self.* = undefined;
    }

    /// Downloads current metadata from the enabled fwupd remotes.
    pub fn refresh(self: *Client) Error!RefreshOutcome {
        var output = try self.capture(&.{"refresh"});
        defer output.deinit(self.allocator);
        if (output.succeeded()) return .refreshed;
        if (output.nothingToDo()) return .already_current;
        return self.fail(output);
    }

    /// Lists devices with a newer firmware release in the cached metadata.
    pub fn getUpdates(self: *Client) Error!UpdateList {
        var output = try self.capture(&.{
            "get-updates",
            "--json",
            // Never prompt from a listing: these checks otherwise ask to
            // enable remotes, refresh metadata, or upload reports.
            "--no-unreported-check",
            "--no-metadata-check",
            "--no-remote-check",
        });
        defer output.deinit(self.allocator);
        if (output.nothingToDo()) return emptyList(self.allocator);
        if (!output.succeeded()) return self.fail(output);
        return parseUpdates(self.allocator, output.stdout);
    }

    /// Installs the newest release on the given devices, or on every
    /// updatable device when `device_ids` is empty. Shelly confirms before
    /// calling this, so fwupdmgr runs non-interactively and never reboots
    /// on its own; use `pendingRestart` afterwards to report what is needed.
    pub fn update(self: *Client, device_ids: []const []const u8, mode: Mode) Error!void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            self.executable,
            "update",
            "--assume-yes",
            "--no-reboot-check",
            "--no-unreported-check",
            "--no-metadata-check",
            "--no-remote-check",
        });
        try argv.appendSlice(self.allocator, device_ids);

        var output = try self.execute(argv.items, mode);
        defer output.deinit(self.allocator);
        if (output.succeeded() or output.nothingToDo()) return;
        return self.fail(output);
    }

    /// Reports whether any device is waiting for a reboot or shutdown to
    /// finish installing firmware. A shutdown requirement wins over reboot.
    pub fn pendingRestart(self: *Client) Error!PendingRestart {
        var output = try self.capture(&.{ "get-devices", "--json" });
        defer output.deinit(self.allocator);
        if (output.nothingToDo()) return .none;
        if (!output.succeeded()) return self.fail(output);
        return parsePendingRestart(self.allocator, output.stdout);
    }

    fn capture(self: *Client, arguments: []const []const u8) Error!Output {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.executable);
        try argv.appendSlice(self.allocator, arguments);
        return self.execute(argv.items, .capture);
    }

    fn execute(self: *Client, argv: []const []const u8, mode: Mode) Error!Output {
        self.clearLastError();
        return self.runner.run(self.allocator, argv, mode) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => error.FwupdUnavailable,
            else => error.FwupdCommandFailed,
        };
    }

    fn fail(self: *Client, output: Output) Error {
        // In --json mode fwupdmgr reports failures as an Error object on
        // stdout and leaves stderr empty; plain commands use stderr.
        const message = jsonErrorMessage(self.allocator, output.stdout) orelse
            self.allocator.dupe(u8, std.mem.trim(u8, output.stderr, " \t\r\n")) catch return error.OutOfMemory;
        if (message.len == 0) {
            self.allocator.free(message);
        } else {
            self.last_error = message;
        }
        return error.FwupdCommandFailed;
    }

    fn clearLastError(self: *Client) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
    }
};

fn emptyList(allocator: std.mem.Allocator) UpdateList {
    return .{ .items = &.{}, .arena = std.heap.ArenaAllocator.init(allocator) };
}

/// Parses `fwupdmgr get-updates --json`. Each device lists its releases
/// newest first; the first release is the one `fwupdmgr update` installs.
/// Devices without releases are skipped. Unknown fields are ignored so newer
/// fwupd versions keep working.
pub fn parseUpdates(allocator: std.mem.Allocator, json: []const u8) Error!UpdateList {
    var list = emptyList(allocator);
    errdefer list.deinit();
    const arena = list.arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFwupdOutput,
    };
    const devices = try devicesArray(parsed.value);

    var updates: std.ArrayList(Update) = .empty;
    for (devices) |device_value| {
        if (device_value != .object) return error.InvalidFwupdOutput;
        const device = device_value.object;
        const releases_value = device.get("Releases") orelse continue;
        if (releases_value != .array) return error.InvalidFwupdOutput;
        if (releases_value.array.items.len == 0) continue;
        const release_value = releases_value.array.items[0];
        if (release_value != .object) return error.InvalidFwupdOutput;
        const release = release_value.object;

        const device_id = string(device, "DeviceId");
        if (device_id.len == 0) return error.InvalidFwupdOutput;
        try updates.append(arena, .{
            .device_id = device_id,
            .name = firstNonEmpty(string(device, "Name"), device_id),
            .vendor = firstNonEmpty(string(device, "Vendor"), string(release, "Vendor")),
            .plugin = string(device, "Plugin"),
            .current_version = string(device, "Version"),
            .new_version = string(release, "Version"),
            .summary = firstNonEmpty(string(release, "Summary"), string(device, "Summary")),
            .size = unsigned(release, "Size"),
            .urgency = string(release, "Urgency"),
        });
    }
    list.items = try updates.toOwnedSlice(arena);
    return list;
}

/// Parses `fwupdmgr get-devices --json` for devices that still need a
/// restart to apply staged firmware.
pub fn parsePendingRestart(allocator: std.mem.Allocator, json: []const u8) Error!PendingRestart {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena_state.allocator(), json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFwupdOutput,
    };
    const devices = try devicesArray(parsed.value);

    var pending: PendingRestart = .none;
    for (devices) |device_value| {
        if (device_value != .object) return error.InvalidFwupdOutput;
        const flags = device_value.object.get("Flags") orelse continue;
        if (flags != .array) continue;
        for (flags.array.items) |flag| {
            if (flag != .string) continue;
            if (std.mem.eql(u8, flag.string, "needs-shutdown")) return .shutdown;
            if (std.mem.eql(u8, flag.string, "needs-reboot")) pending = .reboot;
        }
    }
    return pending;
}

/// Extracts `Error.Message` from fwupdmgr's JSON failure report, as an owned
/// copy, or returns null when `json` is not such a report.
fn jsonErrorMessage(allocator: std.mem.Allocator, json: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const report = parsed.value.object.get("Error") orelse return null;
    if (report != .object) return null;
    const message = string(report.object, "Message");
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn devicesArray(root: std.json.Value) Error![]const std.json.Value {
    if (root != .object) return error.InvalidFwupdOutput;
    const devices = root.object.get("Devices") orelse return &.{};
    if (devices != .array) return error.InvalidFwupdOutput;
    return devices.array.items;
}

fn string(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

fn unsigned(object: std.json.ObjectMap, key: []const u8) u64 {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch 0,
        else => 0,
    };
}

fn firstNonEmpty(preferred: []const u8, fallback: []const u8) []const u8 {
    return if (preferred.len != 0) preferred else fallback;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Abbreviated real `fwupdmgr get-updates --json` output: one UEFI capsule
/// device with two releases and one USB dock with a single release.
const sample_updates_json =
    \\{
    \\  "Devices" : [
    \\    {
    \\      "Name" : "System Firmware",
    \\      "DeviceId" : "a45df35ac0e948ee180fe216a5f703f32dda163f",
    \\      "Guid" : [ "230c8b18-8d9b-53ec-838b-6cfc0383493a" ],
    \\      "Plugin" : "uefi_capsule",
    \\      "Flags" : [ "internal", "updatable", "require-ac", "registered" ],
    \\      "Vendor" : "LENOVO",
    \\      "Version" : "0.1.48",
    \\      "VersionFormat" : "triplet",
    \\      "Releases" : [
    \\        {
    \\          "AppstreamId" : "com.lenovo.ThinkPadN2HET.firmware",
    \\          "Summary" : "Lenovo ThinkPad X1 Carbon 6th System Firmware",
    \\          "Version" : "0.1.49",
    \\          "Size" : 21307393,
    \\          "Urgency" : "high",
    \\          "Flags" : [ "is-upgrade" ]
    \\        },
    \\        {
    \\          "Summary" : "Older release",
    \\          "Version" : "0.1.47",
    \\          "Flags" : [ "is-downgrade" ]
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "Name" : "Thunderbolt Dock",
    \\      "DeviceId" : "6a4e3c12f8e0b1c37a1b3f1d0de0b3c2a1b0c9d8",
    \\      "Plugin" : "thunderbolt",
    \\      "Version" : "20.00",
    \\      "Releases" : [
    \\        {
    \\          "Vendor" : "Dell Inc.",
    \\          "Summary" : "Dock firmware",
    \\          "Version" : "21.00",
    \\          "NewField" : { "ignored" : true }
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "Name" : "No releases",
    \\      "DeviceId" : "ffff",
    \\      "Releases" : [ ]
    \\    }
    \\  ]
    \\}
;

test "parseUpdates takes the newest release for each device" {
    var list = try parseUpdates(testing.allocator, sample_updates_json);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 2), list.items.len);

    const system = list.items[0];
    try testing.expectEqualStrings("a45df35ac0e948ee180fe216a5f703f32dda163f", system.device_id);
    try testing.expectEqualStrings("System Firmware", system.name);
    try testing.expectEqualStrings("LENOVO", system.vendor);
    try testing.expectEqualStrings("uefi_capsule", system.plugin);
    try testing.expectEqualStrings("0.1.48", system.current_version);
    try testing.expectEqualStrings("0.1.49", system.new_version);
    try testing.expectEqualStrings("Lenovo ThinkPad X1 Carbon 6th System Firmware", system.summary);
    try testing.expectEqual(@as(u64, 21307393), system.size);
    try testing.expectEqualStrings("high", system.urgency);

    const dock = list.items[1];
    try testing.expectEqualStrings("Thunderbolt Dock", dock.name);
    // Falls back to the release vendor when the device has none.
    try testing.expectEqualStrings("Dell Inc.", dock.vendor);
    try testing.expectEqualStrings("21.00", dock.new_version);
    try testing.expectEqual(@as(u64, 0), dock.size);
    try testing.expectEqualStrings("", dock.urgency);
}

test "parseUpdates accepts output without a Devices member" {
    var list = try parseUpdates(testing.allocator, "{}");
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "parseUpdates uses the device id when a device has no name" {
    var list = try parseUpdates(testing.allocator,
        \\{"Devices":[{"DeviceId":"abc","Releases":[{"Version":"2"}]}]}
    );
    defer list.deinit();
    try testing.expectEqualStrings("abc", list.items[0].name);
}

test "parseUpdates rejects malformed output" {
    const cases = [_][]const u8{
        "",
        "not json",
        "[]",
        "{\"Devices\":{}}",
        "{\"Devices\":[1]}",
        "{\"Devices\":[{\"DeviceId\":\"a\",\"Releases\":{}}]}",
        // A device with a release but no id cannot be updated selectively.
        "{\"Devices\":[{\"Name\":\"x\",\"Releases\":[{\"Version\":\"1\"}]}]}",
    };
    for (cases) |json| {
        try testing.expectError(error.InvalidFwupdOutput, parseUpdates(testing.allocator, json));
    }
}

test "parsePendingRestart reports the strongest pending requirement" {
    try testing.expectEqual(PendingRestart.none, try parsePendingRestart(testing.allocator,
        \\{"Devices":[{"DeviceId":"a","Flags":["updatable"]},{"DeviceId":"b"}]}
    ));
    try testing.expectEqual(PendingRestart.reboot, try parsePendingRestart(testing.allocator,
        \\{"Devices":[{"DeviceId":"a","Flags":["updatable","needs-reboot"]}]}
    ));
    try testing.expectEqual(PendingRestart.shutdown, try parsePendingRestart(testing.allocator,
        \\{"Devices":[{"Flags":["needs-reboot"]},{"Flags":["needs-shutdown"]}]}
    ));
    try testing.expectError(error.InvalidFwupdOutput, parsePendingRestart(testing.allocator, "{\"Devices\":5}"));
}

/// Replays one recorded response per call and records every argv it saw.
const ScriptedRunner = struct {
    const Response = struct {
        exit_code: ?u8 = 0,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        err: ?anyerror = null,
    };

    responses: []const Response,
    next: usize = 0,
    calls: std.ArrayList([]const []const u8) = .empty,
    modes: std.ArrayList(Mode) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(responses: []const Response) ScriptedRunner {
        return .{ .responses = responses, .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *ScriptedRunner) void {
        self.arena.deinit();
    }

    fn runner(self: *ScriptedRunner) Runner {
        return .{ .context = self, .run_fn = run };
    }

    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, mode: Mode) anyerror!Output {
        const self: *ScriptedRunner = @ptrCast(@alignCast(context.?));
        const arena = self.arena.allocator();
        const copy = try arena.alloc([]const u8, argv.len);
        for (argv, copy) |argument, *slot| slot.* = try arena.dupe(u8, argument);
        try self.calls.append(arena, copy);
        try self.modes.append(arena, mode);

        if (self.next >= self.responses.len) return error.UnexpectedCall;
        const response = self.responses[self.next];
        self.next += 1;
        if (response.err) |err| return err;
        return .{
            .exit_code = response.exit_code,
            .stdout = try allocator.dupe(u8, response.stdout),
            .stderr = try allocator.dupe(u8, response.stderr),
        };
    }
};

fn testClient(script: *ScriptedRunner) Client {
    return .{ .allocator = testing.allocator, .runner = script.runner(), .executable = "/usr/bin/fwupdmgr" };
}

test "getUpdates runs fwupdmgr non-interactively and parses the result" {
    var script = ScriptedRunner.init(&.{.{ .stdout = sample_updates_json }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    var list = try client.getUpdates();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.items.len);

    const argv = script.calls.items[0];
    try testing.expectEqualStrings("/usr/bin/fwupdmgr", argv[0]);
    try testing.expectEqualStrings("get-updates", argv[1]);
    try testing.expectEqualStrings("--json", argv[2]);
    for ([_][]const u8{ "--no-unreported-check", "--no-metadata-check", "--no-remote-check" }) |flag| {
        try testing.expect(contains(argv, flag));
    }
    try testing.expectEqual(Mode.capture, script.modes.items[0]);
}

test "getUpdates treats the nothing-to-do status as no updates" {
    // fwupdmgr prints a human-readable message, not JSON, in this case.
    var script = ScriptedRunner.init(&.{.{ .exit_code = 2, .stdout = "No updatable devices\n" }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    var list = try client.getUpdates();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "getUpdates keeps stderr from a failed command" {
    var script = ScriptedRunner.init(&.{.{ .exit_code = 1, .stderr = "  failed to connect to daemon\n" }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expectEqualStrings("failed to connect to daemon", client.last_error.?);
}

test "getUpdates reads the error report fwupdmgr prints in JSON mode" {
    // Recorded from fwupd 1.9 with no running daemon: exit 1, empty stderr.
    var script = ScriptedRunner.init(&.{.{ .exit_code = 1, .stdout =
        \\{
        \\  "Error" : {
        \\    "Domain" : "g-io-error-quark",
        \\    "Code" : 1,
        \\    "Message" : "Failed to connect to daemon: Could not connect: No such file or directory"
        \\  }
        \\}
        \\
    }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expectEqualStrings(
        "Failed to connect to daemon: Could not connect: No such file or directory",
        client.last_error.?,
    );
}

test "a JSON error report wins over stderr, and non-report stdout is ignored" {
    var script = ScriptedRunner.init(&.{
        .{ .exit_code = 1, .stdout = "{\"Error\":{\"Message\":\"from json\"}}", .stderr = "from stderr" },
        .{ .exit_code = 1, .stdout = "{\"Devices\":[]}", .stderr = "from stderr" },
        .{ .exit_code = 1, .stdout = "{\"Error\":{\"Message\":\"  \"}}", .stderr = "" },
    });
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expectEqualStrings("from json", client.last_error.?);
    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expectEqualStrings("from stderr", client.last_error.?);
    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expect(client.last_error == null);
}

test "a terminated fwupdmgr is a failure, not an empty result" {
    var script = ScriptedRunner.init(&.{.{ .exit_code = null }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();
    try testing.expectError(error.FwupdCommandFailed, client.getUpdates());
    try testing.expect(client.last_error == null);
}

test "a missing executable maps to FwupdUnavailable" {
    var script = ScriptedRunner.init(&.{.{ .err = error.FileNotFound }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();
    try testing.expectError(error.FwupdUnavailable, client.getUpdates());
}

test "refresh distinguishes new metadata from metadata that is already current" {
    var script = ScriptedRunner.init(&.{
        .{ .exit_code = 0 },
        .{ .exit_code = 2 },
        .{ .exit_code = 1, .stderr = "network unreachable" },
    });
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try testing.expectEqual(RefreshOutcome.refreshed, try client.refresh());
    try testing.expectEqual(RefreshOutcome.already_current, try client.refresh());
    try testing.expectError(error.FwupdCommandFailed, client.refresh());
    try testing.expectEqualStrings("network unreachable", client.last_error.?);
    try testing.expectEqualStrings("refresh", script.calls.items[0][1]);
}

test "update never lets fwupdmgr prompt or reboot and targets the given devices" {
    var script = ScriptedRunner.init(&.{ .{ .exit_code = 0 }, .{ .exit_code = 2 } });
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try client.update(&.{ "dev-a", "dev-b" }, .passthrough);
    const argv = script.calls.items[0];
    try testing.expectEqualStrings("update", argv[1]);
    try testing.expect(contains(argv, "--assume-yes"));
    try testing.expect(contains(argv, "--no-reboot-check"));
    try testing.expectEqualStrings("dev-a", argv[argv.len - 2]);
    try testing.expectEqualStrings("dev-b", argv[argv.len - 1]);
    try testing.expectEqual(Mode.passthrough, script.modes.items[0]);

    // Nothing to install is not an error.
    try client.update(&.{}, .capture);
    try testing.expectEqualStrings("--no-remote-check", script.calls.items[1][script.calls.items[1].len - 1]);
}

test "update failures are reported" {
    var script = ScriptedRunner.init(&.{.{ .exit_code = 1, .stderr = "Device requires AC power" }});
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();
    try testing.expectError(error.FwupdCommandFailed, client.update(&.{}, .capture));
    try testing.expectEqualStrings("Device requires AC power", client.last_error.?);
}

test "pendingRestart queries device flags" {
    var script = ScriptedRunner.init(&.{
        .{ .stdout = "{\"Devices\":[{\"Flags\":[\"needs-reboot\"]}]}" },
        .{ .exit_code = 2 },
    });
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();

    try testing.expectEqual(PendingRestart.reboot, try client.pendingRestart());
    try testing.expectEqual(PendingRestart.none, try client.pendingRestart());
    try testing.expectEqualStrings("get-devices", script.calls.items[0][1]);
}

test "a successful command clears the previous error" {
    var script = ScriptedRunner.init(&.{
        .{ .exit_code = 1, .stderr = "first failure" },
        .{ .exit_code = 0 },
    });
    defer script.deinit();
    var client = testClient(&script);
    defer client.deinit();
    try testing.expectError(error.FwupdCommandFailed, client.refresh());
    _ = try client.refresh();
    try testing.expect(client.last_error == null);
}

test "findExecutable returns the first existing candidate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fwupdmgr", .data = "" });
    const present = try tmp.dir.realPathFileAlloc(testing.io, "fwupdmgr", testing.allocator);
    defer testing.allocator.free(present);

    const candidates = [_][]const u8{ "/definitely/missing/fwupdmgr", present };
    try testing.expectEqualStrings(present, findExecutable(testing.io, &candidates).?);
    try testing.expect(findExecutable(testing.io, &.{"/definitely/missing/fwupdmgr"}) == null);
}

test "SystemRunner drives a real fwupdmgr-compatible executable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stands in for fwupdmgr: echoes JSON for get-updates, reports nothing
    // to do for refresh, and fails anything else with a message on stderr.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fwupdmgr", .data =
        \\#!/bin/sh
        \\case "$1" in
        \\  get-updates) printf '{"Devices":[{"DeviceId":"d1","Name":"Disk","Version":"1","Releases":[{"Version":"2"}]}]}' ;;
        \\  refresh) exit 2 ;;
        \\  *) echo "unsupported: $1" >&2; exit 1 ;;
        \\esac
        \\
    });
    const executable = try tmp.dir.realPathFileAlloc(testing.io, "fwupdmgr", testing.allocator);
    defer testing.allocator.free(executable);
    const chmod = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "/bin/chmod", "0755", executable } });
    testing.allocator.free(chmod.stdout);
    testing.allocator.free(chmod.stderr);

    var system: SystemRunner = .{ .io = testing.io };
    var client: Client = .{ .allocator = testing.allocator, .runner = system.runner(), .executable = executable };
    defer client.deinit();

    var list = try client.getUpdates();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("Disk", list.items[0].name);
    try testing.expectEqualStrings("2", list.items[0].new_version);

    try testing.expectEqual(RefreshOutcome.already_current, try client.refresh());
    try testing.expectError(error.FwupdCommandFailed, client.pendingRestart());
    try testing.expectEqualStrings("unsupported: get-devices", client.last_error.?);
}

test "SystemRunner reports a missing executable as FwupdUnavailable" {
    var system: SystemRunner = .{ .io = testing.io };
    var client: Client = .{ .allocator = testing.allocator, .runner = system.runner(), .executable = "/definitely/missing/fwupdmgr" };
    defer client.deinit();
    try testing.expectError(error.FwupdUnavailable, client.getUpdates());
}

fn contains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |argument| {
        if (std.mem.eql(u8, argument, needle)) return true;
    }
    return false;
}
