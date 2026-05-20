const std = @import("std");
const swc = @import("swc");
const ipc = @import("ipc.zig");
const w = @import("wm.zig");
const sub = @import("subscriber.zig");
const dispatch = @import("dispatch.zig");
const notify = @import("json.zig").notify;
const mouseRelease = @import("actions.zig").mouseRelease;

pub fn modeName(m: *const w.Mode) []const u8 {
    return m.name[0..m.name_len];
}

pub fn findMode(name: []const u8) ?usize {
    for (w.wm.modes[0..w.wm.mode_count], 0..) |*m, i| {
        if (std.mem.eql(u8, modeName(m), name)) return i;
    }
    return null;
}

pub fn defineMode(name: []const u8) !usize {
    if (findMode(name)) |i| return i;
    if (w.wm.mode_count >= w.MAX_MODES) return error.OutOfMemory;
    const idx = w.wm.mode_count;
    w.wm.mode_count += 1;
    const m = &w.wm.modes[idx];
    m.* = .{};
    const copy_len = @min(name.len, w.MODE_NAME_MAX - 1);
    @memcpy(m.name[0..copy_len], name[0..copy_len]);
    m.name_len = copy_len;
    swc.wl_list_init(&m.binds);
    swc.wl_list_init(&m.mouse_binds);
    return idx;
}

pub fn onKeyFire(data: ?*anyopaque, _: u32, _: u32, state: u32) callconv(.c) void {
    if (state != 1) return;
    const bind: *w.Bind = @ptrCast(@alignCast(data orelse return));
    if (bind.mode_idx != w.wm.mode_idx) return;
    const cmd = ipc.parse(bind.command) catch return;
    dispatch.dispatchCmd(cmd, -1);
}

pub fn registerBind(bind: *w.Bind) void {
    _ = swc.swc_add_binding(
        swc.SWC_BINDING_KEY,
        bind.mods,
        bind.sym,
        onKeyFire,
        bind,
    );
}

pub fn unregisterBind(bind: *w.Bind) void {
    _ = swc.swc_remove_binding(swc.SWC_BINDING_KEY, bind.mods, bind.sym);
}

pub fn onMouseFire(data: ?*anyopaque, _: u32, _: u32, state: u32) callconv(.c) void {
    std.log.debug("mouse fired", .{});
    if (state == swc.WL_POINTER_BUTTON_STATE_RELEASED) {
        mouseRelease();
        return;
    }
    const bind: *w.MouseBind = @ptrCast(@alignCast(data orelse return));
    if (bind.mode_idx != w.wm.mode_idx) return;
    const cmd = ipc.parse(bind.command) catch return;
    dispatch.dispatchCmd(cmd, -1);
}

pub fn registerMouseBind(bind: *w.MouseBind) void {
    const ret = swc.swc_add_binding(
        swc.SWC_BINDING_BUTTON,
        bind.mods,
        bind.button,
        onMouseFire,
        bind,
    );
    std.log.debug("registerMouseBind mods={x} button={x} ret={d}", .{ bind.mods, bind.button, ret });
}

pub fn unregisterMouseBind(bind: *w.MouseBind) void {
    _ = swc.swc_remove_binding(swc.SWC_BINDING_BUTTON, bind.mods, bind.button);
}

pub fn activateMode(idx: usize) void {
    if (idx == w.wm.mode_idx) return;

    const old_m = &w.wm.modes[w.wm.mode_idx];
    var it: ?*swc.struct_wl_list = old_m.binds.next;
    while (it != &old_m.binds) : (it = it.?.next) {
        const b: *w.Bind = @fieldParentPtr("link", it.?);
        unregisterBind(b);
    }
    it = old_m.mouse_binds.next;
    while (it != &old_m.mouse_binds) : (it = it.?.next) {
        const b: *w.MouseBind = @fieldParentPtr("link", it.?);
        unregisterMouseBind(b);
    }

    w.wm.mode_idx = idx;

    const new_m = &w.wm.modes[idx];
    it = new_m.binds.next;
    while (it != &new_m.binds) : (it = it.?.next) {
        const b: *w.Bind = @fieldParentPtr("link", it.?);
        registerBind(b);
    }
    it = new_m.mouse_binds.next;
    while (it != &new_m.mouse_binds) : (it = it.?.next) {
        const b: *w.MouseBind = @fieldParentPtr("link", it.?);
        registerMouseBind(b);
    }

    notify(sub.EVT_MODE);
}

pub fn addBind(def: ipc.BindDef) void {
    const mode_idx = defineMode(def.mode) catch return;
    const m = &w.wm.modes[mode_idx];
    var it: ?*swc.struct_wl_list = m.binds.next;
    while (it != &m.binds) : (it = it.?.next) {
        const b: *w.Bind = @fieldParentPtr("link", it.?);
        if (b.mods == def.key.mods and b.sym == def.key.sym) {
            if (mode_idx == w.wm.mode_idx) unregisterBind(b);
            w.gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            w.gpa.destroy(b);
            break;
        }
    }
    const bind = w.gpa.create(w.Bind) catch return;
    bind.* = .{
        .mods = def.key.mods,
        .sym = def.key.sym,
        .command = w.gpa.dupe(u8, def.command) catch {
            w.gpa.destroy(bind);
            return;
        },
        .mode_idx = mode_idx,
        .link = undefined,
    };
    swc.wl_list_insert(&m.binds, &bind.link);
    if (mode_idx == w.wm.mode_idx) registerBind(bind);
}

pub fn addMouseBind(def: ipc.MouseBindDef) void {
    std.log.debug("addMouseBind called mode={s} mods={x} button={x} cmd={s}", .{ def.mode, def.mods, def.button, def.command });

    const mode_idx = defineMode(def.mode) catch return;
    const m = &w.wm.modes[mode_idx];
    var it: ?*swc.struct_wl_list = m.mouse_binds.next;
    while (it != &m.mouse_binds) : (it = it.?.next) {
        const b: *w.MouseBind = @fieldParentPtr("link", it.?);
        if (b.mods == def.mods and b.button == def.button) {
            if (mode_idx == w.wm.mode_idx) unregisterMouseBind(b);
            w.gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            w.gpa.destroy(b);
            break;
        }
    }
    const bind = w.gpa.create(w.MouseBind) catch return;
    bind.* = .{
        .mods = def.mods,
        .button = def.button,
        .command = w.gpa.dupe(u8, def.command) catch {
            w.gpa.destroy(bind);
            return;
        },
        .mode_idx = mode_idx,
        .link = undefined,
    };
    std.log.debug("addMouseBind mods={x} button={x} cmd={s}", .{ def.mods, def.button, def.command });
    swc.wl_list_insert(&m.mouse_binds, &bind.link);
    if (mode_idx == w.wm.mode_idx) registerMouseBind(bind);
}

pub fn removeBind(mode_name: []const u8, key: ipc.BindKey) void {
    const mode_idx = findMode(mode_name) orelse return;
    const m = &w.wm.modes[mode_idx];
    var it: ?*swc.struct_wl_list = m.binds.next;
    while (it != &m.binds) : (it = it.?.next) {
        const b: *w.Bind = @fieldParentPtr("link", it.?);
        if (b.mods == key.mods and b.sym == key.sym) {
            if (mode_idx == w.wm.mode_idx) unregisterBind(b);
            w.gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            w.gpa.destroy(b);
            return;
        }
    }
}

pub fn destroyMode(idx: usize) void {
    if (idx == 0) return;
    const m = &w.wm.modes[idx];
    if (w.wm.mode_idx == idx) activateMode(0);
    while (swc.wl_list_empty(&m.binds) == 0) {
        const next_ptr: *swc.struct_wl_list = @ptrCast(m.binds.next.?);
        const b: *w.Bind = @fieldParentPtr("link", next_ptr);
        w.gpa.free(b.command);
        swc.wl_list_remove(&b.link);
        w.gpa.destroy(b);
    }
    while (swc.wl_list_empty(&m.mouse_binds) == 0) {
        const next_ptr: *swc.struct_wl_list = @ptrCast(m.mouse_binds.next.?);
        const b: *w.MouseBind = @fieldParentPtr("link", next_ptr);
        w.gpa.free(b.command);
        swc.wl_list_remove(&b.link);
        w.gpa.destroy(b);
    }
    var i = idx;
    while (i + 1 < w.wm.mode_count) : (i += 1) w.wm.modes[i] = w.wm.modes[i + 1];
    w.wm.mode_count -= 1;
    if (w.wm.mode_idx > idx) w.wm.mode_idx -= 1;
}

pub fn freeAllModes() void {
    for (w.wm.modes[0..w.wm.mode_count]) |*m| {
        while (swc.wl_list_empty(&m.binds) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(m.binds.next.?);
            const b: *w.Bind = @fieldParentPtr("link", next_ptr);
            w.gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            w.gpa.destroy(b);
        }
        while (swc.wl_list_empty(&m.mouse_binds) == 0) {
            const next_ptr: *swc.struct_wl_list = @ptrCast(m.mouse_binds.next.?);
            const b: *w.MouseBind = @fieldParentPtr("link", next_ptr);
            w.gpa.free(b.command);
            swc.wl_list_remove(&b.link);
            w.gpa.destroy(b);
        }
    }
}
