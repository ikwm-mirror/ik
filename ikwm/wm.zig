const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const sub = @import("subscriber.zig");

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

pub const MAX_MODES = 32;
pub const MODE_NAME_MAX = 64;

pub const Bind = struct {
    mods: u32,
    sym: u32,
    command: []u8,
    mode_idx: usize,
    link: swc.struct_wl_list,
};

pub const Mode = struct {
    name: [MODE_NAME_MAX]u8 = std.mem.zeroes([MODE_NAME_MAX]u8),
    name_len: usize = 0,
    binds: swc.struct_wl_list = undefined,
};

pub const Workspace = struct {
    tree: bsp.Tree,
    focused_node: ?*bsp.Node = null,
    clients: swc.struct_wl_list = undefined,

    pub fn deinit(self: *Workspace) void {
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

pub var wm: Wm = undefined;
pub var gpa: std.mem.Allocator = undefined;

// --- Helpers ---

pub fn curWs() *Workspace {
    return &wm.workspaces[wm.ws - 1];
}

pub fn wsClients(ws_idx: usize) *swc.struct_wl_list {
    return &wm.workspaces[ws_idx].clients;
}

pub fn firstWsClient(ws: u32) ?*Client {
    const head = wsClients(ws - 1);
    if (swc.wl_list_empty(head) != 0) return null;
    const next_ptr: *swc.struct_wl_list = @ptrCast(head.next.?);
    return @fieldParentPtr("ws_link", next_ptr);
}

pub fn isWsClient(cl: *const Client, ws: u32) bool {
    return cl.ws == ws;
}

pub fn procName(cl: *Client) []const u8 {
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
