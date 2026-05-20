const std = @import("std");
const swc = @import("swc");
const ipc = @import("ipc.zig");
const w = @import("wm.zig");
const r = @import("render.zig");
const act = @import("actions.zig");
const kb = @import("keybind.zig");
const j = @import("json.zig");
const sub = @import("subscriber.zig");
const autostart = @import("main.zig").runAutostart;

pub fn dispatchCmd(cmd: ipc.Command, reply_fd: c_int) void {
    switch (cmd) {
        .node => |c| dispatchNode(c),
        .desktop => |c| dispatchDesktop(c),
        .config => |c| dispatchConfig(c, reply_fd),
        .bind => |c| dispatchBind(c, reply_fd),
        .mode => |c| dispatchMode(c),
        .wm => |c| dispatchWm(c),
        .query => |c| j.dispatchQuery(c, reply_fd),
        .follow => {},
    }
}

fn dispatchNode(cmd: ipc.NodeCmd) void {
    switch (cmd) {
        .focus => |t| act.moveFocus(t),
        .swap => |t| act.swapNode(t),
        .kill, .close => {
            if (w.wm.sel_client) |cl| swc.swc_window_close(cl.win);
        },
        .fullscreen => act.toggleFullscreen(),
        .floating => act.setFloating(true),
        .tiling => act.setFloating(false),
        .toggle_floating => act.toggleFloating(),
        .rotate => act.rotateSplit(),
        .ratio => |v| act.setRatio(v),
        .split => |d| act.setSplit(d),
    }
}

fn dispatchDesktop(cmd: ipc.DesktopCmd) void {
    switch (cmd) {
        .focus => |n| act.gotoWs(n),
        .send => |n| act.moveToWs(n),
        .count => |n| act.setWorkspaceCount(n),
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
    var wr: std.Io.Writer = .fixed(&buf);
    const cfg = &w.wm.cfg;
    wr.writeAll("{\"") catch return;
    wr.writeAll(@tagName(key)) catch return;
    wr.writeAll("\":") catch return;
    switch (key) {
        .border_width => wr.print("{d}", .{cfg.border_width}) catch return,
        .border_outer_width => wr.print("{d}", .{cfg.border_outer_width}) catch return,
        .border_color_active => wr.print("{x:0>8}", .{cfg.border_color_active}) catch return,
        .border_color_normal => wr.print("{x:0>8}", .{cfg.border_color_normal}) catch return,
        .border_outer_color_active => wr.print("{x:0>8}", .{cfg.border_outer_color_active}) catch return,
        .border_outer_color_normal => wr.print("{x:0>8}", .{cfg.border_outer_color_normal}) catch return,
        .gap_inner => wr.print("{d}", .{cfg.gap_inner}) catch return,
        .gap_outer => wr.print("{d}", .{cfg.gap_outer}) catch return,
        .wallpaper_color => wr.print("{x:0>8}", .{cfg.wallpaper_color}) catch return,
        .decor => {
            if (w.wm.sel_client) |cl| wr.print("{}", .{cl.decor_enabled}) catch return else wr.writeAll("null") catch return;
        },
        .decor_default => wr.print("{}", .{cfg.decor_default}) catch return,
        .workspace_count => wr.print("{d}", .{cfg.workspace_count}) catch return,
        .motion_throttle_hz => wr.print("{d}", .{cfg.motion_throttle_hz}) catch return,
    }
    wr.writeAll("}\n") catch return;
    const out = wr.buffered();
    _ = swc.write(fd, out.ptr, out.len);
}

fn applyConfig(s: ipc.ConfigSet) void {
    const cfg = &w.wm.cfg;
    switch (s) {
        .border_width => |v| {
            cfg.border_width = v;
            r.reapplyBorders();
        },
        .border_outer_width => |v| {
            cfg.border_outer_width = v;
            r.reapplyBorders();
        },
        .border_color_active => |v| {
            cfg.border_color_active = v;
            r.reapplyBorders();
        },
        .border_color_normal => |v| {
            cfg.border_color_normal = v;
            r.reapplyBorders();
        },
        .border_outer_color_active => |v| {
            cfg.border_outer_color_active = v;
            r.reapplyBorders();
        },
        .border_outer_color_normal => |v| {
            cfg.border_outer_color_normal = v;
            r.reapplyBorders();
        },
        .gap_inner => |v| {
            cfg.gap_inner = v;
            r.scheduleRetile();
        },
        .gap_outer => |v| {
            cfg.gap_outer = v;
            r.scheduleRetile();
        },
        .wallpaper_color => |v| {
            cfg.wallpaper_color = v;
            swc.swc_wallpaper_color_set(v);
        },
        .decor => |v| r.setDecorFocused(v),
        .decor_default => |v| {
            cfg.decor_default = v;
        },
        .workspace_count => |v| act.setWorkspaceCount(v),
        .motion_throttle_hz => |v| {
            cfg.motion_throttle_hz = v;
        },
    }
    j.notify(sub.EVT_CONFIG);
}

fn dispatchBind(cmd: ipc.BindCmd, reply_fd: c_int) void {
    std.log.debug("dispatchBind tag={s}", .{@tagName(cmd)});
    switch (cmd) {
        .add => |def| kb.addBind(def),
        .list => |name| {
            if (reply_fd < 0) return;
            var buf: [16384]u8 = undefined;
            var wr: std.Io.Writer = .fixed(&buf);
            j.writeBindsJson(name, &wr) catch return;
            _ = wr.writeByte('\n') catch {};
            const out = wr.buffered();
            _ = swc.write(reply_fd, out.ptr, out.len);
        },
        .mouse_add => |def| kb.addMouseBind(def),
        .mouse_list => |name| {
            if (reply_fd < 0) return;
            var buf: [16384]u8 = undefined;
            var wr: std.Io.Writer = .fixed(&buf);
            j.writeMouseBindsJson(name, &wr) catch return;
            _ = wr.writeByte('\n') catch {};
            const out = wr.buffered();
            _ = swc.write(reply_fd, out.ptr, out.len);
        },
    }
}

fn dispatchMode(cmd: ipc.ModeCmd) void {
    switch (cmd) {
        .enter => |name| {
            if (kb.findMode(name)) |i| kb.activateMode(i);
        },
        .leave => kb.activateMode(0),
        .define => |name| {
            _ = kb.defineMode(name) catch {};
        },
        .remove => |name| {
            if (kb.findMode(name)) |i| kb.destroyMode(i);
        },
    }
}

fn dispatchWm(cmd: ipc.WmCmd) void {
    switch (cmd) {
        .quit => swc.wl_display_terminate(w.wm.dpy),
        .reload => runAutostart(),
        .spawn => |s| act.spawnCmd(s),
        .mouse_move => act.mouseMove(),
        .mouse_resize => |edge| act.mouseResize(edge),
    }
}

fn runAutostart() void {
    autostart();
}
