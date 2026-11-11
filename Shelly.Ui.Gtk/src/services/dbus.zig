const std = @import("std");
const diagnostics = @import("diagnostics");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const gobject = bindings.gobject;
const glib = bindings.glib;

const TrayPath: [:0]const u8 = "/org/shellyorg/Notifications";
const TrayInterface: [:0]const u8 = "com.shellyorg.shelly";

const POLKIT_NAME: [:0]const u8 = "org.freedesktop.PolicyKit1";
const POLKIT_AUTH_PATH: [:0]const u8 = "/org/freedesktop/PolicyKit1/Authority";
const POLKIT_AUTH_IFACE: [:0]const u8 = "org.freedesktop.PolicyKit1.Authority";
const PROBE_PATH: [:0]const u8 = "/org/shelly/AuthAgentProbe";

const LOGIND_NAME: [:0]const u8 = "org.freedesktop.login1";
const LOGIND_PATH: [:0]const u8 = "/org/freedesktop/login1";
const LOGIND_MANAGER_IFACE: [:0]const u8 = "org.freedesktop.login1.Manager";

const polkit_check = @import("polkit_check.zig");

pub const DBus = struct {
    connection: ?*gio.DBusConnection = null,
    system_connection: ?*gio.DBusConnection = null,

    pub fn deinit(self: *DBus) void {
        if (self.connection) |c| c.unref();
        if (self.system_connection) |c| c.unref();
    }

    pub fn updatesMadeInUi(self: *DBus) void {
        self.emitTray("Refresh");
    }

    fn ensureBus(self: *DBus, slot: *?*gio.DBusConnection, bus: gio.BusType) ?*gio.DBusConnection {
        _ = self;
        if (slot.*) |conn| return conn;
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(bus, null, &err);
        if (err) |e| {
            std.log.warn("Could not connect to the selected D-Bus session. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
            return null;
        }
        slot.* = conn;
        return conn;
    }

    fn ensureConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.connection, .session);
    }

    fn ensureSystemConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.system_connection, .system);
    }

    fn emitTray(self: *DBus, signal: [:0]const u8) void {
        const conn = self.ensureConnection() orelse return;
        var err: ?*glib.Error = null;
        _ = gio.DBusConnection.emitSignal(
            conn,
            null,
            TrayPath,
            TrayInterface,
            signal,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("Could not send the tray settings signal over D-Bus. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
        }
    }

    /// Probes polkitd and, when it is available, the session's
    /// authentication agent. See `polkit_check` for how to interpret it.
    pub fn probePolkit(self: *DBus) polkit_check.Probe {
        const daemon = self.polkitDaemonPresence();
        return switch (daemon) {
            .running, .started => .{ .daemon = daemon, .agent = self.authAgentPresent() },
            .absent, .unknown => .{ .daemon = daemon },
        };
    }

    pub fn polkitAvailable(self: *DBus) bool {
        return switch (self.polkitDaemonPresence()) {
            .running, .started => true,
            .absent, .unknown => false,
        };
    }

    /// polkitd is D-Bus activated, so it may not own its name until
    /// something talks to it. Ask the bus to start it, as any polkit client
    /// would implicitly, instead of only checking for a current owner.
    fn polkitDaemonPresence(self: *DBus) polkit_check.Daemon {
        const conn = self.ensureSystemConnection() orelse return .unknown;
        const params = glib.Variant.new("(su)", POLKIT_NAME.ptr, @as(u32, 0));
        const reply_type = glib.VariantType.new("(u)");
        defer reply_type.free();
        var call_err: ?*glib.Error = null;
        const result = conn.callSync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "StartServiceByName",
            params,
            reply_type,
            .{},
            -1,
            null,
            &call_err,
        );
        if (call_err) |e| {
            defer glib.Error.free(e);
            const remote = gio.DBusError.getRemoteError(e);
            defer if (remote) |name| glib.free(name);
            const error_name: []const u8 = if (remote) |name| std.mem.span(name) else "";
            const daemon = polkit_check.daemonFromStartService(null, error_name);
            if (daemon == .unknown)
                std.log.info("Could not check whether the authorization service is running. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            return daemon;
        }
        const res = result orelse return .unknown;
        defer res.unref();
        const child = res.getChildValue(0);
        defer child.unref();
        const reply = child.getUint32();
        std.log.debug("StartServiceByName(PolicyKit1) = {d}", .{reply});
        return polkit_check.daemonFromStartService(reply, null);
    }

    fn authAgentPresent(self: *DBus) polkit_check.Agent {
        const conn = self.ensureSystemConnection() orelse return .unknown;

        var sid_buf: [64]u8 = undefined;
        const sid = self.currentSessionId(&sid_buf) orelse {
            std.log.info("Could not identify the login session; the authorization-agent check was skipped.", .{});
            return .unknown;
        };

        const subject = buildUnixSessionSubject(sid) orelse return .unknown;

        const params = glib.Variant.new(
            "(@(sa{sv})ss)",
            subject,
            "en_US.UTF-8",
            PROBE_PATH.ptr,
        );

        var err: ?*glib.Error = null;
        const result = conn.callSync(
            POLKIT_NAME,
            POLKIT_AUTH_PATH,
            POLKIT_AUTH_IFACE,
            "RegisterAuthenticationAgent",
            params,
            null,
            .{},
            -1,
            null,
            &err,
        );

        if (err) |e| {
            defer glib.Error.free(e);
            const msg: []const u8 = if (e.f_message) |m| std.mem.span(m) else "";
            if (std.mem.indexOf(u8, msg, "already exists") != null) return .present;
            std.log.debug("polkit agent probe inconclusive: {s}", .{msg});
            return .unknown;
        }

        if (result) |r| r.unref();
        self.unregisterProbeAgent(sid);
        return .absent;
    }

    fn unregisterProbeAgent(self: *DBus, sid: []const u8) void {
        const conn = self.ensureSystemConnection() orelse return;
        const subject = buildUnixSessionSubject(sid) orelse return;
        const params = glib.Variant.new("(@(sa{sv})s)", subject, PROBE_PATH.ptr);
        var err: ?*glib.Error = null;
        const r = conn.callSync(
            POLKIT_NAME,
            POLKIT_AUTH_PATH,
            POLKIT_AUTH_IFACE,
            "UnregisterAuthenticationAgent",
            params,
            null,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("Could not unregister the temporary authorization-agent probe. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
        }
        if (r) |res| res.unref();
    }

    fn buildUnixSessionSubject(sid: []const u8) ?*glib.Variant {
        const vt = glib.VariantType.new("a{sv}");
        defer vt.free();

        const builder = glib.VariantBuilder.new(vt);
        builder.add("{sv}", "session-id", glib.Variant.new("s", sid.ptr));
        const dict = builder.end();
        _ = &builder;

        return glib.Variant.new("(s@a{sv})", "unix-session", dict);
    }

    fn currentSessionId(self: *DBus, buf: []u8) ?[]const u8 {
        if (std.c.getenv("XDG_SESSION_ID")) |env_ptr| {
            const env = std.mem.span(env_ptr);
            if (env.len > 0 and env.len < buf.len) {
                @memcpy(buf[0..env.len], env);
                buf[env.len] = 0;
                return buf[0..env.len :0];
            }
        }
        return self.sessionIdFromLogind(buf);
    }

    fn sessionIdFromLogind(self: *DBus, buf: []u8) ?[]const u8 {
        const conn = self.ensureSystemConnection() orelse return null;
        const pid: u32 = @intCast(std.os.linux.getpid());

        const params = glib.Variant.new("(u)", pid);
        const reply_type = glib.VariantType.new("(o)");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        const result = conn.callSync(
            LOGIND_NAME,
            LOGIND_PATH,
            LOGIND_MANAGER_IFACE,
            "GetSessionByPID",
            params,
            reply_type,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.info("Could not identify the login session through logind. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
            return null;
        }
        const res = result orelse return null;
        defer res.unref();

        const path_v = res.getChildValue(0);
        defer path_v.unref();

        var len: usize = 0;
        const path_c = path_v.getString(&len);
        const session_path = path_c[0..len];

        return self.sessionIdProperty(session_path, buf);
    }

    fn sessionIdProperty(self: *DBus, session_path: []const u8, buf: []u8) ?[]const u8 {
        const conn = self.ensureSystemConnection() orelse return null;

        var path_buf: [256]u8 = undefined;
        if (session_path.len >= path_buf.len) return null;
        @memcpy(path_buf[0..session_path.len], session_path);
        path_buf[session_path.len] = 0;
        const path_z = path_buf[0..session_path.len :0];

        const params = glib.Variant.new(
            "(ss)",
            "org.freedesktop.login1.Session",
            "Id",
        );
        const reply_type = glib.VariantType.new("(v)");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        const result = conn.callSync(
            LOGIND_NAME,
            path_z,
            "org.freedesktop.DBus.Properties",
            "Get",
            params,
            reply_type,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("Could not identify the login session through logind. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
            return null;
        }
        const res = result orelse return null;
        defer res.unref();

        const variant = res.getChildValue(0);
        defer variant.unref();
        const inner = variant.getVariant();
        defer inner.unref();

        var len: usize = 0;
        const id_c = inner.getString(&len);
        if (len == 0 or len >= buf.len) return null;
        @memcpy(buf[0..len], id_c[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }
};
