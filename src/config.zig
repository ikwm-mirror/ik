const swc = @import("swc");
const main = @import("main.zig");

pub const border_width: u32 = 2;
pub const border_outer_width: u32 = 1;

pub const border_color_active: u32 = 0xffb48ead;
pub const border_color_normal: u32 = 0xff3d3d56;
pub const border_outer_color_active: u32 = 0xff6c6f85;
pub const border_outer_color_normal: u32 = 0xff1e1e2e;

pub const wallpaper_color: u32 = 0xff1e1e2e;

pub const motion_throttle_hz: u32 = 60;

pub const decor_template: swc.swc_decor = .{
    .title = .{
        .color = 0xffffffff,
        .string = "ikwm",
    },
};

const MOD = swc.SWC_MOD_LOGO; // super
const MODS = swc.SWC_MOD_LOGO | swc.SWC_MOD_SHIFT;

var ws_args = [9]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

var cmd_term = [_:null]?[*:0]const u8{ "foot", null };
var cmd_run = [_:null]?[*:0]const u8{ "fuzzel", null };

pub const Bind = struct {
    type: c_uint,
    mods: u32,
    ksym: u32,
    handler: swc.swc_binding_handler,
    data: ?*anyopaque,
};

pub const binds = [_]Bind{
    // focus cycling
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_j, .handler = main.actFocusNext, .data = null },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_k, .handler = main.actFocusPrev, .data = null },

    // kill focused
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_q, .handler = main.actKillSel, .data = null },

    // fullscreen
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_f, .handler = main.actFullscreen, .data = null },

    // quit compositor
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_q, .handler = main.actQuit, .data = null },

    // spawn terminal
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_Return, .handler = main.actSpawn, .data = @ptrCast(&cmd_term) },

    // spawn launcher
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_d, .handler = main.actSpawn, .data = @ptrCast(&cmd_run) },

    // mouse move
    .{ .type = swc.SWC_BINDING_BUTTON, .mods = MOD, .ksym = swc.BTN_LEFT, .handler = main.actMouseMove, .data = null },

    // mouse resize
    .{ .type = swc.SWC_BINDING_BUTTON, .mods = MOD, .ksym = swc.BTN_RIGHT, .handler = main.actMouseResize, .data = null },

    // workspace go
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_1, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[0]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_2, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[1]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_3, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[2]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_4, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[3]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_5, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[4]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_6, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[5]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_7, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[6]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_8, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[7]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MOD, .ksym = swc.XKB_KEY_9, .handler = main.actWorkspaceGoto, .data = @ptrCast(&ws_args[8]) },

    // workspace move
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_1, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[0]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_2, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[1]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_3, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[2]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_4, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[3]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_5, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[4]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_6, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[5]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_7, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[6]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_8, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[7]) },
    .{ .type = swc.SWC_BINDING_KEY, .mods = MODS, .ksym = swc.XKB_KEY_9, .handler = main.actWorkspaceMoveto, .data = @ptrCast(&ws_args[8]) },
};
