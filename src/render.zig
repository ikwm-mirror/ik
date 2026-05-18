const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const w = @import("wm.zig");
const sub = @import("subscriber.zig");
const notify = @import("json.zig").notify;

pub fn applyDecor(cl: *w.Client, active: bool) void {
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
    const name = w.procName(cl);
    if (name.len > 0) {
        cl.decor.title.string = @ptrCast(&cl.proc_name);
        cl.decor.title.enabled = true;
        cl.decor.title.color = if (active) 0xffffffff else 0xffc0c0c0;
        cl.decor.title.edge = swc.SWC_DECOR_EDGE_TOP;
        cl.decor.title.@"align" = swc.SWC_DECOR_ALIGN_CENTER;
    }
    swc.swc_window_set_decor(cl.win, &cl.decor);
}

pub fn setDecorFocused(enabled: bool) void {
    const cl = w.wm.sel_client orelse return;
    if (cl.decor_enabled == enabled) return;
    cl.decor_enabled = enabled;
    applyDecor(cl, true);
    scheduleRetile();
}

pub fn setBorder(cl: *w.Client, active: bool) void {
    const cfg = &w.wm.cfg;
    swc.swc_window_set_border(
        cl.win,
        if (active) cfg.border_color_active else cfg.border_color_normal,
        cfg.border_width,
        if (active) cfg.border_outer_color_active else cfg.border_outer_color_normal,
        cfg.border_outer_width,
    );
}

pub fn reapplyBorders() void {
    const head = w.wsClients(w.wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *w.Client = @fieldParentPtr("ws_link", it.?);
        setBorder(cl, w.wm.sel_client == cl);
    }
}

pub fn focus(cl: ?*w.Client) void {
    if (w.wm.sel_client) |prev| setBorder(prev, false);
    if (cl) |next| {
        setBorder(next, true);
        swc.swc_window_focus(next.win);
        if (next.bsp_node) |n| w.curWs().focused_node = n;
    } else {
        swc.swc_window_focus(null);
    }
    w.wm.sel_client = cl;
    notify(sub.EVT_FOCUS);
}

pub fn scheduleRetile() void {
    if (w.wm.retile_pending) return;
    w.wm.retile_pending = true;
    if (w.wm.retile_idle == null) {
        w.wm.retile_idle = swc.wl_event_loop_add_idle(w.wm.ev_loop, doRetileIdle, null);
    }
}

pub fn doRetileIdle(_: ?*anyopaque) callconv(.c) void {
    w.wm.retile_idle = null;
    w.wm.retile_pending = false;
    retile(null);
}

pub fn retile(ws_idx: ?usize) void {
    const ws = if (ws_idx) |wid| &w.wm.workspaces[wid] else w.curWs();
    const scr = w.wm.sel_screen orelse return;
    ws.tree.layout(
        scr.scr.geometry.x,
        scr.scr.geometry.y,
        scr.scr.geometry.width,
        scr.scr.geometry.height,
        w.wm.cfg.gap_inner,
        w.wm.cfg.gap_outer,
        &tileCallback,
    );
}

fn tileCallback(client: *anyopaque, x: i32, y: i32, width: u32, height: u32) void {
    const cl: *w.Client = @ptrCast(@alignCast(client));
    swc.swc_window_set_geometry(cl.win, &.{ .x = x, .y = y, .width = width, .height = height });
}

pub fn syncWindowVisibility() void {
    var it: ?*swc.struct_wl_list = w.wm.clients.next;
    while (it != &w.wm.clients) : (it = it.?.next) {
        const cl: *w.Client = @fieldParentPtr("link", it.?);
        if (cl.ws == w.wm.ws) swc.swc_window_show(cl.win) else swc.swc_window_hide(cl.win);
    }
}
