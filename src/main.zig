const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const ipc = @import("ipc.zig");

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

const Workspace = struct {
    tree: bsp.Tree,
    focused_node: ?*bsp.Node = null,
    clients: swc.struct_wl_list = undefined,

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

// --- App Name ---

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

fn setDecorGlobal(enabled: bool) void {
    wm.cfg.decor_default = enabled;
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
    if (wm.sel_client) |prev| {
        setBorder(prev, false);
    }
    if (cl) |next| {
        setBorder(next, true);
        swc.swc_window_focus(next.win);
        if (next.bsp_node) |n| curWs().focused_node = n;
    } else {
        swc.swc_window_focus(null);
    }
    wm.sel_client = cl;
}

// --- Retile ---

fn scheduleRetile() void {
    if (wm.retile_pending) return;
    wm.retile_pending = true;
    if (wm.retile_idle == null) {
        wm.retile_idle = swc.wl_event_loop_add_idle(
            wm.ev_loop,
            doRetileIdle,
            null,
        );
    }
}

fn doRetileIdle(_: ?*anyopaque) callconv(.c) void {
    wm.retile_idle = null;
    wm.retile_pending = false;
    retile();
}

fn retile() void {
    const ws = curWs();
    const scr = wm.sel_screen orelse return;
    std.log.debug("retile: root={any} focused={any}", .{
        ws.tree.root != null,
        ws.focused_node != null,
    });
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
        wm.sel_screen = if (swc.wl_list_empty(&wm.screens) != 0)
            null
        else
            @fieldParentPtr("link", @as(*swc.struct_wl_list, @ptrCast(wm.screens.next)));
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
}

fn onWinDestroy(data: ?*anyopaque) callconv(.c) void {
    const cl: *Client = @ptrCast(@alignCast(data orelse return));

    if (wm.grab.active and wm.grab.c == cl) wm.grab = .{};

    const cl_ws = cl.ws;
    const cl_floating = cl.floating;

    if (!cl_floating) {
        const ws = &wm.workspaces[cl_ws - 1];
        if (cl.bsp_node) |n| {
            // pick the sibling to focus after removal
            const sibling: ?*bsp.Node = blk: {
                const p = n.parent orelse break :blk null;
                break :blk if (p.left == n) p.right else p.left;
            };
            ws.tree.remove(n);
            ws.focused_node = if (sibling) |s|
                bsp.Tree.firstLeaf(s)
            else if (ws.tree.root) |r|
                bsp.Tree.firstLeaf(r)
            else
                null;
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

    // retry once to recover from a stale socket left by a previous crash
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
                };
                _ = swc.send(fd, msg.ptr, msg.len, swc.MSG_NOSIGNAL);
                continue;
            };
            dispatchCmd(cmd, fd);
        }
    }

    _ = swc.wl_event_source_remove(ipc_conn.source);
    gpa.destroy(ipc_conn);
    _ = swc.close(fd);
    return 0;
}

fn dispatchCmd(cmd: ipc.Command, reply_fd: c_int) void {
    switch (cmd) {
        .focus_next => moveFocus(1),
        .focus_prev => moveFocus(-1),
        .focus_dir => |d| focusDir(d),
        .kill => {
            if (wm.sel_client) |cl| swc.swc_window_close(cl.win);
        },
        .fullscreen => toggleFullscreen(),
        .floating => setFloating(true),
        .tiling => setFloating(false),
        .split => |dir| setSplit(dir),
        .ratio => |r| setRatio(r),
        .rotate => rotateSplit(),

        .gap_inner => |v| {
            wm.cfg.gap_inner = v;
            scheduleRetile();
        },
        .gap_outer => |v| {
            wm.cfg.gap_outer = v;
            scheduleRetile();
        },

        .border_width => |v| {
            wm.cfg.border_width = v;
            reapplyBorders();
        },
        .border_outer_width => |v| {
            wm.cfg.border_outer_width = v;
            reapplyBorders();
        },
        .border_color_active => |v| {
            wm.cfg.border_color_active = v;
            reapplyBorders();
        },
        .border_color_normal => |v| {
            wm.cfg.border_color_normal = v;
            reapplyBorders();
        },
        .border_outer_color_active => |v| {
            wm.cfg.border_outer_color_active = v;
            reapplyBorders();
        },
        .border_outer_color_normal => |v| {
            wm.cfg.border_outer_color_normal = v;
            reapplyBorders();
        },

        .wallpaper_color => |v| {
            wm.cfg.wallpaper_color = v;
            swc.swc_wallpaper_color_set(v);
        },

        .decor_focused => |v| setDecorFocused(v),
        .decor_global => |v| setDecorGlobal(v),

        .workspace_goto => |n| gotoWs(n),
        .workspace_move => |n| moveToWs(n),
        .workspace_count => |n| setWorkspaceCount(n),

        .spawn => |cmd_str| spawnCmd(cmd_str),
        .quit => swc.wl_display_terminate(wm.dpy),

        .query_focused => {
            if (wm.sel_client) |cl| {
                const pid = swc.swc_window_get_pid(cl.win);
                var pbuf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{pid}) catch return;
                _ = swc.write(reply_fd, s.ptr, s.len);
            } else {
                _ = swc.write(reply_fd, "none\n", 5);
            }
        },

        .query_workspaces => {
            var pbuf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&pbuf, "count {d}\ncurrent {d}\n", .{
                wm.cfg.workspace_count,
                wm.ws,
            }) catch return;
            _ = swc.write(reply_fd, s.ptr, s.len);
        },
    }
}

// --- Actions ---

fn moveFocus(dir: i32) void {
    const head = wsClients(wm.ws - 1);
    if (swc.wl_list_empty(head) != 0) return;

    const sel = wm.sel_client orelse {
        focus(firstWsClient(wm.ws));
        return;
    };

    const next_link = if (dir > 0) sel.ws_link.next else sel.ws_link.prev;
    const target_link = if (next_link == head)
        (if (dir > 0) head.next else head.prev) // wrap around
    else
        next_link;

    if (target_link == head) return;
    const target_ptr: *swc.struct_wl_list = @ptrCast(target_link.?);
    focus(@fieldParentPtr("ws_link", target_ptr));
}

fn focusDir(dir: ipc.Command.Dir) void {
    const sel = wm.sel_client orelse {
        moveFocus(1);
        return;
    };
    const sel_node = sel.bsp_node orelse {
        moveFocus(1);
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
        };
        if (dist < best_dist) {
            best_dist = dist;
            best = cl;
        }
    }

    if (best) |b| focus(b) else moveFocus(1);
}

fn toggleFullscreen() void {
    const cl = wm.sel_client orelse return;
    const scr = cl.scr orelse return;

    if (cl.fullscreen) {
        cl.fullscreen = false;
        swc.swc_window_set_stacked(cl.win);
        applyDecor(cl, true);
        if (!cl.floating) {
            scheduleRetile();
        } else if (cl.fw > 0) {
            swc.swc_window_set_geometry(cl.win, &.{ .x = cl.fx, .y = cl.fy, .width = cl.fw, .height = cl.fh });
        }
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
    if (swc.wl_list_empty(head) != 0) return;
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
    retile(); // must layout before focus
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
}

fn setWorkspaceCount(count: u32) void {
    const new_count = std.math.clamp(count, 1, 10);
    const old_count = wm.cfg.workspace_count;
    if (new_count == old_count) return;

    if (new_count < old_count) {
        // evacuate clients from removed workspaces into the new last one
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

                if (cl.ws == wm.ws)
                    swc.swc_window_show(cl.win)
                else
                    swc.swc_window_hide(cl.win);
            }
        }

        if (wm.ws > new_count) {
            wm.ws = new_count;
            syncWindowVisibility();
        }
    }

    wm.cfg.workspace_count = new_count;
    retile();
    focus(firstWsClient(wm.ws));
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
        while (fd < 1024) : (fd += 1) _ = swc.close(fd); // close inherited fds
        _ = swc.execl("/bin/sh", "/bin/sh", "-c", @as([*:0]const u8, @ptrCast(&buf)), @as(?[*:0]const u8, null));
        swc.exit(1);
    }
}

// --- Signals ---

fn sigHandler(_: c_int) callconv(.c) void {
    swc.wl_display_terminate(wm.dpy);
}

// --- Setup ---

fn setup() !void {
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

    for (&wm.workspaces) |*ws| {
        ws.tree = bsp.Tree.init(gpa);
        ws.focused_node = null;
        swc.wl_list_init(&ws.clients);
    }

    if (!swc.swc_initialize(wm.dpy, wm.ev_loop, &manager)) {
        // swc may have called newScreen before failing; clean up
        while (swc.wl_list_empty(&wm.screens) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(wm.screens.next.?);
            const s: *Screen = @fieldParentPtr("link", next_ptr);
            swc.wl_list_remove(&s.link);
            gpa.destroy(s);
        }
        return error.SwcInit;
    }

    swc.swc_wallpaper_color_set(wm.cfg.wallpaper_color);

    const sock = swc.wl_display_add_socket_auto(wm.dpy) orelse
        return error.Socket;
    _ = swc.setenv("WAYLAND_DISPLAY", sock, 1);

    _ = swc.signal(swc.SIGINT, sigHandler);
    _ = swc.signal(swc.SIGTERM, sigHandler);
    _ = swc.signal(swc.SIGQUIT, sigHandler);

    try ipcSetup();
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
    const path = std.fmt.bufPrintZ(&buf, "{s}/.config/ikwm/autostart", .{home_str}) catch return;
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
        if (wm.ipc_path[0] != 0) _ = swc.unlink(&wm.ipc_path);
        for (&wm.workspaces) |*ws| ws.deinit();
        swc.swc_finalize();
        swc.wl_display_destroy(wm.dpy);
    }

    runAutostart();
    swc.wl_display_run(wm.dpy);
}
