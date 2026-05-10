const std = @import("std");
const swc = @import("swc");
const config = @import("config.zig");

// --- Types ---

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
    floating: bool = true,
    fullscreen: bool = false,
    mapped: bool = false,
    ws: u32 = 1,
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    decor: swc.swc_decor = std.mem.zeroes(swc.swc_decor),
    proc_name: [256]u8 = std.mem.zeroes([256]u8),
};

pub const Grab = struct {
    active: bool = false,
    resize: bool = false,
    c: ?*Client = null,
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
};

// --- Global State ---

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

// --- Hardware Callbacks ---

pub fn newScreen(scr: ?*swc.swc_screen) callconv(.c) void {
    const s: *Screen = gpa.create(Screen) catch @panic("OOM: new screen");
    s.* = .{
        .scr = scr orelse @panic("null screen"),
        .link = undefined,
    };
    swc.wl_list_insert(&wm.screens, &s.link);
    if (wm.sel_screen == null) wm.sel_screen = s;
    swc.swc_screen_set_handler(scr, &screen_handler, s);
    std.log.debug("new_screen={*}", .{scr});
}

pub fn newWindow(win: ?*swc.swc_window) callconv(.c) void {
    const w = win orelse @panic("null window");
    const pid = swc.swc_window_get_pid(w);
    if (pid <= 0) {
        std.log.debug("ignoring window with no pid", .{});
        swc.swc_window_set_handler(w, null, null);
        return;
    }
    const cl: *Client = gpa.create(Client) catch @panic("OOM: new client");
    cl.* = .{
        .win = w,
        .scr = wm.sel_screen,
        .link = undefined,
    };

    w.motion_throttle_ms = 1000 / config.motion_throttle_hz;
    w.min_width = 1;
    w.min_height = 1;
    w.max_width = 0;
    w.max_height = 0;

    swc.wl_list_insert(&wm.clients, &cl.link);
    swc.swc_window_set_handler(w, &window_handler, cl);
    swc.swc_window_set_stacked(w);
    applyDecor(cl, false);

    var cx: i32 = 0;
    var cy: i32 = 0;
    if (swc.swc_cursor_position(&cx, &cy))
        swc.swc_window_set_position(w, @divTrunc(cx, 256), @divTrunc(cy, 256));

    swc.swc_window_show(w);
    focus(cl);
    std.log.debug("new_window={*}", .{w});
}

pub fn newDevice(_: ?*swc.struct_libinput_device) callconv(.c) void {}

pub const manager: swc.swc_manager = .{
    .new_screen = newScreen,
    .new_window = newWindow,
    .new_device = newDevice,
    .activate = onActivate,
    .deactivate = onDeactivate,
};

// --- Focus/Decor ---

fn focus(cl: ?*Client) void {
    std.log.debug("focus start", .{});
    if (wm.sel_client) |prev| {
        std.log.debug("focus: unsetting prev", .{});
        swc.swc_window_set_border(
            prev.win,
            config.border_color_normal,
            config.border_width,
            config.border_outer_color_normal,
            config.border_outer_width,
        );
        std.log.debug("focus: calling applyDecor prev", .{});
        applyDecor(prev, false);
    }
    if (cl) |next| {
        std.log.debug("focus: setting next border", .{});
        swc.swc_window_set_border(
            next.win,
            config.border_color_active,
            config.border_width,
            config.border_outer_color_active,
            config.border_outer_width,
        );
        std.log.debug("focus: calling applyDecor next", .{});
        applyDecor(next, true);
        std.log.debug("focus: calling swc_window_focus", .{});
        swc.swc_window_focus(next.win);
    }
    std.log.debug("focus done", .{});
    wm.sel_client = cl;
}

fn applyDecor(cl: *Client, active: bool) void {
    if (cl.fullscreen) {
        swc.swc_window_set_decor(cl.win, null);
        return;
    }
    const pid = swc.swc_window_get_pid(cl.win);
    if (pid <= 0) {
        swc.swc_window_set_decor(cl.win, null);
        return;
    }
    cl.decor = config.decor_template;
    cl.decor.title.color = if (active) 0xffffffff else 0xffc0c0c0;
    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch {
        cl.decor.title.enabled = false;
        swc.swc_window_set_decor(cl.win, &cl.decor);
        return;
    };
    _ = path;
    const fd = swc.open(&path_buf, swc.O_RDONLY, @as(c_int, 0));
    if (fd >= 0) {
        defer _ = swc.close(fd);
        const n = swc.read(fd, &cl.proc_name, cl.proc_name.len - 1);
        if (n > 0) {
            const len: usize = @intCast(n);
            var end = len;
            while (end > 0 and cl.proc_name[end - 1] == '\n') end -= 1;
            cl.proc_name[end] = 0;
            cl.decor.title.string = @ptrCast(&cl.proc_name);
            cl.decor.title.enabled = true;
        } else {
            cl.decor.title.enabled = false;
        }
    } else {
        cl.decor.title.enabled = false;
    }
    swc.swc_window_set_decor(cl.win, &cl.decor);
}

// --- WS Helpers ---

fn isWsClient(cl: *const Client, s: ?*const Screen) bool {
    return cl.ws == wm.ws and (s == null or cl.scr == s);
}

fn firstClient(s: ?*Screen) ?*Client {
    var it: ?*swc.struct_wl_list = @as(?*swc.struct_wl_list, wm.clients.next);
    while (it != &wm.clients) : (it = @as(?*swc.struct_wl_list, it.?.next)) {
        const cl: *Client = @fieldParentPtr("link", @as(*swc.struct_wl_list, it.?));
        if (isWsClient(cl, s)) return cl;
    }
    return null;
}

fn syncWindowVisibility() void {
    var it: ?*swc.struct_wl_list = @as(?*swc.struct_wl_list, wm.clients.next);
    while (it != &wm.clients) : (it = it.?.next) {
        const cl: *Client = @fieldParentPtr("link", @as(*swc.struct_wl_list, it.?));
        if (cl.ws == wm.ws)
            swc.swc_window_show(cl.win)
        else
            swc.swc_window_hide(cl.win);
    }
}

// --- Events (Window/Screen) ---

fn onScreenDestroy(data: ?*anyopaque) callconv(.c) void {
    const s: *Screen = @ptrCast(@alignCast(data orelse return));
    swc.wl_list_remove(&s.link);

    if (wm.sel_screen == s) {
        if (swc.wl_list_empty(&wm.screens) != 0) {
            wm.sel_screen = null;
        } else {
            const next_screen: *Screen = @fieldParentPtr("link", @as(*swc.struct_wl_list, wm.screens.next.?));
            wm.sel_screen = next_screen;
        }
    }

    gpa.destroy(s);
}

fn onWinDestroy(data: ?*anyopaque) callconv(.c) void {
    const cl: *Client = @ptrCast(@alignCast(data orelse return));

    if (wm.grab.active and wm.grab.c == cl) {
        wm.grab.active = false;
        wm.grab.c = null;
    }
    if (wm.sel_client == cl) wm.sel_client = null;

    swc.wl_list_remove(&cl.link);
    gpa.destroy(cl);

    var next = firstClient(wm.sel_screen);
    if (next == null) next = firstClient(null);
    focus(next);
}

fn onWinEntered(data: ?*anyopaque) callconv(.c) void {
    std.log.debug("onWinEntered", .{});
    if (wm.grab.active) return;
    const cl: *Client = @ptrCast(@alignCast(data orelse return));
    std.log.debug("onWinEntered: checking ws", .{});
    if (!isWsClient(cl, null)) return;
    std.log.debug("onWinEntered: calling focus", .{});
    focus(cl);
    std.log.debug("onWinEntered: done", .{});
}

// --- Keybinds ---

pub fn actFocusNext(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    if (swc.wl_list_empty(&wm.clients) != 0) return;

    const sel = wm.sel_client;
    if (sel == null or !isWsClient(sel.?, wm.sel_screen)) {
        var next = firstClient(wm.sel_screen);
        if (next == null) next = firstClient(null);
        focus(next);
        return;
    }

    var it: ?*swc.struct_wl_list = @as(?*swc.struct_wl_list, sel.?.link.next);
    const start = it;
    while (true) {
        if (it == &wm.clients) it = wm.clients.next;
        if (it == &wm.clients) break;
        const cl: *Client = @fieldParentPtr("link", @as(*swc.struct_wl_list, it.?));
        if (isWsClient(cl, wm.sel_screen)) {
            focus(cl);
            return;
        }
        it = it.?.next;
        if (it == start) break;
    }

    var fallback = firstClient(wm.sel_screen);
    if (fallback == null) fallback = firstClient(null);
    focus(fallback);
}

pub fn actFocusPrev(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    if (swc.wl_list_empty(&wm.clients) != 0) return;

    const sel = wm.sel_client;
    if (sel == null or !isWsClient(sel.?, wm.sel_screen)) {
        var next = firstClient(wm.sel_screen);
        if (next == null) next = firstClient(null);
        focus(next);
        return;
    }

    var it: ?*swc.struct_wl_list = @as(?*swc.struct_wl_list, sel.?.link.prev);
    const start = it;
    while (true) {
        if (it == &wm.clients) it = wm.clients.prev;
        if (it == &wm.clients) break;
        const cl: *Client = @fieldParentPtr("link", @as(*swc.struct_wl_list, it.?));
        if (isWsClient(cl, wm.sel_screen)) {
            focus(cl);
            return;
        }
        it = it.?.prev;
        if (it == start) break;
    }

    var fallback = firstClient(wm.sel_screen);
    if (fallback == null) fallback = firstClient(null);
    focus(fallback);
}

pub fn actKillSel(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    if (wm.sel_client) |cl| swc.swc_window_close(cl.win);
}

pub fn actFullscreen(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    const cl = wm.sel_client orelse return;

    if (cl.fullscreen) {
        cl.fullscreen = false;
        swc.swc_window_set_stacked(cl.win);
        applyDecor(cl, true);
        if (cl.w > 0 and cl.h > 0) {
            swc.swc_window_set_geometry(cl.win, &.{
                .x = cl.x,
                .y = cl.y,
                .width = cl.w,
                .height = cl.h,
            });
        }
        return;
    }

    const scr = cl.scr orelse return;
    var geom: swc.swc_rectangle = undefined;
    if (swc.swc_window_get_geometry(cl.win, &geom)) {
        cl.x = geom.x;
        cl.y = geom.y;
        cl.w = geom.width;
        cl.h = geom.height;
    }
    cl.fullscreen = true;
    applyDecor(cl, true);
    swc.swc_window_set_fullscreen(cl.win, scr.scr);
}

pub fn actMouseMove(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state == swc.WL_POINTER_BUTTON_STATE_PRESSED) {
        const cl = wm.sel_client orelse return;
        if (!cl.floating) {
            cl.floating = true;
            swc.swc_window_set_stacked(cl.win);
        }
        wm.grab = .{ .active = true, .resize = false, .c = cl };
        swc.swc_window_begin_move(cl.win);
    } else {
        if (!wm.grab.active or wm.grab.resize) return;
        if (wm.grab.c) |gc| swc.swc_window_end_move(gc.win);
        wm.grab = .{};
    }
}

pub fn actMouseResize(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state == swc.WL_POINTER_BUTTON_STATE_PRESSED) {
        const cl = wm.sel_client orelse return;
        if (!cl.floating) {
            cl.floating = true;
            swc.swc_window_set_stacked(cl.win);
        }
        wm.grab = .{ .active = true, .resize = true, .c = cl };
        swc.swc_window_begin_resize(
            cl.win,
            swc.SWC_WINDOW_EDGE_RIGHT | swc.SWC_WINDOW_EDGE_BOTTOM,
        );
    } else {
        if (!wm.grab.active or !wm.grab.resize) return;
        if (wm.grab.c) |gc| swc.swc_window_end_resize(gc.win);
        wm.grab = .{};
    }
}

pub fn actQuit(
    _: ?*anyopaque,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {
    swc.wl_display_terminate(wm.dpy);
}

/// data must point to a null-sentinel argv: [*:null]?[*:0]u8
pub fn actSpawn(
    data: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    const argv_c: [*:null]?[*:0]const u8 = @ptrCast(@alignCast(data orelse return));
    const cmd = argv_c[0] orelse return;

    const pid = swc.fork();
    if (pid == 0) {
        _ = swc.setsid();
        var fd: c_int = 3;
        while (fd < 1024) : (fd += 1) _ = swc.close(fd);
        _ = swc.execl("/bin/sh", "/bin/sh", "-c", cmd, @as(?[*:0]const u8, null));
        swc.exit(1);
    }
}

pub fn actWorkspaceGoto(
    data: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    const ws: *u32 = @ptrCast(@alignCast(data orelse return));
    if (ws.* < 1 or ws.* > 9 or ws.* == wm.ws) return;
    wm.ws = ws.*;
    syncWindowVisibility();
    var next = firstClient(wm.sel_screen);
    if (next == null) next = firstClient(null);
    focus(next);
}

pub fn actWorkspaceMoveto(
    data: ?*anyopaque,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    if (state != swc.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    const cl = wm.sel_client orelse return;
    const ws: *u32 = @ptrCast(@alignCast(data orelse return));
    if (ws.* < 1 or ws.* > 9 or cl.ws == ws.*) return;
    cl.ws = ws.*;
    if (cl.ws == wm.ws) swc.swc_window_show(cl.win) else swc.swc_window_hide(cl.win);
    var next = firstClient(wm.sel_screen);
    if (next == null) next = firstClient(null);
    focus(next);
}

// --- Signals ---

fn sigHandler(_: c_int) callconv(.c) void {
    swc.wl_display_terminate(wm.dpy);
}

// --- Seat ---
pub fn onActivate() callconv(.c) void {
    std.log.debug("activate", .{});
}

pub fn onDeactivate() callconv(.c) void {
    std.log.debug("deactivate", .{});
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

    if (!swc.swc_initialize(wm.dpy, wm.ev_loop, &manager))
        return error.SwcInit;

    swc.swc_wallpaper_color_set(config.wallpaper_color);

    for (config.binds) |bind| {
        _ = swc.swc_add_binding(bind.type, bind.mods, bind.ksym, bind.handler, bind.data);
    }

    const sock = swc.wl_display_add_socket_auto(wm.dpy) orelse
        return error.Socket;
    _ = swc.setenv("WAYLAND_DISPLAY", sock, 1);
    std.log.info("WAYLAND_DISPLAY={s}", .{sock});

    _ = swc.signal(swc.SIGINT, sigHandler);
    _ = swc.signal(swc.SIGTERM, sigHandler);
    _ = swc.signal(swc.SIGQUIT, sigHandler);
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = &init.io;

    std.log.info("starting ikwm", .{}); // erm dont delete this or the entire thing hangs

    try setup();
    defer {
        swc.swc_finalize();
        swc.wl_display_destroy(wm.dpy);
    }

    swc.wl_display_run(wm.dpy);
}
