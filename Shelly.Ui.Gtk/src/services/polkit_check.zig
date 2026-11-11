//! Decides whether to warn that polkit is unusable, from one probe of the
//! system bus.
//!
//! Two things make a single, immediate probe unreliable:
//!
//! - polkitd is D-Bus activated. It runs only after something first talks to
//!   it, so "not on the bus right now" does not mean "not installed". The
//!   probe asks the bus to start it instead of only checking for an owner.
//! - Authentication agents register asynchronously, at login or as soon as
//!   polkitd appears. A probe that runs a moment too early sees no agent, so
//!   a missing agent is checked again before Shelly warns.
//!
//! Anything inconclusive never produces a warning: a false "polkit is
//! required" lockout is worse than a missing one, because privileged actions
//! report their own errors anyway.

const std = @import("std");

pub const Daemon = enum {
    /// polkitd already owned its bus name.
    running,
    /// polkitd was not running and the bus just started it.
    started,
    /// No polkitd is installed or activatable on the system bus.
    absent,
    /// The system bus could not answer.
    unknown,
};

pub const Agent = enum { present, absent, unknown };

pub const Probe = struct {
    daemon: Daemon,
    /// Only meaningful when the daemon is running or was just started.
    agent: Agent = .unknown,
};

pub const Step = union(enum) {
    /// polkit is usable, or the result was inconclusive: do not warn.
    ok,
    /// Warn that polkit itself is missing.
    no_daemon,
    /// Warn that no authentication agent is running in this session.
    no_agent,
    /// No agent yet. Probe again after this many milliseconds.
    retry_after_ms: u32,
};

/// Delays before each re-check of a missing agent, about 5 seconds in total.
/// Each probe briefly registers a placeholder agent, so they stay few.
pub const agent_retry_delays_ms = [_]u32{ 1500, 3500 };

/// `attempt` counts earlier probes in this check, starting at 0.
pub fn decide(probe: Probe, attempt: usize) Step {
    switch (probe.daemon) {
        .absent => return .no_daemon,
        .unknown => return .ok,
        .running, .started => {},
    }
    return switch (probe.agent) {
        .present, .unknown => .ok,
        .absent => if (attempt < agent_retry_delays_ms.len)
            .{ .retry_after_ms = agent_retry_delays_ms[attempt] }
        else
            .no_agent,
    };
}

/// Maps a `StartServiceByName` result to a daemon state. `reply` is the
/// method's return code; `error_name` is the D-Bus error name when the call
/// failed.
pub fn daemonFromStartService(reply: ?u32, error_name: ?[]const u8) Daemon {
    if (error_name) |name| {
        // Raised when no service file provides the name: polkit is not
        // installed (or not activatable) on this system.
        if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown")) return .absent;
        return .unknown;
    }
    return switch (reply orelse return .unknown) {
        1 => .started, // DBUS_START_REPLY_SUCCESS
        2 => .running, // DBUS_START_REPLY_ALREADY_RUNNING
        else => .unknown,
    };
}

const testing = std.testing;

test "a running daemon with an agent is fine" {
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .running, .agent = .present }, 0));
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .started, .agent = .present }, 0));
}

test "a missing daemon warns immediately" {
    try testing.expectEqual(Step.no_daemon, decide(.{ .daemon = .absent }, 0));
}

test "inconclusive probes never warn" {
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .unknown }, 0));
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .running, .agent = .unknown }, 0));
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .started, .agent = .unknown }, 5));
}

test "a missing agent is re-checked before warning" {
    const probe: Probe = .{ .daemon = .started, .agent = .absent };
    try testing.expectEqual(Step{ .retry_after_ms = 1500 }, decide(probe, 0));
    try testing.expectEqual(Step{ .retry_after_ms = 3500 }, decide(probe, 1));
    try testing.expectEqual(Step.no_agent, decide(probe, 2));
}

test "an agent that registers during the grace period clears the warning" {
    try testing.expectEqual(Step{ .retry_after_ms = 1500 }, decide(.{ .daemon = .started, .agent = .absent }, 0));
    try testing.expectEqual(Step.ok, decide(.{ .daemon = .running, .agent = .present }, 1));
}

test "StartServiceByName replies map to daemon states" {
    try testing.expectEqual(Daemon.started, daemonFromStartService(1, null));
    try testing.expectEqual(Daemon.running, daemonFromStartService(2, null));
    try testing.expectEqual(Daemon.unknown, daemonFromStartService(7, null));
    try testing.expectEqual(Daemon.unknown, daemonFromStartService(null, null));
    try testing.expectEqual(Daemon.absent, daemonFromStartService(null, "org.freedesktop.DBus.Error.ServiceUnknown"));
    // Activation failures (polkitd installed but crashing, timeouts, policy
    // denials) are not proof that polkit is missing.
    try testing.expectEqual(Daemon.unknown, daemonFromStartService(null, "org.freedesktop.DBus.Error.Spawn.ChildExited"));
    try testing.expectEqual(Daemon.unknown, daemonFromStartService(null, "org.freedesktop.DBus.Error.NoReply"));
}
