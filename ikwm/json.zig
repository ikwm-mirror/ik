const std = @import("std");
const swc = @import("swc");
const panthera = @import("panthera");
const ipc = @import("ipc.zig");
const query = @import("query.zig");
const w = @import("wm.zig");
const sub = @import("subscriber.zig");
const findMode = @import("keybind.zig").findMode;

// --- Builders ---

pub fn clientToJson(cl: *w.Client) query.ClientJson {
    const node = cl.bsp_node;
    return .{
        .pid = swc.swc_window_get_pid(cl.win),
        .workspace = cl.ws,
        .floating = cl.floating,
        .fullscreen = cl.fullscreen,
        .decor_enabled = cl.decor_enabled,
        .focused = w.wm.sel_client == cl,
        .x = if (node) |n| n.x else cl.fx,
        .y = if (node) |n| n.y else cl.fy,
        .w = if (node) |n| n.w else cl.fw,
        .h = if (node) |n| n.h else cl.fh,
        .name = w.procName(cl),
    };
}

pub fn buildFocusedJson(_: std.mem.Allocator) !query.FocusedJson {
    const cl = w.wm.sel_client orelse return .{
        .pid = -1,
        .workspace = 0,
        .floating = false,
        .fullscreen = false,
        .decor_enabled = false,
        .focused = false,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .name = "",
        .none = true,
    };
    const j = clientToJson(cl);
    return .{
        .pid = j.pid,
        .workspace = j.workspace,
        .floating = j.floating,
        .fullscreen = j.fullscreen,
        .decor_enabled = j.decor_enabled,
        .focused = j.focused,
        .x = j.x,
        .y = j.y,
        .w = j.w,
        .h = j.h,
        .name = j.name,
        .none = false,
    };
}

pub fn buildWorkspacesJson(a: std.mem.Allocator) !query.WorkspacesJson {
    var list: std.ArrayListUnmanaged(query.WorkspaceJson) = .empty;
    var i: u32 = 0;
    while (i < w.wm.cfg.workspace_count) : (i += 1) {
        const head = w.wsClients(i);
        var count: u32 = 0;
        var it: ?*swc.struct_wl_list = head.next;
        while (it != head) : (it = it.?.next) count += 1;
        try list.append(a, .{
            .index = i + 1,
            .focused = (i + 1 == w.wm.ws),
            .client_count = count,
        });
    }
    return .{
        .workspaces = try list.toOwnedSlice(a),
        .current = w.wm.ws,
        .count = w.wm.cfg.workspace_count,
    };
}

pub fn buildClientsJson(a: std.mem.Allocator, scope: ipc.ClientScope) !query.ClientsJson {
    var list: std.ArrayListUnmanaged(query.ClientJson) = .empty;
    switch (scope) {
        .current => {
            const head = w.wsClients(w.wm.ws - 1);
            var it: ?*swc.struct_wl_list = head.next;
            while (it != head) : (it = it.?.next) {
                const cl: *w.Client = @fieldParentPtr("ws_link", it.?);
                try list.append(a, clientToJson(cl));
            }
            return .{ .clients = try list.toOwnedSlice(a), .workspace = w.wm.ws };
        },
        .all => {
            var it: ?*swc.struct_wl_list = w.wm.clients.next;
            while (it != &w.wm.clients) : (it = it.?.next) {
                const cl: *w.Client = @fieldParentPtr("link", it.?);
                try list.append(a, clientToJson(cl));
            }
            return .{ .clients = try list.toOwnedSlice(a), .workspace = 0 };
        },
    }
}

pub fn buildModeJson(a: std.mem.Allocator) !query.ModeJson {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (w.wm.modes[0..w.wm.mode_count]) |*m| {
        try names.append(a, m.name[0..m.name_len]);
    }
    return .{
        .current = w.wm.modes[w.wm.mode_idx].name[0..w.wm.modes[w.wm.mode_idx].name_len],
        .all = try names.toOwnedSlice(a),
    };
}

pub fn buildConfigJson() query.ConfigJson {
    return .{
        .border_width = w.wm.cfg.border_width,
        .border_outer_width = w.wm.cfg.border_outer_width,
        .border_color_active = w.wm.cfg.border_color_active,
        .border_color_normal = w.wm.cfg.border_color_normal,
        .border_outer_color_active = w.wm.cfg.border_outer_color_active,
        .border_outer_color_normal = w.wm.cfg.border_outer_color_normal,
        .wallpaper_color = w.wm.cfg.wallpaper_color,
        .gap_inner = w.wm.cfg.gap_inner,
        .gap_outer = w.wm.cfg.gap_outer,
        .motion_throttle_hz = w.wm.cfg.motion_throttle_hz,
        .decor_default = w.wm.cfg.decor_default,
        .workspace_count = w.wm.cfg.workspace_count,
    };
}

pub fn buildStatusJson(a: std.mem.Allocator) !query.StatusJson {
    return .{
        .workspaces = try buildWorkspacesJson(a),
        .focused = try buildFocusedJson(a),
        .clients = (try buildClientsJson(a, .all)).clients,
        .mode = w.wm.modes[w.wm.mode_idx].name[0..w.wm.modes[w.wm.mode_idx].name_len],
    };
}

// --- Notify ---

pub fn notify(evt_mask: u32) void {
    if (w.wm.subscribers.head == null) return;

    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var wr: std.Io.Writer = .fixed(&buf);

    if (evt_mask & sub.EVT_WORKSPACE != 0) {
        const payload = buildWorkspacesJson(a) catch return;
        const env = query.EventEnvelope(query.WorkspacesJson){ .event = "workspace_change", .data = payload };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        w.wm.subscribers.emit(sub.EVT_WORKSPACE, wr.buffered());
        wr = .fixed(&buf);
    }
    if (evt_mask & sub.EVT_FOCUS != 0) {
        const payload = buildFocusedJson(a) catch return;
        const env = query.EventEnvelope(query.FocusedJson){ .event = "focus_change", .data = payload };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        w.wm.subscribers.emit(sub.EVT_FOCUS, wr.buffered());
        wr = .fixed(&buf);
    }
    if (evt_mask & sub.EVT_CLIENT != 0) {
        const payload = buildClientsJson(a, .all) catch return;
        const env = query.EventEnvelope(query.ClientsJson){ .event = "client_change", .data = payload };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        w.wm.subscribers.emit(sub.EVT_CLIENT, wr.buffered());
        wr = .fixed(&buf);
    }
    if (evt_mask & sub.EVT_MODE != 0) {
        const payload = buildModeJson(a) catch return;
        const env = query.EventEnvelope(query.ModeJson){ .event = "mode_change", .data = payload };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        w.wm.subscribers.emit(sub.EVT_MODE, wr.buffered());
        wr = .fixed(&buf);
    }
    if (evt_mask & sub.EVT_CONFIG != 0) {
        const payload = buildConfigJson();
        const env = query.EventEnvelope(query.ConfigJson){ .event = "config_change", .data = payload };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        w.wm.subscribers.emit(sub.EVT_CONFIG, wr.buffered());
    }
}

pub fn sendInitialSnapshot(fd: c_int, mask: u32) void {
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var wr: std.Io.Writer = .fixed(&buf);

    if (mask & sub.EVT_WORKSPACE != 0) {
        const j = buildWorkspacesJson(a) catch return;
        const env = query.EventEnvelope(query.WorkspacesJson){ .event = "workspace_change", .data = j };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        _ = swc.write(fd, wr.buffered().ptr, wr.buffered().len);
        wr = .fixed(&buf);
    }
    if (mask & sub.EVT_FOCUS != 0) {
        const j = buildFocusedJson(a) catch return;
        const env = query.EventEnvelope(query.FocusedJson){ .event = "focus_change", .data = j };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        _ = swc.write(fd, wr.buffered().ptr, wr.buffered().len);
        wr = .fixed(&buf);
    }
    if (mask & sub.EVT_CLIENT != 0) {
        const j = buildClientsJson(a, .all) catch return;
        const env = query.EventEnvelope(query.ClientsJson){ .event = "client_change", .data = j };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        _ = swc.write(fd, wr.buffered().ptr, wr.buffered().len);
        wr = .fixed(&buf);
    }
    if (mask & sub.EVT_MODE != 0) {
        const j = buildModeJson(a) catch return;
        const env = query.EventEnvelope(query.ModeJson){ .event = "mode_change", .data = j };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        _ = swc.write(fd, wr.buffered().ptr, wr.buffered().len);
        wr = .fixed(&buf);
    }
    if (mask & sub.EVT_CONFIG != 0) {
        const j = buildConfigJson();
        const env = query.EventEnvelope(query.ConfigJson){ .event = "config_change", .data = j };
        panthera.stringify(env, .{}, &wr) catch return;
        _ = wr.writeByte('\n') catch {};
        _ = swc.write(fd, wr.buffered().ptr, wr.buffered().len);
    }
}

// --- Query dispatch ---

const BindJson = struct { mode: []const u8, mods: u32, sym: u32, command: []const u8 };

pub fn writeBindsJson(mode_name: []const u8, wr: *std.Io.Writer) !void {
    const mode_idx = findMode(mode_name) orelse return;
    const m = &w.wm.modes[mode_idx];

    var list: [256]BindJson = undefined;
    var count: usize = 0;

    var it: ?*swc.struct_wl_list = m.binds.next;
    while (it != &m.binds and count < list.len) : (it = it.?.next) {
        const b: *w.Bind = @fieldParentPtr("link", it.?);
        list[count] = .{
            .mode = m.name[0..m.name_len],
            .mods = b.mods,
            .sym = b.sym,
            .command = b.command,
        };
        count += 1;
    }
    try panthera.stringify(list[0..count], .{}, wr);
}

pub fn dispatchQuery(cmd: ipc.QueryCmd, fd: c_int) void {
    if (fd < 0) return;

    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var wr: std.Io.Writer = .fixed(&buf);

    switch (cmd) {
        .focused => {
            const j = buildFocusedJson(a) catch return;
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .workspaces => {
            const j = buildWorkspacesJson(a) catch return;
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .clients => |scope| {
            const j = buildClientsJson(a, scope) catch return;
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .mode => {
            const j = buildModeJson(a) catch return;
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .config => {
            const j = buildConfigJson();
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .status => {
            const j = buildStatusJson(a) catch return;
            panthera.stringify(j, .{}, &wr) catch return;
        },
        .binds => |name| {
            writeBindsJson(name, &wr) catch return;
        },
    }

    _ = wr.writeByte('\n') catch {};
    const out = wr.buffered();
    _ = swc.write(fd, out.ptr, out.len);
}
