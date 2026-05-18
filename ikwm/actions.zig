const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");
const ipc = @import("ipc.zig");
const w = @import("wm.zig");
const r = @import("render.zig");
const sub = @import("subscriber.zig");
const notify = @import("json.zig").notify;

pub fn moveFocus(target: ipc.FocusTarget) void {
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
    const head = w.wsClients(w.wm.ws - 1);
    if (swc.wl_list_empty(head) != 0) return;
    const sel = w.wm.sel_client orelse {
        r.focus(w.firstWsClient(w.wm.ws));
        return;
    };
    const next_link = if (dir > 0) sel.ws_link.next else sel.ws_link.prev;
    const target_link = if (next_link == head)
        (if (dir > 0) head.next else head.prev)
    else
        next_link;
    if (target_link == head) return;
    const next_ptr: *swc.struct_wl_list = @ptrCast(target_link.?);
    r.focus(@fieldParentPtr("ws_link", next_ptr));
}

fn focusDir(dir: ipc.FocusTarget) void {
    const sel = w.wm.sel_client orelse {
        moveFocusCyclic(1);
        return;
    };
    const sel_node = sel.bsp_node orelse {
        moveFocusCyclic(1);
        return;
    };
    const sel_cx: i32 = sel_node.x + @as(i32, @intCast(sel_node.w / 2));
    const sel_cy: i32 = sel_node.y + @as(i32, @intCast(sel_node.h / 2));

    var best: ?*w.Client = null;
    var best_dist: i32 = std.math.maxInt(i32);

    const head = w.wsClients(w.wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *w.Client = @fieldParentPtr("ws_link", it.?);
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

    if (best) |b| r.focus(b) else moveFocusCyclic(1);
}

pub fn swapNode(target: ipc.FocusTarget) void {
    const sel = w.wm.sel_client orelse return;
    const sel_n = sel.bsp_node orelse return;
    const sel_cx: i32 = sel_n.x + @as(i32, @intCast(sel_n.w / 2));
    const sel_cy: i32 = sel_n.y + @as(i32, @intCast(sel_n.h / 2));

    var best: ?*w.Client = null;
    var best_dist: i32 = std.math.maxInt(i32);

    const head = w.wsClients(w.wm.ws - 1);
    var it: ?*swc.struct_wl_list = head.next;
    while (it != head) : (it = it.?.next) {
        const cl: *w.Client = @fieldParentPtr("ws_link", it.?);
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
    r.scheduleRetile();
    notify(sub.EVT_CLIENT);
}

pub fn toggleFullscreen() void {
    const cl = w.wm.sel_client orelse return;
    const scr = cl.scr orelse return;
    if (cl.fullscreen) {
        cl.fullscreen = false;
        swc.swc_window_set_stacked(cl.win);
        r.applyDecor(cl, true);
        if (!cl.floating) r.scheduleRetile() else if (cl.fw > 0) swc.swc_window_set_geometry(cl.win, &.{ .x = cl.fx, .y = cl.fy, .width = cl.fw, .height = cl.fh });
    } else {
        var geom: swc.swc_rectangle = undefined;
        if (swc.swc_window_get_geometry(cl.win, &geom)) {
            cl.fx = geom.x;
            cl.fy = geom.y;
            cl.fw = geom.width;
            cl.fh = geom.height;
        }
        cl.fullscreen = true;
        r.applyDecor(cl, true);
        swc.swc_window_set_fullscreen(cl.win, scr.scr);
    }
    notify(sub.EVT_CLIENT);
}

pub fn setFloating(floating: bool) void {
    const cl = w.wm.sel_client orelse return;
    if (cl.floating == floating) return;
    if (floating) {
        if (cl.bsp_node) |n| {
            const ws = &w.wm.workspaces[cl.ws - 1];
            if (ws.focused_node == n) ws.focused_node = null;
            ws.tree.remove(n);
            cl.bsp_node = null;
        }
        cl.floating = true;
        swc.swc_window_set_stacked(cl.win);
        r.scheduleRetile();
    } else {
        const ws = w.curWs();
        const leaf = ws.tree.insert(cl, ws.focused_node) catch return;
        cl.bsp_node = leaf;
        ws.focused_node = leaf;
        cl.floating = false;
        swc.swc_window_set_tiled(cl.win);
        r.scheduleRetile();
    }
    notify(sub.EVT_CLIENT);
}

pub fn setSplit(dir: bsp.Dir) void {
    const ws = w.curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.split_dir = dir;
    r.scheduleRetile();
}

pub fn setRatio(ratio: f32) void {
    const ws = w.curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.ratio = std.math.clamp(ratio, 0.1, 0.9);
    r.scheduleRetile();
}

pub fn rotateSplit() void {
    const ws = w.curWs();
    const node = ws.focused_node orelse return;
    const parent = node.parent orelse return;
    parent.split_dir = if (parent.split_dir == .horizontal) .vertical else .horizontal;
    r.scheduleRetile();
}

pub fn gotoWs(n: u32) void {
    if (n < 1 or n > w.wm.cfg.workspace_count or n == w.wm.ws) return;
    w.wm.ws = n;
    r.syncWindowVisibility();
    r.scheduleRetile();
    r.focus(w.firstWsClient(w.wm.ws));
    notify(sub.EVT_WORKSPACE);
}

pub fn moveToWs(n: u32) void {
    const cl = w.wm.sel_client orelse return;
    if (n < 1 or n > w.wm.cfg.workspace_count or cl.ws == n) return;

    if (!cl.floating) {
        const old_ws = &w.wm.workspaces[cl.ws - 1];
        if (cl.bsp_node) |leaf| {
            if (old_ws.focused_node == leaf) old_ws.focused_node = null;
            old_ws.tree.remove(leaf);
            cl.bsp_node = null;
        }
    }
    swc.wl_list_remove(&cl.ws_link);
    cl.ws = n;
    swc.wl_list_insert(w.wsClients(n - 1), &cl.ws_link);

    if (!cl.floating) {
        const new_ws = &w.wm.workspaces[n - 1];
        const leaf = new_ws.tree.insert(cl, new_ws.focused_node) catch return;
        cl.bsp_node = leaf;
    }

    if (cl.ws != w.wm.ws) swc.swc_window_hide(cl.win) else swc.swc_window_show(cl.win);
    r.scheduleRetile();
    r.focus(w.firstWsClient(w.wm.ws));
    notify(sub.EVT_WORKSPACE | sub.EVT_CLIENT);
}

pub fn setWorkspaceCount(count: u32) void {
    const new_count = std.math.clamp(count, 1, 10);
    const old_count = w.wm.cfg.workspace_count;
    if (new_count == old_count) return;

    if (new_count < old_count) {
        var ws_idx: u32 = new_count;
        while (ws_idx < old_count) : (ws_idx += 1) {
            const src = &w.wm.workspaces[ws_idx];
            while (swc.wl_list_empty(&src.clients) == 0) {
                const next_ptr: *swc.struct_wl_list = @ptrCast(src.clients.next.?);
                const cl: *w.Client = @fieldParentPtr("ws_link", next_ptr);
                if (!cl.floating) {
                    if (cl.bsp_node) |leaf| {
                        if (src.focused_node == leaf) src.focused_node = null;
                        src.tree.remove(leaf);
                        cl.bsp_node = null;
                    }
                }
                swc.wl_list_remove(&cl.ws_link);
                cl.ws = new_count;
                swc.wl_list_insert(w.wsClients(new_count - 1), &cl.ws_link);
                if (!cl.floating) {
                    const dst = &w.wm.workspaces[new_count - 1];
                    const leaf = dst.tree.insert(cl, dst.focused_node) catch continue;
                    cl.bsp_node = leaf;
                    dst.focused_node = leaf;
                }
                if (cl.ws == w.wm.ws) swc.swc_window_show(cl.win) else swc.swc_window_hide(cl.win);
            }
        }
        if (w.wm.ws > new_count) {
            w.wm.ws = new_count;
            r.syncWindowVisibility();
        }
    }

    w.wm.cfg.workspace_count = new_count;
    r.retile(null);
    r.focus(w.firstWsClient(w.wm.ws));
    notify(sub.EVT_WORKSPACE | sub.EVT_CONFIG);
}

pub fn spawnCmd(cmd_str: []const u8) void {
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
