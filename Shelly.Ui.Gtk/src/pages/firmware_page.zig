//! Firmware page: the devices fwupd can update, with their installed
//! version and any available update. Shown when firmware support is on.

const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const FirmwareDevice = @import("../models/sync.zig").FirmwareDevice;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const translations = @import("../helpers/translations.zig");
const firmware_install = @import("../helpers/firmware_install.zig");

pub const FirmwarePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Firmware";
    pub const icon_name: [:0]const u8 = "firmware-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/firmware_page.ui";

    const Private = struct {
        summary_label: *gtk.Label,
        refresh_button: *gtk.Button,
        update_button: *gtk.Button,
        stack: *gtk.Stack,
        loading_page: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        list_page: *gtk.ScrolledWindow,
        device_list: *gtk.ListBox,
        empty_page: *gtk.Box,
        error_page: *gtk.Box,
        /// Owns `devices` and the row strings.
        arena: ?*std.heap.ArenaAllocator,
        devices: []const FirmwareDevice,
        generation: u64,
        loaded: bool,
        var offset: c_int = 0;
    };

    const LoadResult = struct {
        page: *Self,
        generation: u64,
        arena: *std.heap.ArenaAllocator,
        devices: ?[]const FirmwareDevice,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFirmwarePage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.arena = null;
        p.devices = &.{};
        p.generation = 0;
        p.loaded = false;
        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        self.load(false);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        self.clear();
    }

    fn clear(self: *Self) void {
        const p = self.priv();
        // Results still in flight belong to an older view; drop them.
        p.generation += 1;
        gtk.ListBox.removeAll(p.device_list);
        p.devices = &.{};
        if (p.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            p.arena = null;
        }
    }

    fn load(self: *Self, refresh_metadata: bool) void {
        const p = self.priv();
        self.clear();
        gtk.Spinner.start(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.stack, p.loading_page.as(gtk.Widget));
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.update_button.as(gtk.Widget), 0);
        gtk.Label.setLabel(p.summary_label, translations._("Devices managed by fwupd"));

        const thread = std.Thread.spawn(.{}, worker, .{ self, p.generation, refresh_metadata }) catch {
            self.showError();
            return;
        };
        thread.detach();
    }

    fn worker(page: *Self, generation: u64, refresh_metadata: bool) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        if (refresh_metadata) cli.refresh_firmware_metadata();
        const devices: ?[]const FirmwareDevice = if (cli.list_firmware_devices()) |parsed| parsed.value else |_| null;

        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{ .page = page, .generation = generation, .arena = arena, .devices = devices };
        _ = glib.idleAdd(&onLoaded, result);
    }

    fn onLoaded(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(result);
        const page = result.page;
        const p = page.priv();

        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            return 0;
        }
        p.arena = result.arena;
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);

        const devices = result.devices orelse {
            page.showError();
            return 0;
        };
        p.devices = devices;
        if (devices.len == 0) {
            gtk.Stack.setVisibleChild(p.stack, p.empty_page.as(gtk.Widget));
            return 0;
        }

        const alloc = result.arena.allocator();
        var pending: usize = 0;
        for (devices) |device| {
            if (device.UpdateVersion.len != 0) pending += 1;
            gtk.ListBox.append(p.device_list, deviceRow(alloc, device) catch continue);
        }
        const noun = if (devices.len == 1) translations._("device") else translations._("devices");
        const summary = if (pending == 0)
            std.fmt.allocPrintSentinel(alloc, "{d} {s} · {s}", .{ devices.len, noun, translations._("all up to date") }, 0)
        else
            std.fmt.allocPrintSentinel(alloc, "{d} {s} · {d} {s}", .{ devices.len, noun, pending, translations._("with updates") }, 0);
        gtk.Label.setLabel(p.summary_label, summary catch translations._("Devices managed by fwupd"));
        gtk.Widget.setSensitive(p.update_button.as(gtk.Widget), @intFromBool(pending != 0));
        gtk.Stack.setVisibleChild(p.stack, p.list_page.as(gtk.Widget));
        return 0;
    }

    fn showError(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.stack, p.error_page.as(gtk.Widget));
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
        gtk.Widget.setSensitive(p.update_button.as(gtk.Widget), 0);
    }

    fn deviceRow(alloc: std.mem.Allocator, device: FirmwareDevice) !*gtk.Widget {
        const row = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginStart(row.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(row.as(gtk.Widget), 12);

        const text = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text.as(gtk.Widget), 1);
        const name = gtk.Label.new(try alloc.dupeSentinel(u8, device.Name, 0));
        gtk.Label.setXalign(name, 0);
        gtk.Widget.addCssClass(name.as(gtk.Widget), "heading");
        gtk.Box.append(text, name.as(gtk.Widget));
        const vendor = if (device.Vendor.len != 0) device.Vendor else translations._("Unknown vendor");
        const detail_text = if (device.Summary.len != 0)
            try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ vendor, device.Summary }, 0)
        else
            try alloc.dupeSentinel(u8, vendor, 0);
        const detail = gtk.Label.new(detail_text);
        gtk.Label.setXalign(detail, 0);
        gtk.Label.setWrap(detail, 1);
        gtk.Widget.addCssClass(detail.as(gtk.Widget), "dim-label");
        gtk.Box.append(text, detail.as(gtk.Widget));
        gtk.Box.append(row, text.as(gtk.Widget));

        const state = gtk.Box.new(.vertical, 2);
        gtk.Widget.setValign(state.as(gtk.Widget), .center);
        const version = gtk.Label.new(try alloc.dupeSentinel(u8, if (device.Version.len != 0) device.Version else "?", 0));
        gtk.Label.setXalign(version, 1);
        gtk.Box.append(state, version.as(gtk.Widget));
        const status_text = if (device.UpdateVersion.len == 0)
            translations._("Up to date")
        else if (device.Urgency.len != 0)
            try std.fmt.allocPrintSentinel(alloc, "{s} {s} ({s})", .{ translations._("Update to"), device.UpdateVersion, device.Urgency }, 0)
        else
            try std.fmt.allocPrintSentinel(alloc, "{s} {s}", .{ translations._("Update to"), device.UpdateVersion }, 0);
        const status = gtk.Label.new(status_text);
        gtk.Label.setXalign(status, 1);
        gtk.Widget.addCssClass(status.as(gtk.Widget), if (device.UpdateVersion.len == 0) "dim-label" else "heading");
        gtk.Box.append(state, status.as(gtk.Widget));
        gtk.Box.append(row, state.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn refresh_firmware(self: *Self) callconv(.c) void {
        self.load(true);
    }

    fn update_firmware(self: *Self) callconv(.c) void {
        const p = self.priv();
        const win = support.getWindow(ShellyWindow, self) orelse return;
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        for (p.devices) |device| {
            if (device.UpdateVersion.len != 0) names.append(std.heap.c_allocator, device.Name) catch return;
        }
        firmware_install.confirmAndInstall(win, names.items, &onInstallComplete, self);
    }

    fn onInstallComplete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = success;
        // Reload either way: a failed install may still have updated some
        // devices, and the list should show what fwupd reports now.
        if (self.priv().loaded) self.load(false);
    }

    const template_children = .{
        .{ "summary_label", @offsetOf(Private, "summary_label") },
        .{ "refresh_button", @offsetOf(Private, "refresh_button") },
        .{ "update_button", @offsetOf(Private, "update_button") },
        .{ "stack", @offsetOf(Private, "stack") },
        .{ "loading_page", @offsetOf(Private, "loading_page") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "list_page", @offsetOf(Private, "list_page") },
        .{ "device_list", @offsetOf(Private, "device_list") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
        .{ "error_page", @offsetOf(Private, "error_page") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |child| {
                support.bindChild(class, Private.offset, child[0], child[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "refresh_firmware", @ptrCast(&refresh_firmware));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "update_firmware", @ptrCast(&update_firmware));
        }
    };
};
