const std = @import("std");
const panthera = @import("panthera");
const swc = @import("swc");

// --- Response structs ---

pub const WorkspaceJson = struct {
    index: u32,
    focused: bool,
    client_count: u32,
};

pub const ClientJson = struct {
    pid: i32,
    workspace: u32,
    floating: bool,
    fullscreen: bool,
    decor_enabled: bool,
    focused: bool,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    name: []const u8,
};

pub const FocusedJson = struct {
    pid: i32,
    workspace: u32,
    floating: bool,
    fullscreen: bool,
    decor_enabled: bool,
    focused: bool,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    name: []const u8,
    none: bool,
};

pub const ModeJson = struct {
    current: []const u8,
    all: [][]const u8,
};

pub const BindJson = struct {
    mode: []const u8,
    mods: u32,
    sym: u32,
    command: []const u8,
};

pub const WorkspacesJson = struct {
    workspaces: []WorkspaceJson,
    current: u32,
    count: u32,
};

pub const ClientsJson = struct {
    clients: []ClientJson,
    workspace: u32,
};

pub const StatusJson = struct {
    workspaces: WorkspacesJson,
    focused: FocusedJson,
    clients: []ClientJson,
    mode: []const u8,
};

pub const ConfigJson = struct {
    border_width: u32,
    border_outer_width: u32,
    border_color_active: u32,
    border_color_normal: u32,
    border_outer_color_active: u32,
    border_outer_color_normal: u32,
    wallpaper_color: u32,
    gap_inner: u32,
    gap_outer: u32,
    motion_throttle_hz: u32,
    decor_default: bool,
    workspace_count: u32,
};

// --- Event envelope ---

pub const EventKind = enum {
    workspace_change,
    focus_change,
    client_add,
    client_remove,
    mode_change,
    config_change,
    status,
};

pub fn EventEnvelope(comptime T: type) type {
    return struct {
        event: []const u8,
        data: T,
    };
}

// --- Writer helpers ---

pub fn writeJson(comptime T: type, value: T, fd: c_int) void {
    if (fd < 0) return;
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    panthera.stringify(value, .{}, &w) catch return;
    _ = writeNewline(&w);
    const out = w.buffered();
    _ = swc.write(fd, out.ptr, out.len);
}

fn writeNewline(w: *std.Io.Writer) bool {
    w.writeByte('\n') catch return false;
    return true;
}

pub fn writeJsonAlloc(comptime T: type, value: T, alloc: std.mem.Allocator) ?[]u8 {
    var list = std.ArrayList(u8).init(alloc);
    var w = list.writer();
    var iow: std.Io.Writer = .{ .context = &w, .writeFn = arrayListWriteFn };
    panthera.stringify(value, .{}, &iow) catch {
        list.deinit();
        return null;
    };
    list.append('\n') catch {
        list.deinit();
        return null;
    };
    return list.toOwnedSlice() catch null;
}

fn arrayListWriteFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
    const list: *std.ArrayList(u8).Writer = @ptrCast(@alignCast(ctx));
    try list.writeAll(bytes);
    return bytes.len;
}
