const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const ipc = @import("ipc.zig");
const query = @import("query.zig");
const sub = @import("subscriber.zig");
const panthera = @import("panthera");

// --- State ---

pub const Screen = struct {
    scr: *swc.swc_screen,
    link: swc.struct_wl_list,
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Client = struct {
    win: *swc.swc_window,
    scr: ?*Screen,
    link: swc.struct_wl_list,
    ws_link: swc.struct_wl_list,
    ws: u32 = 1,
    floating: bool = false,
    fullscreen: bool = false,
    mapped: bool = true,
    decor_enabled: bool = true,

    fx: i32 = 0,
    fy: i32 = 0,
    fw: u32 = 0,
    fh: u32 = 0,

    bsp_node: ?*bsp.Node = null,

    decor: swc.swc_decor = std.mem.zeroes(swc.swc_decor),
    proc_name: [256]u8 = std.mem.zeroes([256]u8),
    proc_name_len: usize = 0,
};

pub const Config = struct {
    border_width: u32 = 2,
    border_outer_width: u32 = 1,
    border_color_active: u32 = 0xffb48ead,
    border_color_normal: u32 = 0xff3d3d56,
    border_outer_color_active: u32 = 0xff6c6f85,
    border_outer_color_normal: u32 = 0xff1e1e2e,
    wallpaper_color: u32 = 0xff1e1e2e,
    gap_inner: u32 = 8,
    gap_outer: u32 = 8,
    motion_throttle_hz: u32 = 60,
    decor_default: bool = true,
    workspace_count: u32 = 9,
};

pub const Grab = struct {
    active: bool = false,
    resize: bool = false,
    c: ?*Client = null,
};

// --- Keybinds ---

const MAX_MODES = 32;
const MODE_NAME_MAX = 64;

const Bind = struct {
    mods: u32,
    sym: u32,
    command: []u8,
    mode_idx: usize,
    link: swc.struct_wl_list,
};

const Mode = struct {
    name: [MODE_NAME_MAX]u8 = std.mem.zeroes([MODE_NAME_MAX]u8),
    name_len: usize = 0,
    binds: swc.struct_wl_list = undefined,
};

// --- Workspace ---

const Workspace = struct {
    tree: bsp.Tree,
    focused_node: ?*bsp.Node = null,
    clients: swc.struct_wl_list = undefined,

    fn init(alloc: std.mem.Allocator) Workspace {
        var ws = Workspace{ .tree = bsp.Tree.init(alloc) };
        swc.wl_list_init(&ws.clients);
        return ws;
    }

    fn deinit(self: *Workspace) void {
        self.tree.deinit();
    }
};

pub const Wm = struct {
    dpy: *swc.wl_display,
    ev_loop: *swc.wl_event_loop,
    screens: swc.struct_wl_list,
    clients: swc.struct_wl_list,
    sel_client: ?*Client,
    sel_screen: ?*Screen,
    grab: Grab,
    ws: u32,
    workspaces: [10]Workspace,
    cfg: Config,

    ipc_server_fd: std.posix.socket_t = -1,
    ipc_source: ?*swc.wl_event_source = null,
    ipc_path: [256:0]u8 = std.mem.zeroes([256:0]u8),

    retile_pending: bool = false,
    retile_idle: ?*swc.wl_event_source = null,

    modes: [MAX_MODES]Mode,
    mode_count: usize,
    mode_idx: usize,

    subscribers: sub.Registry,
};

// --- Globals ---

var wm: Wm = undefined;
var gpa: std.mem.Allocator = undefined;
var io: *const std.Io = undefined;

var window_handler: swc.swc_window_handler = .{
    .destroy = onWinDestroy,
    .entered = onWinEntered,
};

var screen_handler: swc.swc_screen_handler = .{
    .destroy = onScreenDestroy,
};

// --- Helpers ---

fn curWs() *Workspace {
    return &wm.workspaces[wm.ws - 1];
}

fn wsClients(ws_idx: usize) *swc.struct_wl_list {
    return &wm.workspaces[ws_idx].clients;
}

fn firstWsClient(ws: u32) ?*Client {
    const head = wsClients(ws - 1);
    if (swc.wl_list_empty(head) != 0) return null;
    const next_ptr: *swc.struct_wl_list = @ptrCast(head.next.?);
    return @fieldParentPtr("ws_link", next_ptr);
}

fn isWsClient(cl: *const Client, ws: u32) bool {
    return cl.ws == ws;
}

// --- Cache Names ---

fn procName(cl: *Client) []const u8 {
    if (cl.proc_name_len > 0) return cl.proc_name[0..cl.proc_name_len];
    const pid = swc.swc_window_get_pid(cl.win);
    if (pid <= 0) return &.{};
    var path_buf: [64:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch return &.{};
    const fd = swc.open(&path_buf, swc.O_RDONLY, @as(c_int, 0));
    if (fd < 0) return &.{};
    defer _ = swc.close(fd);
    const n = swc.read(fd, &cl.proc_name, cl.proc_name.len - 1);
    if (n <= 0) return &.{};
    var len: usize = @intCast(n);
    while (len > 0 and cl.proc_name[len - 1] == '\n') len -= 1;
    cl.proc_name[len] = 0;
    cl.proc_name_len = len;
    return cl.proc_name[0..len];
}

// --- Decor ---

fn applyDecor(cl: *Client, active: bool) void {
    if (cl.fullscreen or !cl.decor_enabled) {
        swc.swc_window_set_decor(cl.win, null);
        return;
    }
    const pid = swc.swc_window_get_pid(cl.win);
    if (pid <= 0) {
        swc.swc_window_set_decor(cl.win, null);
        return;
    }
    cl.decor = std.mem.zeroes(swc.swc_decor);
    cl.decor.color = 0xff232136;
    cl.decor.top = 22;
    cl.decor.title.enabled = false;
    const name = procName(cl);
    if (name.len > 0) {
        cl.decor.title.string = @ptrCast(&cl.proc_name);
        cl.decor.title.enabled = true;
        cl.decor.title.color = if (active) 0xffffffff else 0xffc0c0c0;
        cl.decor.title.edge = swc.SWC_DECOR_EDGE_TOP;
        cl.decor.title.@"align" = swc.SWC_DECOR_ALIGN_CENTER;
    }
    swc.swc_window_set_decor(cl.win, &cl.decor);
}

fn setDecorFocused(enabled: bool) void {
    const cl = wm.sel_client orelse return;
    if (cl.decor_enabled == enabled) return;
    cl.decor_enabled = enabled;
    applyDecor(cl, true);
    scheduleRetile();
}

// --- Borders ---

fn setBorder(cl: *Client, active: bool) void {
    const cfg = &wm.cfg;
    swc.swc_window_set_border(
        cl.win,
        if (active) cfg.border_color_active else cfg.border_color_normal,
        cfg.border_width,
        if (active) cfg.border_outer_color_active else cfg.border_outer_color_normal,
        cfg.border_outer_width,
    );
}

fn focus(cl: ?*Client) void {
    if (wm.sel_client) |prev| setBorder(prev, false);
    if (cl) |next| {
        setBorder(next, true);
        swc.swc_window_focus(next.win);
        if (next.bsp_node) |n| curWs().focused_node = n;
    } else {
        swc.swc_window_focus(null);
    }
    wm.sel_client = cl;
    notify(sub.EVT_FOCUS);
}

// --- Retile ---

fn scheduleRetile() void {
    if (wm.retile_pending) return;
    wm.retile_pending = true;
    if (wm.retile_idle == null) {
        wm.retile_idle = swc.wl_event_loop_add_idle(wm.ev_loop, doRetileIdle, null);
    }
}

fn doRetileIdle(_: ?*anyopaque) callconv(.c) void {
    wm.retile_idle = null;
    wm.retile_pending = false;
    retile(null);
}

fn retile(ws_idx: ?usize) void {
    const ws = if (ws_idx) |wid| &wm.workspaces[wid] else curWs();
    const scr = wm.sel_screen orelse return;
    ws.tree.layout(
        scr.scr.geometry.x,
        scr.scr.geometry.y,
        scr.scr.geometry.width,
        scr.scr.geometry.height,
        wm.cfg.gap_inner,
        wm.cfg.gap_outer,
        &tileCallback,
    );
}

fn tileCallback(client: *anyopaque, x: i32, y: i32, w: u32, h: u32) void {
    const cl: *Client = @ptrCast(@alignCast(client));
    swc.swc_window_set_geometry(cl.win, &.{ .x = x, .y = y, .width = w, .height = h });
}

fn syncWindowVisibility() void {
    var it: ?*swc.struct_wl_list = wm.clients.next;
    while (it != &wm.clients) : (it = it.?.next) {
        const cl: *Client = @fieldParentPtr("link", it.?);
        if (cl.ws == wm.ws) swc.swc_window_show(cl.win) else swc.swc_window_hide(cl.win);
    }
}

// --- Notify / Follow ---

fn notify(evt_mask: u32) void {
    if (wm.subscribers.head == null) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    if (evt_mask & sub.EVT_WORKSPACE != 0) {
        const payload = buildWorkspacesJson(a) catch return;
        const env = query.EventEnvelope(query.WorkspacesJson){ .event = "workspace_change", .data = payload };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        wm.subscribers.emit(sub.EVT_WORKSPACE, w.buffered());
        w = .fixed(&buf);
    }

    if (evt_mask & sub.EVT_FOCUS != 0) {
        const payload = buildFocusedJson(a) catch return;
        const env = query.EventEnvelope(query.FocusedJson){ .event = "focus_change", .data = payload };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        wm.subscribers.emit(sub.EVT_FOCUS, w.buffered());
        w = .fixed(&buf);
    }

    if (evt_mask & sub.EVT_CLIENT != 0) {
        const payload = buildClientsJson(a, .all) catch return;
        const env = query.EventEnvelope(query.ClientsJson){ .event = "client_change", .data = payload };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        wm.subscribers.emit(sub.EVT_CLIENT, w.buffered());
        w = .fixed(&buf);
    }

    if (evt_mask & sub.EVT_MODE != 0) {
        const payload = buildModeJson(a) catch return;
        const env = query.EventEnvelope(query.ModeJson){ .event = "mode_change", .data = payload };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        wm.subscribers.emit(sub.EVT_MODE, w.buffered());
        w = .fixed(&buf);
    }

    if (evt_mask & sub.EVT_CONFIG != 0) {
        const payload = buildConfigJson();
        const env = query.EventEnvelope(query.ConfigJson){ .event = "config_change", .data = payload };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        wm.subscribers.emit(sub.EVT_CONFIG, w.buffered());
    }
}

// TODO: Split all of this into separate files

// --- JSON ---

fn clientToJson(cl: *Client) query.ClientJson {
    const node = cl.bsp_node;
    return .{
        .pid = swc.swc_window_get_pid(cl.win),
        .workspace = cl.ws,
        .floating = cl.floating,
        .fullscreen = cl.fullscreen,
        .decor_enabled = cl.decor_enabled,
        .focused = wm.sel_client == cl,
        .x = if (node) |n| n.x else cl.fx,
        .y = if (node) |n| n.y else cl.fy,
        .w = if (node) |n| n.w else cl.fw,
        .h = if (node) |n| n.h else cl.fh,
        .name = procName(cl),
    };
}

fn buildFocusedJson(_: std.mem.Allocator) !query.FocusedJson {
    const cl = wm.sel_client orelse return .{
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

fn buildWorkspacesJson(a: std.mem.Allocator) !query.WorkspacesJson {
    var list: std.ArrayListUnmanaged(query.WorkspaceJson) = .empty;
    var i: u32 = 0;
    while (i < wm.cfg.workspace_count) : (i += 1) {
        const head = wsClients(i);
        var count: u32 = 0;
        var it: ?*swc.struct_wl_list = head.next;
        while (it != head) : (it = it.?.next) count += 1;
        try list.append(a, .{
            .index = i + 1,
            .focused = (i + 1 == wm.ws),
            .client_count = count,
        });
    }
    return .{
        .workspaces = try list.toOwnedSlice(a),
        .current = wm.ws,
        .count = wm.cfg.workspace_count,
    };
}

fn buildClientsJson(a: std.mem.Allocator, scope: ipc.ClientScope) !query.ClientsJson {
    var list: std.ArrayListUnmanaged(query.ClientJson) = .empty;
    switch (scope) {
        .current => return .{ .clients = try list.toOwnedSlice(a), .workspace = wm.ws },
        .all => return .{ .clients = try list.toOwnedSlice(a), .workspace = 0 },
    }
}

fn buildModeJson(a: std.mem.Allocator) !query.ModeJson {
    var names: std.ArrayList([]const u8) = .empty;
    for (wm.modes[0..wm.mode_count]) |*m| {
        try names.append(a, m.name[0..m.name_len]);
    }
    return .{
        .current = wm.modes[wm.mode_idx].name[0..wm.modes[wm.mode_idx].name_len],
        .all = try names.toOwnedSlice(a),
    };
}

fn buildConfigJson() query.ConfigJson {
    return .{
        .border_width = wm.cfg.border_width,
        .border_outer_width = wm.cfg.border_outer_width,
        .border_color_active = wm.cfg.border_color_active,
        .border_color_normal = wm.cfg.border_color_normal,
        .border_outer_color_active = wm.cfg.border_outer_color_active,
        .border_outer_color_normal = wm.cfg.border_outer_color_normal,
        .wallpaper_color = wm.cfg.wallpaper_color,
        .gap_inner = wm.cfg.gap_inner,
        .gap_outer = wm.cfg.gap_outer,
        .motion_throttle_hz = wm.cfg.motion_throttle_hz,
        .decor_default = wm.cfg.decor_default,
        .workspace_count = wm.cfg.workspace_count,
    };
}

fn buildStatusJson(a: std.mem.Allocator) !query.StatusJson {
    return .{
        .workspaces = try buildWorkspacesJson(a),
        .focused = try buildFocusedJson(a),
        .clients = (try buildClientsJson(a, .all)).clients,
        .mode = wm.modes[wm.mode_idx].name[0..wm.modes[wm.mode_idx].name_len],
    };
}

// --- Query Dispatch ---

fn dispatchQuery(cmd: ipc.QueryCmd, fd: c_int) void {
    if (fd < 0) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    switch (cmd) {
        .focused => {
            const j = buildFocusedJson(a) catch return;
            panthera.stringify(j, .{}, &w) catch return;
        },
        .workspaces => {
            const j = buildWorkspacesJson(a) catch return;
            panthera.stringify(j, .{}, &w) catch return;
        },
        .clients => |scope| {
            const j = buildClientsJson(a, scope) catch return;
            panthera.stringify(j, .{}, &w) catch return;
        },
        .mode => {
            const j = buildModeJson(a) catch return;
            panthera.stringify(j, .{}, &w) catch return;
        },
        .config => {
            const j = buildConfigJson();
            panthera.stringify(j, .{}, &w) catch return;
        },
        .status => {
            const j = buildStatusJson(a) catch return;
            panthera.stringify(j, .{}, &w) catch return;
        },
        .binds => |name| {
            writeBindsJson(name, &w) catch return;
        },
    }

    _ = w.writeByte('\n') catch {};
    const out = w.buffered();
    _ = swc.write(fd, out.ptr, out.len);
}

const BindJson = struct { mode: []const u8, mods: u32, sym: u32, command: []const u8 };

fn writeBindsJson(mode_name: []const u8, w: *std.Io.Writer) !void {
    const mode_idx = findMode(mode_name) orelse return;
    const m = &wm.modes[mode_idx];

    var list: [256]BindJson = undefined;
    var count: usize = 0;

    var it: ?*swc.struct_wl_list = m.binds.next;
    while (it != &m.binds and count < list.len) : (it = it.?.next) {
        const b: *Bind = @fieldParentPtr("link", it.?);
        list[count] = .{
            .mode = m.name[0..m.name_len],
            .mods = b.mods,
            .sym = b.sym,
            .command = b.command,
        };
        count += 1;
    }

    try panthera.stringify(list[0..count], .{}, w);
}

// --- Keybind (Modal) ---

fn modeName(m: *const Mode) []const u8 {
    return m.name[0..m.name_len];
}

fn findMode(name: []const u8) ?usize {
    for (wm.modes[0..wm.mode_count], 0..) |*m, i| {
        if (std.mem.eql(u8, modeName(m), name)) return i;
    }
    return null;
}

fn defineMode(name: []const u8) !usize {
    if (findMode(name)) |i| return i;
    if (wm.mode_count >= MAX_MODES) return error.OutOfMemory;
    const idx = wm.mode_count;
    wm.mode_count += 1;
    const m = &wm.modes[idx];
    m.* = .{};
    const copy_len = @min(name.len, MODE_NAME_MAX - 1);
    @memcpy(m.name[0..copy_len], name[0..copy_len]);
    m.name_len = copy_len;
    swc.wl_list_init(&m.binds);
    return idx;
}

fn onKeyFire(data: ?*anyopaque, _: u32, _: u32, state: u32) callconv(.c) void {
    if (state != 1) return;
    const bind: *Bind = @ptrCast(@alignCast(data orelse return));
    if (bind.mode_idx != wm.mode_idx) return;
    const cmd = ipc.parse(bind.command) catch return;
    dispatchCmd(cmd, -1);
}

fn registerBind(bind: *Bind) void {
    _ = swc.swc_add_binding(
        swc.SWC_BINDING_KEY,
        bind.mods,
        bind.sym,
        onKeyFire,
        bind,
    );
}

fn activateMode(idx: usize) void {
    wm.mode_idx = idx;
    notify(sub.EVT_MODE);
}

fn addBind(def: ipc.BindDef) void {
    const mode_idx = defineMode(def.mode) catch return;
    const m = &wm.modes[mode_idx];

    var it: ?*swc.struct_wl_list = m.binds.next;
    while (it != &m.binds) : (it = it.?.next) {
        const b: *Bind = @fieldParentPtr("link", it.?);
        if (b.mods == def.key.mods and b.sym == def.key.sym) {
            gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            gpa.destroy(b);
            break;
        }
    }

    const bind = gpa.create(Bind) catch return;
    bind.* = .{
        .mods = def.key.mods,
        .sym = def.key.sym,
        .command = gpa.dupe(u8, def.command) catch {
            gpa.destroy(bind);
            return;
        },
        .mode_idx = mode_idx,
        .link = undefined,
    };
    swc.wl_list_insert(&m.binds, &bind.link);
    registerBind(bind); // always register; handler gates on mode_idx
}

fn destroyMode(idx: usize) void {
    if (idx == 0) return;
    const m = &wm.modes[idx];
    if (wm.mode_idx == idx) activateMode(0);
    while (swc.wl_list_empty(&m.binds) == 0) {
        const next_ptr: *swc.struct_wl_list = @ptrCast(m.binds.next.?);
        const b: *Bind = @fieldParentPtr("link", next_ptr);
        gpa.free(b.command);
        swc.wl_list_remove(&b.link);
        gpa.destroy(b);
    }
    var i = idx;
    while (i + 1 < wm.mode_count) : (i += 1) wm.modes[i] = wm.modes[i + 1];
    wm.mode_count -= 1;
    if (wm.mode_idx > idx) wm.mode_idx -= 1;
}

fn freeAllModes() void {
    for (wm.modes[0..wm.mode_count]) |*m| {
        while (swc.wl_list_empty(&m.binds) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(m.binds.next.?);
            const b: *Bind = @fieldParentPtr("link", next_ptr);
            gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            gpa.destroy(b);
        }
    }
}

// --- Hardware ---

pub fn newScreen(scr: ?*swc.swc_screen) callconv(.c) void {
    const s: *Screen = gpa.create(Screen) catch @panic("OOM");
    s.* = .{ .scr = scr orelse @panic("null screen"), .link = undefined };
    swc.wl_list_insert(&wm.screens, &s.link);
    if (wm.sel_screen == null) wm.sel_screen = s;
    swc.swc_screen_set_handler(scr, &screen_handler, s);
}

fn onScreenDestroy(data: ?*anyopaque) callconv(.c) void {
    const s: *Screen = @ptrCast(@alignCast(data orelse return));
    swc.wl_list_remove(&s.link);
    if (wm.sel_screen == s) {
        wm.sel_screen = if (swc.wl_list_empty(&wm.screens) != 0) null else @fieldParentPtr("link", @as(*swc.struct_wl_list, @ptrCast(wm.screens.next)));
    }
    gpa.destroy(s);
}

pub fn newDevice(_: ?*swc.struct_libinput_device) callconv(.c) void {}

pub const manager: swc.swc_manager = .{
    .new_screen = newScreen,
    .new_window = newWindow,
    .new_device = newDevice,
    .activate = onActivate,
    .deactivate = onDeactivate,
};

pub fn onActivate() callconv(.c) void {}
pub fn onDeactivate() callconv(.c) void {}

// --- Window ---

pub fn newWindow(win: ?*swc.swc_window) callconv(.c) void {
    const w = win orelse return;
    const cl: *Client = gpa.create(Client) catch @panic("OOM");
    cl.* = .{
        .win = w,
        .scr = wm.sel_screen,
        .link = undefined,
        .ws_link = undefined,
        .ws = wm.ws,
        .decor_enabled = wm.cfg.decor_default,
    };
    w.motion_throttle_ms = 1000 / wm.cfg.motion_throttle_hz;
    w.min_width = 1;
    w.min_height = 1;
    w.max_width = 0;
    w.max_height = 0;

    const ws = curWs();
    const leaf = ws.tree.insert(cl, ws.focused_node) catch @panic("OOM");
    cl.bsp_node = leaf;
    ws.focused_node = leaf;

    swc.wl_list_insert(&wm.clients, &cl.link);
    swc.wl_list_insert(wsClients(wm.ws - 1), &cl.ws_link);
    swc.swc_window_set_handler(w, &window_handler, cl);
    swc.swc_window_set_tiled(w);
    swc.swc_window_show(w);
    focus(cl);
    scheduleRetile();
    notify(sub.EVT_CLIENT | sub.EVT_WORKSPACE);
}

fn onWinDestroy(data: ?*anyopaque) callconv(.c) void {
    const cl: *Client = @ptrCast(@alignCast(data orelse return));
    if (wm.grab.active and wm.grab.c == cl) wm.grab = .{};

    const cl_ws = cl.ws;
    const cl_floating = cl.floating;

    if (!cl_floating) {
        const ws = &wm.workspaces[cl_ws - 1];
        if (cl.bsp_node) |n| {
            const sibling: ?*bsp.Node = blk: {
                const p = n.parent orelse break :blk null;
                break :blk if (p.left == n) p.right else p.left;
            };
            ws.tree.remove(n);
            ws.focused_node = if (sibling) |s| bsp.Tree.firstLeaf(s) else if (ws.tree.root) |r| bsp.Tree.firstLeaf(r) else null;
        }
    }

    swc.wl_list_remove(&cl.link);
    swc.wl_list_remove(&cl.ws_link);

    if (wm.sel_client == cl) {
        wm.sel_client = null;
        const next = firstWsClient(wm.ws);
        if (next) |nc| {
            if (nc.bsp_node) |bn| wm.workspaces[wm.ws - 1].focused_node = bn;
        }
        gpa.destroy(cl);
        focus(next);
        if (cl_ws == wm.ws) scheduleRetile();
    } else {
        gpa.destroy(cl);
        if (cl_ws == wm.ws) scheduleRetile();
    }
    notify(sub.EVT_CLIENT | sub.EVT_WORKSPACE);
}

fn onWinEntered(data: ?*anyopaque) callconv(.c) void {
    if (wm.grab.active) return;
    const cl: *Client = @ptrCast(@alignCast(data orelse return));
    if (!isWsClient(cl, wm.ws)) return;
    focus(cl);
}

// --- IPC ---

fn ipcSocketPath(buf: []u8) []const u8 {
    const xdg = swc.getenv("XDG_RUNTIME_DIR");
    const dir: []const u8 = if (xdg != null) std.mem.span(xdg.?) else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/ikwm.sock", .{dir}) catch "/tmp/ikwm.sock";
}

fn ipcSetup() !void {
    var path_buf: [256]u8 = undefined;
    const path = ipcSocketPath(&path_buf);

    _ = swc.unlink(@as([*:0]const u8, @ptrCast(path.ptr)));

    const sock = swc.socket(swc.AF_UNIX, swc.SOCK_STREAM | swc.SOCK_CLOEXEC | swc.SOCK_NONBLOCK, 0);
    if (sock < 0) return error.SocketCreate;
    errdefer _ = swc.close(sock);

    var addr: swc.sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = swc.AF_UNIX;
    const max_len = @typeInfo(@TypeOf(addr.sun_path)).array.len - 1;
    const copy_len = @min(path.len, max_len);
    @memcpy(addr.sun_path[0..copy_len], path[0..copy_len]);
    addr.sun_path[copy_len] = 0;

    if (swc.bind(sock, @ptrCast(&addr), @sizeOf(swc.sockaddr_un)) < 0) {
        _ = swc.unlink(@ptrCast(&addr.sun_path));
        if (swc.bind(sock, @ptrCast(&addr), @sizeOf(swc.sockaddr_un)) < 0)
            return error.Bind;
    }
    if (swc.listen(sock, 16) < 0) return error.Listen;

    wm.ipc_server_fd = sock;
    @memcpy(wm.ipc_path[0..path.len], path);
    wm.ipc_path[path.len] = 0;

    wm.ipc_source = swc.wl_event_loop_add_fd(
        wm.ev_loop,
        sock,
        swc.WL_EVENT_READABLE,
        ipcAccept,
        null,
    );
    if (wm.ipc_source == null) return error.EventLoopAddFd;

    var env_buf: [272]u8 = undefined;
    const env_val = std.fmt.bufPrintZ(&env_buf, "{s}", .{path}) catch return;
    _ = swc.setenv("IKWM_SOCKET", env_val.ptr, 1);
}

const IpcConn = struct {
    fd: c_int,
    source: *swc.wl_event_source,
};

fn ipcAccept(_: c_int, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    const conn = swc.accept(wm.ipc_server_fd, null, null);
    if (conn < 0) return 0;

    const ipc_conn = gpa.create(IpcConn) catch return 0;
    ipc_conn.fd = conn;

    const source = swc.wl_event_loop_add_fd(
        wm.ev_loop,
        conn,
        swc.WL_EVENT_READABLE,
        ipcRead,
        ipc_conn,
    ) orelse {
        gpa.destroy(ipc_conn);
        _ = swc.close(conn);
        return 0;
    };
    ipc_conn.source = source;
    return 0;
}

fn ipcRead(_: c_int, _: u32, data: ?*anyopaque) callconv(.c) c_int {
    const ipc_conn: *IpcConn = @ptrCast(@alignCast(data orelse return 0));
    const fd = ipc_conn.fd;

    var buf: [4096]u8 = undefined;
    const n = swc.read(fd, &buf, buf.len - 1);

    var became_subscriber = false;

    if (n > 0) {
        const bytes = buf[0..@as(usize, @intCast(n))];
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const cmd = ipc.parse(trimmed) catch |err| {
                const msg = switch (err) {
                    error.UnknownCommand => "error: unknown command\n",
                    error.MissingArgument => "error: missing argument\n",
                    error.BadInteger => "error: bad integer\n",
                    error.BadFloat => "error: bad float\n",
                    error.BadColor => "error: bad color\n",
                    error.BadKey => "error: bad key\n",
                };
                _ = swc.send(fd, msg.ptr, msg.len, swc.MSG_NOSIGNAL);
                continue;
            };

            if (cmd == .follow) {
                wm.subscribers.add(fd, cmd.follow.mask, ipc_conn.source);
                gpa.destroy(ipc_conn);
                became_subscriber = true;
                sendInitialSnapshot(fd, cmd.follow.mask);
                break;
            }

            dispatchCmd(cmd, fd);
        }
    }

    if (!became_subscriber) {
        _ = swc.wl_event_source_remove(ipc_conn.source);
        gpa.destroy(ipc_conn);
        _ = swc.close(fd);
    }

    return 0;
}

fn sendInitialSnapshot(fd: c_int, mask: u32) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    if (mask & sub.EVT_WORKSPACE != 0) {
        const j = buildWorkspacesJson(a) catch return;
        const env = query.EventEnvelope(query.WorkspacesJson){ .event = "workspace_change", .data = j };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        _ = swc.write(fd, w.buffered().ptr, w.buffered().len);
        w = .fixed(&buf);
    }
    if (mask & sub.EVT_FOCUS != 0) {
        const j = buildFocusedJson(a) catch return;
        const env = query.EventEnvelope(query.FocusedJson){ .event = "focus_change", .data = j };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        _ = swc.write(fd, w.buffered().ptr, w.buffered().len);
        w = .fixed(&buf);
    }
    if (mask & sub.EVT_CLIENT != 0) {
        const j = buildClientsJson(a, .all) catch return;
        const env = query.EventEnvelope(query.ClientsJson){ .event = "client_change", .data = j };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        _ = swc.write(fd, w.buffered().ptr, w.buffered().len);
        w = .fixed(&buf);
    }
    if (mask & sub.EVT_MODE != 0) {
        const j = buildModeJson(a) catch return;
        const env = query.EventEnvelope(query.ModeJson){ .event = "mode_change", .data = j };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        _ = swc.write(fd, w.buffered().ptr, w.buffered().len);
        w = .fixed(&buf);
    }
    if (mask & sub.EVT_CONFIG != 0) {
        const j = buildConfigJson();
        const env = query.EventEnvelope(query.ConfigJson){ .event = "config_change", .data = j };
        panthera.stringify(env, .{}, &w) catch return;
        _ = w.writeByte('\n') catch {};
        _ = swc.write(fd, w.buffered().ptr, w.buffered().len);
    }
}

// --- Dispatch ---

fn dispatchCmd(cmd: ipc.Command, reply_fd: c_int) void {
    switch (cmd) {
        .node => |c| dispatchNode(c),
        .desktop => |c| dispatchDesktop(c),
        .config => |c| dispatchConfig(c, reply_fd),
        .bind => |c| dispatchBind(c, reply_fd),
        .mode => |c| dispatchMode(c),
        .wm => |c| dispatchWm(c),
        .query => |c| dispatchQuery(c, reply_fd),
        .follow => {},
    }
}

fn dispatchNode(cmd: ipc.NodeCmd) void {
    switch (cmd) {
        .focus => |t| moveFocus(t),
        .swap => |t| swapNode(t),
        .kill, .close => {
            if (wm.sel_client) |cl| swc.swc_window_close(cl.win);
        },
        .fullscreen => toggleFullscreen(),
        .floating => setFloating(true),
        .tiling => setFloating(false),
        .rotate => rotateSplit(),
        .ratio => |r| setRatio(r),
        .split => |d| setSplit(d),
    }
}

fn dispatchDesktop(cmd: ipc.DesktopCmd) void {
    switch (cmd) {
        .focus => |n| gotoWs(n),
        .send => |n| moveToWs(n),
        .count => |n| setWorkspaceCount(n),
    }
}

fn dispatchConfig(cmd: ipc.ConfigCmd, reply_fd: c_int) void {
    switch (cmd) {
        .get => |key| replyConfig(key, reply_fd),
        .set => |s| applyConfig(s),
    }
}

fn replyConfig(key: ipc.ConfigKey, fd: c_int) void {
    if (fd < 0) return;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const cfg = &wm.cfg;
    const field_name = @tagName(key);
    w.writeAll("{\"") catch return;
    w.writeAll(field_name) catch return;
    w.writeAll("\":") catch return;
    switch (key) {
        .border_width => w.print("{d}", .{cfg.border_width}) catch return,
        .border_outer_width => w.print("{d}", .{cfg.border_outer_width}) catch return,
        .border_color_active => w.print("{x:0>8}", .{cfg.border_color_active}) catch return,
        .border_color_normal => w.print("{x:0>8}", .{cfg.border_color_normal}) catch return,
        .border_outer_color_active => w.print("{x:0>8}", .{cfg.border_outer_color_active}) catch return,
        .border_outer_color_normal => w.print("{x:0>8}", .{cfg.border_outer_color_normal}) catch return,
        .gap_inner => w.print("{d}", .{cfg.gap_inner}) catch return,
        .gap_outer => w.print("{d}", .{cfg.gap_outer}) catch return,
        .wallpaper_color => w.print("{x:0>8}", .{cfg.wallpaper_color}) catch return,
        .decor => {
            if (wm.sel_client) |cl| w.print("{}", .{cl.decor_enabled}) catch return else w.writeAll("null") catch return;
        },
        .decor_default => w.print("{}", .{cfg.decor_default}) catch return,
        .workspace_count => w.print("{d}", .{cfg.workspace_count}) catch return,
        .motion_throttle_hz => w.print("{d}", .{cfg.motion_throttle_hz}) catch return,
    }
    w.writeAll("}\n") catch return;
    const out = w.buffered();
    _ = swc.write(fd, out.ptr, out.len);
}

fn applyConfig(s: ipc.ConfigSet) void {
    const cfg = &wm.cfg;
    switch (s) {
        .border_width => |v| {
            cfg.border_width = v;
            reapplyBorders();
        },
        .border_outer_width => |v| {
            cfg.border_outer_width = v;
            reapplyBorders();
        },
        .border_color_active => |v| {
            cfg.border_color_active = v;
            reapplyBorders();
        },
        .border_color_normal => |v| {
            cfg.border_color_normal = v;
            reapplyBorders();
        },
        .border_outer_color_active => |v| {
            cfg.border_outer_color_active = v;
            reapplyBorders();
        },
        .border_outer_color_normal => |v| {
            cfg.border_outer_color_normal = v;
            reapplyBorders();
        },
        .gap_inner => |v| {
            cfg.gap_inner = v;
            scheduleRetile();
        },
        .gap_outer => |v| {
            cfg.gap_outer = v;
            scheduleRetile();
        },
        .wallpaper_color => |v| {
            cfg.wallpaper_color = v;
            swc.swc_wallpaper_color_set(v);
        },
        .decor => |v| setDecorFocused(v),
        .decor_default => |v| {
            cfg.decor_default = v;
        },
        .workspace_count => |v| setWorkspaceCount(v),
        .motion_throttle_hz => |v| {
            cfg.motion_throttle_hz = v;
        },
    }
    notify(sub.EVT_CONFIG);
}

fn dispatchBind(cmd: ipc.BindCmd, reply_fd: c_int) void {
    switch (cmd) {
        .add => |def| addBind(def),
        .list => |name| {
            if (reply_fd < 0) return;
            var buf: [16384]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeBindsJson(name, &w) catch return;
            _ = w.writeByte('\n') catch {};
            const out = w.buffered();
            _ = swc.write(reply_fd, out.ptr, out.len);
        },
    }
}

fn dispatchMode(cmd: ipc.ModeCmd) void {
    switch (cmd) {
        .enter => |name| {
            if (findMode(name)) |i| activateMode(i);
        },
        .leave => activateMode(0),
        .define => |name| {
            _ = defineMode(name) catch {};
        },
        .remove => |name| {
            if (findMode(name)) |i| destroyMode(i);
        },
    }
}

fn dispatchWm(cmd: ipc.WmCmd) void {
    switch (cmd) {
        .quit => swc.wl_display_terminate(wm.dpy),
        .reload => {},
        .spawn => |s| spawnCmd(s),
    }
}

// --- Actions ---

fn moveFocus(target: ipc.FocusTarget) void {
    switch (target) {
        .next => moveFocusCyclic(1),
        .prev => moveFocusCyclic(-1),
        .left => focusDir(.left),
        .right => focusDir(.right),
        .up => focusDir(.up),
        .down => focusDir(.down),
    }
}

fn moveFocusCyclic(dir: i32) void {
    const head = wsClients(wm.ws - 1);
    if (swc.wl_list_empty(head) != 0) return;
    const sel = wm.sel_client orelse {
        focus(firstWsClient(wm.ws));
        return;
    };
    const next_link = if (dir > 0) sel.ws_link.next else sel.ws_link.prev;
    const target_link = if (next_link == head)
        (if (dir > 0) head.next else head.prev)
    else
        next_link;
    if (target_link == head) return;
    const next_ptr: *swc.struct_wl_list = @ptrCast(target_link.?);
    focus(@fieldParentPtr("ws_link", next_ptr));
}

fn focusDir(dir: ipc.FocusTarget) void {
    const sel = wm.sel_client orelse {
        moveFocusCyclic(1);
        return;
    };
    const sel_node = sel.bsp_node orelse {
        moveFocusCyclic(1);
        return;
    };
    const sel_cx: i32 = sel_node.x + @as(i32, @intCast(sel_node.w / 2));
    const sel_cy: i32 = sel_node.y + @as(i32, @intCast(sel_node.h / 2));

    var best: ?*Client = null;
    var best_dist: i32 = std.math.maxInt(i32);

    const head = wsClients(wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *Client = @fieldParentPtr("ws_link", it.?);
        if (cl == sel or cl.floating or cl.bsp_node == null) continue;
        const n = cl.bsp_node.?;
        const cx: i32 = n.x + @as(i32, @intCast(n.w / 2));
        const cy: i32 = n.y + @as(i32, @intCast(n.h / 2));
        const dist: i32 = switch (dir) {
            .left => blk: {
                if (cx >= sel_cx) continue;
                break :blk sel_cx - cx;
            },
            .right => blk: {
                if (cx <= sel_cx) continue;
                break :blk cx - sel_cx;
            },
            .up => blk: {
                if (cy >= sel_cy) continue;
                break :blk sel_cy - cy;
            },
            .down => blk: {
                if (cy <= sel_cy) continue;
                break :blk cy - sel_cy;
            },
            else => continue,
        };
        if (dist < best_dist) {
            best_dist = dist;
            best = cl;
        }
    }

    if (best) |b| focus(b) else moveFocusCyclic(1);
}

fn swapNode(target: ipc.FocusTarget) void {
    const sel = wm.sel_client orelse return;
    const sel_n = sel.bsp_node orelse return;
    const sel_cx: i32 = sel_n.x + @as(i32, @intCast(sel_n.w / 2));
    const sel_cy: i32 = sel_n.y + @as(i32, @intCast(sel_n.h / 2));

    var best: ?*Client = null;
    var best_dist: i32 = std.math.maxInt(i32);

    const head = wsClients(wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *Client = @fieldParentPtr("ws_link", it.?);
        if (cl == sel or cl.floating or cl.bsp_node == null) continue;
        const n = cl.bsp_node.?;
        const cx: i32 = n.x + @as(i32, @intCast(n.w / 2));
        const cy: i32 = n.y + @as(i32, @intCast(n.h / 2));
        const dist: i32 = switch (target) {
            .left => blk: {
                if (cx >= sel_cx) continue;
                break :blk sel_cx - cx;
            },
            .right => blk: {
                if (cx <= sel_cx) continue;
                break :blk cx - sel_cx;
            },
            .up => blk: {
                if (cy >= sel_cy) continue;
                break :blk sel_cy - cy;
            },
            .down => blk: {
                if (cy <= sel_cy) continue;
                break :blk cy - sel_cy;
            },
            .next, .prev => @intCast((@intFromPtr(cl) >> 4) & 0xffff),
        };
        if (dist < best_dist) {
            best_dist = dist;
            best = cl;
        }
    }

    const other = best orelse return;
    const other_n = other.bsp_node orelse return;
    sel_n.client = other;
    other_n.client = sel;
    sel.bsp_node = other_n;
    other.bsp_node = sel_n;
    scheduleRetile();
    notify(sub.EVT_CLIENT);
}

fn toggleFullscreen() void {
    const cl = wm.sel_client orelse return;
    const scr = cl.scr orelse return;
    if (cl.fullscreen) {
        cl.fullscreen = false;
        swc.swc_window_set_stacked(cl.win);
        applyDecor(cl, true);
        if (!cl.floating) scheduleRetile() else if (cl.fw > 0) swc.swc_window_set_geometry(cl.win, &.{ .x = cl.fx, .y = cl.fy, .width = cl.fw, .height = cl.fh });
    } else {
        var geom: swc.swc_rectangle = undefined;
        if (swc.swc_window_get_geometry(cl.win, &geom)) {
            cl.fx = geom.x;
            cl.fy = geom.y;
            cl.fw = geom.width;
            cl.fh = geom.height;
        }
        cl.fullscreen = true;
        applyDecor(cl, true);
        swc.swc_window_set_fullscreen(cl.win, scr.scr);
    }
    notify(sub.EVT_CLIENT);
}

fn setFloating(floating: bool) void {
    const cl = wm.sel_client orelse return;
    if (cl.floating == floating) return;
    if (floating) {
        if (cl.bsp_node) |n| {
            const ws = &wm.workspaces[cl.ws - 1];
            if (ws.focused_node == n) ws.focused_node = null;
            ws.tree.remove(n);
            cl.bsp_node = null;
        }
        cl.floating = true;
        swc.swc_window_set_stacked(cl.win);
        scheduleRetile();
    } else {
        const ws = curWs();
        const leaf = ws.tree.insert(cl, ws.focused_node) catch return;
        cl.bsp_node = leaf;
        ws.focused_node = leaf;
        cl.floating = false;
        swc.swc_window_set_tiled(cl.win);
        scheduleRetile();
    }
    notify(sub.EVT_CLIENT);
}

fn setSplit(dir: bsp.Dir) void {
    const ws = curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.split_dir = dir;
    scheduleRetile();
}

fn setRatio(r: f32) void {
    const ws = curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.ratio = std.math.clamp(r, 0.1, 0.9);
    scheduleRetile();
}

fn rotateSplit() void {
    const ws = curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.split_dir = if (parent.split_dir == .horizontal) .vertical else .horizontal;
    scheduleRetile();
}

fn reapplyBorders() void {
    const head = wsClients(wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *Client = @fieldParentPtr("ws_link", it.?);
        setBorder(cl, wm.sel_client == cl);
    }
}

fn gotoWs(n: u32) void {
    if (n < 1 or n > wm.cfg.workspace_count or n == wm.ws) return;
    wm.ws = n;
    syncWindowVisibility();
    scheduleRetile();
    focus(firstWsClient(wm.ws));
}

fn moveToWs(n: u32) void {
    const cl = wm.sel_client orelse return;
    if (n < 1 or n > wm.cfg.workspace_count or cl.ws == n) return;

    if (!cl.floating) {
        const old_ws = &wm.workspaces[cl.ws - 1];
        if (cl.bsp_node) |leaf| {
            if (old_ws.focused_node == leaf) old_ws.focused_node = null;
            old_ws.tree.remove(leaf);
            cl.bsp_node = null;
        }
    }
    swc.wl_list_remove(&cl.ws_link);
    cl.ws = n;
    swc.wl_list_insert(wsClients(n - 1), &cl.ws_link);

    if (!cl.floating) {
        const new_ws = &wm.workspaces[n - 1];
        const leaf = new_ws.tree.insert(cl, new_ws.focused_node) catch return;
        cl.bsp_node = leaf;
    }

    if (cl.ws != wm.ws) swc.swc_window_hide(cl.win) else swc.swc_window_show(cl.win);
    scheduleRetile();
    focus(firstWsClient(wm.ws));
    notify(sub.EVT_WORKSPACE | sub.EVT_CLIENT);
}

fn setWorkspaceCount(count: u32) void {
    const new_count = std.math.clamp(count, 1, 10);
    const old_count = wm.cfg.workspace_count;
    if (new_count == old_count) return;

    if (new_count < old_count) {
        var ws_idx: u32 = new_count;
        while (ws_idx < old_count) : (ws_idx += 1) {
            const src = &wm.workspaces[ws_idx];
            while (swc.wl_list_empty(&src.clients) == 0) {
                const next_ptr: *swc.struct_wl_list = @ptrCast(src.clients.next.?);
                const cl: *Client = @fieldParentPtr("ws_link", next_ptr);
                if (!cl.floating) {
                    if (cl.bsp_node) |leaf| {
                        if (src.focused_node == leaf) src.focused_node = null;
                        src.tree.remove(leaf);
                        cl.bsp_node = null;
                    }
                }
                swc.wl_list_remove(&cl.ws_link);
                cl.ws = new_count;
                swc.wl_list_insert(wsClients(new_count - 1), &cl.ws_link);
                if (!cl.floating) {
                    const dst = &wm.workspaces[new_count - 1];
                    const leaf = dst.tree.insert(cl, dst.focused_node) catch continue;
                    cl.bsp_node = leaf;
                    dst.focused_node = leaf;
                }
                if (cl.ws == wm.ws) swc.swc_window_show(cl.win) else swc.swc_window_hide(cl.win);
            }
        }
        if (wm.ws > new_count) {
            wm.ws = new_count;
            syncWindowVisibility();
        }
    }

    wm.cfg.workspace_count = new_count;
    retile(null);
    focus(firstWsClient(wm.ws));
    notify(sub.EVT_WORKSPACE | sub.EVT_CONFIG);
}

fn spawnCmd(cmd_str: []const u8) void {
    var buf: [1024:0]u8 = undefined;
    const len = @min(cmd_str.len, buf.len - 1);
    @memcpy(buf[0..len], cmd_str[0..len]);
    buf[len] = 0;
    const pid = swc.fork();
    if (pid == 0) {
        _ = swc.setsid();
        var fd: c_int = 3;
        while (fd < 1024) : (fd += 1) _ = swc.close(fd);
        _ = swc.execl("/bin/sh", "/bin/sh", "-c", @as([*:0]const u8, @ptrCast(&buf)), @as(?[*:0]const u8, null));
        swc.exit(1);
    }
}

// --- Signals ---

fn sigHandler(_: c_int) callconv(.c) void {
    swc.wl_display_terminate(wm.dpy);
}

// --- Setup ---

fn initWorkspaces() void {
    for (&wm.workspaces) |*ws| {
        ws.tree = bsp.Tree.init(gpa);
        ws.focused_node = null;
        swc.wl_list_init(&ws.clients);
    }
}

fn setup() !void {
    wm.subscribers = sub.Registry.init(gpa);
    wm.dpy = swc.wl_display_create() orelse return error.DisplayCreate;
    wm.ev_loop = swc.wl_display_get_event_loop(wm.dpy) orelse return error.EventLoop;

    swc.wl_list_init(&wm.screens);
    swc.wl_list_init(&wm.clients);
    wm.sel_client = null;
    wm.sel_screen = null;
    wm.grab = .{};
    wm.ws = 1;
    wm.cfg = .{};
    wm.retile_pending = false;
    wm.retile_idle = null;
    wm.mode_count = 0;
    wm.mode_idx = 0;

    _ = try defineMode("default");

    initWorkspaces();

    if (!swc.swc_initialize(wm.dpy, wm.ev_loop, &manager)) {
        while (swc.wl_list_empty(&wm.screens) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(wm.screens.next.?);
            const s: *Screen = @fieldParentPtr("link", next_ptr);
            swc.wl_list_remove(&s.link);
            gpa.destroy(s);
        }
        return error.SwcInit;
    }

    swc.swc_wallpaper_color_set(wm.cfg.wallpaper_color);

    const sock = swc.wl_display_add_socket_auto(wm.dpy) orelse return error.Socket;
    _ = swc.setenv("WAYLAND_DISPLAY", sock, 1);

    _ = swc.signal(swc.SIGINT, sigHandler);
    _ = swc.signal(swc.SIGTERM, sigHandler);
    _ = swc.signal(swc.SIGQUIT, sigHandler);

    try ipcSetup();
}

fn runAutostartIdle(_: ?*anyopaque) callconv(.c) void {
    runAutostart();
}

fn runAutostart() void {
    var buf: [512:0]u8 = undefined;
    const env_path = swc.getenv("IKWM_AUTOSTART");
    if (env_path != null) {
        const pid = swc.fork();
        if (pid == 0) {
            _ = swc.setsid();
            _ = swc.execl(env_path.?, env_path.?, @as(?[*:0]const u8, null));
            swc.exit(0);
        }
        return;
    }
    const home = swc.getenv("HOME");
    if (home == null) return;
    const home_str = std.mem.span(home.?);
    const path = std.fmt.bufPrintZ(&buf, "{s}/.config/ikwm/ikrc", .{home_str}) catch return;
    if (swc.access(path.ptr, swc.X_OK) != 0) return;
    const pid = swc.fork();
    if (pid == 0) {
        _ = swc.setsid();
        _ = swc.execl(path.ptr, path.ptr, @as(?[*:0]const u8, null));
        swc.exit(0);
    }
}

// --- Main ---

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = &init.io;

    std.log.info("starting ikwm", .{});

    try setup();
    defer {
        if (wm.retile_idle) |src| _ = swc.wl_event_source_remove(src);
        wm.subscribers.deinit();
        freeAllModes();
        if (wm.ipc_path[0] != 0) _ = swc.unlink(&wm.ipc_path);
        for (&wm.workspaces) |*ws| ws.deinit();
        swc.swc_finalize();
        swc.wl_display_destroy(wm.dpy);
    }

    _ = swc.wl_event_loop_add_idle(wm.ev_loop, runAutostartIdle, null);
    swc.wl_display_run(wm.dpy);
}
