const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const ipc = @import("ipc.zig");
const w = @import("wm.zig");
const r = @import("render.zig");
const act = @import("actions.zig");
const kb = @import("keybind.zig");
const jn = @import("json.zig");
const dp = @import("dispatch.zig");
const sub = @import("subscriber.zig");

// --- Aliases ---

const Io = std.Io;
const fs = Io.Dir;
const net = Io.net;
const unix = net.UnixAddress;

// --- Hardware Callbacks ---

var window_handler: swc.swc_window_handler = .{
    .destroy = onWinDestroy,
    .entered = onWinEntered,
};

var screen_handler: swc.swc_screen_handler = .{
    .destroy = onScreenDestroy,
};

pub fn newScreen(scr: ?*swc.swc_screen) callconv(.c) void {
    const s: *w.Screen = w.gpa.create(w.Screen) catch @panic("OOM");
    s.* = .{ .scr = scr orelse @panic("null screen"), .link = undefined };
    swc.wl_list_insert(&w.wm.screens, &s.link);
    if (w.wm.sel_screen == null) w.wm.sel_screen = s;
    swc.swc_screen_set_handler(scr, &screen_handler, s);
}

fn onScreenDestroy(data: ?*anyopaque) callconv(.c) void {
    const s: *w.Screen = @ptrCast(@alignCast(data orelse return));
    swc.wl_list_remove(&s.link);
    if (w.wm.sel_screen == s) {
        w.wm.sel_screen = if (swc.wl_list_empty(&w.wm.screens) != 0) null else @fieldParentPtr("link", @as(*swc.struct_wl_list, @ptrCast(w.wm.screens.next)));
    }
    w.gpa.destroy(s);
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

// --- Window callbacks ---

pub fn newWindow(win: ?*swc.swc_window) callconv(.c) void {
    const wn = win orelse return;
    const cl: *w.Client = w.gpa.create(w.Client) catch @panic("OOM");
    cl.* = .{
        .win = wn,
        .scr = w.wm.sel_screen,
        .link = undefined,
        .ws_link = undefined,
        .ws = w.wm.ws,
        .decor_enabled = w.wm.cfg.decor_default,
    };
    wn.motion_throttle_ms = 1000 / w.wm.cfg.motion_throttle_hz;
    wn.min_width = 1;
    wn.min_height = 1;
    wn.max_width = 0;
    wn.max_height = 0;

    const ws = w.curWs();
    const leaf = ws.tree.insert(cl, ws.focused_node) catch @panic("OOM");
    cl.bsp_node = leaf;
    ws.focused_node = leaf;

    swc.wl_list_insert(&w.wm.clients, &cl.link);
    swc.wl_list_insert(w.wsClients(w.wm.ws - 1), &cl.ws_link);
    swc.swc_window_set_handler(wn, &window_handler, cl);
    swc.swc_window_set_tiled(wn);
    swc.swc_window_show(wn);
    r.focus(cl);
    r.scheduleRetile();
    jn.notify(sub.EVT_CLIENT | sub.EVT_WORKSPACE);
}

fn onWinDestroy(data: ?*anyopaque) callconv(.c) void {
    const cl: *w.Client = @ptrCast(@alignCast(data orelse return));
    if (w.wm.grab.active and w.wm.grab.c == cl) w.wm.grab = .{};

    const cl_ws = cl.ws;
    const cl_floating = cl.floating;

    if (!cl_floating) {
        const ws = &w.wm.workspaces[cl_ws - 1];
        if (cl.bsp_node) |n| {
            const sibling: ?*bsp.Node = blk: {
                const p = n.parent orelse break :blk null;
                break :blk if (p.left == n) p.right else p.left;
            };
            ws.tree.remove(n);
            ws.focused_node = if (sibling) |s| bsp.Tree.firstLeaf(s) else if (ws.tree.root) |rt| bsp.Tree.firstLeaf(rt) else null;
        }
    }

    swc.wl_list_remove(&cl.link);
    swc.wl_list_remove(&cl.ws_link);

    if (w.wm.sel_client == cl) {
        w.wm.sel_client = null;
        const next = w.firstWsClient(w.wm.ws);
        if (next) |nc| {
            if (nc.bsp_node) |bn| w.wm.workspaces[w.wm.ws - 1].focused_node = bn;
        }
        w.gpa.destroy(cl);
        r.focus(next);
        if (cl_ws == w.wm.ws) r.scheduleRetile();
    } else {
        w.gpa.destroy(cl);
        if (cl_ws == w.wm.ws) r.scheduleRetile();
    }
    jn.notify(sub.EVT_CLIENT | sub.EVT_WORKSPACE);
}

fn onWinEntered(data: ?*anyopaque) callconv(.c) void {
    if (w.wm.grab.active) return;
    const cl: *w.Client = @ptrCast(@alignCast(data orelse return));
    if (!w.isWsClient(cl, w.wm.ws)) return;
    r.focus(cl);
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

    fs.deleteDirAbsolute(w.io.*, path) catch {};

    const addr = try unix.init(path);
    const server = try addr.listen(w.io.*, .{ .kernel_backlog = 16 });
    const sock: i32 = server.socket.handle;

    w.wm.ipc_server_fd = sock;
    w.wm.ipc_server = server;

    @memcpy(w.wm.ipc_path[0..path.len], path);
    w.wm.ipc_path[path.len] = 0;

    w.wm.ipc_source = swc.wl_event_loop_add_fd(
        w.wm.ev_loop,
        sock,
        swc.WL_EVENT_READABLE,
        ipcAccept,
        null,
    );
    if (w.wm.ipc_source == null) return error.EventLoopAddFd;

    try w.env.put("IKWM_SOCKET", path);
}

const IpcConn = struct {
    fd: c_int,
    source: *swc.wl_event_source,
};

fn ipcAccept(_: c_int, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    const conn = swc.accept(w.wm.ipc_server_fd, null, null);
    if (conn < 0) return 0;

    const ipc_conn = w.gpa.create(IpcConn) catch return 0;
    ipc_conn.fd = conn;

    const source = swc.wl_event_loop_add_fd(
        w.wm.ev_loop,
        conn,
        swc.WL_EVENT_READABLE,
        ipcRead,
        ipc_conn,
    ) orelse {
        w.gpa.destroy(ipc_conn);
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
                w.wm.subscribers.add(fd, cmd.follow.mask, ipc_conn.source);
                w.gpa.destroy(ipc_conn);
                became_subscriber = true;
                jn.sendInitialSnapshot(fd, cmd.follow.mask);
                break;
            }

            dp.dispatchCmd(cmd, fd);
        }
    }

    if (!became_subscriber) {
        _ = swc.wl_event_source_remove(ipc_conn.source);
        w.gpa.destroy(ipc_conn);
        _ = swc.close(fd);
    }

    return 0;
}

// --- Signals ---

fn sigHandler(_: c_int) callconv(.c) void {
    swc.wl_display_terminate(w.wm.dpy);
}

// --- Setup ---

fn initWorkspaces() void {
    for (&w.wm.workspaces) |*ws| {
        ws.tree = bsp.Tree.init(w.gpa);
        ws.focused_node = null;
        swc.wl_list_init(&ws.clients);
    }
}

fn setup() !void {
    w.wm.subscribers = sub.Registry.init(w.gpa);

    w.wm.dpy = swc.wl_display_create() orelse return error.DisplayCreate;
    w.wm.ev_loop = swc.wl_display_get_event_loop(w.wm.dpy) orelse return error.EventLoop;

    swc.wl_list_init(&w.wm.screens);
    swc.wl_list_init(&w.wm.clients);
    w.wm.sel_client = null;
    w.wm.sel_screen = null;
    w.wm.grab = .{};
    w.wm.ws = 1;
    w.wm.cfg = .{};
    w.wm.retile_pending = false;
    w.wm.retile_idle = null;
    w.wm.mode_count = 0;
    w.wm.mode_idx = 0;

    _ = try kb.defineMode("default");

    initWorkspaces();

    if (!swc.swc_initialize(w.wm.dpy, w.wm.ev_loop, &manager)) {
        while (swc.wl_list_empty(&w.wm.screens) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(w.wm.screens.next.?);
            const s: *w.Screen = @fieldParentPtr("link", next_ptr);
            swc.wl_list_remove(&s.link);
            w.gpa.destroy(s);
        }
        return error.SwcInit;
    }

    swc.swc_wallpaper_color_set(w.wm.cfg.wallpaper_color);

    const sock = swc.wl_display_add_socket_auto(w.wm.dpy) orelse return error.Socket;
    _ = swc.setenv("WAYLAND_DISPLAY", sock, 1);

    _ = swc.signal(swc.SIGINT, sigHandler);
    _ = swc.signal(swc.SIGTERM, sigHandler);
    _ = swc.signal(swc.SIGQUIT, sigHandler);

    try ipcSetup();
}

pub fn runAutostart() void {
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

fn runAutostartIdle(_: ?*anyopaque) callconv(.c) void {
    runAutostart();
}

// --- Main ---

pub fn main(init: std.process.Init) !void {
    w.gpa = init.gpa;
    w.env = init.environ_map;
    w.io = &init.io;

    std.log.info("starting ikwm", .{});

    try setup();
    defer {
        if (w.wm.retile_idle) |src| _ = swc.wl_event_source_remove(src);
        w.wm.subscribers.deinit();
        kb.freeAllModes();
        if (w.wm.ipc_path[0] != 0) _ = swc.unlink(&w.wm.ipc_path);
        for (&w.wm.workspaces) |*ws| ws.deinit();
        swc.swc_finalize();
        swc.wl_display_destroy(w.wm.dpy);
    }

    _ = swc.wl_event_loop_add_idle(w.wm.ev_loop, runAutostartIdle, null);
    swc.wl_display_run(w.wm.dpy);
}
