const std = @import("std");
const bsp = @import("bsp.zig");

pub const Command = union(enum) {
    focus_next,
    focus_prev,
    focus_dir: Dir,
    kill,
    fullscreen,
    floating,
    tiling,
    split: bsp.Dir,
    ratio: f32,
    rotate,

    gap_inner: u32,
    gap_outer: u32,

    // inner border
    border_width: u32,
    border_color_active: u32,
    border_color_normal: u32,
    // outer border
    border_outer_width: u32,
    border_outer_color_active: u32,
    border_outer_color_normal: u32,

    wallpaper_color: u32,

    // server-side decorations
    decor_focused: bool,
    decor_global: bool,

    workspace_goto: u32,
    workspace_move: u32,
    workspace_count: u32, // workspaces <n>

    spawn: []const u8,

    quit,

    query_focused, // replies with pid
    query_workspaces, // replies with "count <n>\ncurrent <n>\n"

    pub const Dir = enum { left, right, up, down };
};

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    BadInteger,
    BadFloat,
    BadColor,
};

pub fn parse(line: []const u8) ParseError!Command {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r"), ' ');
    const verb = it.next() orelse return ParseError.UnknownCommand;

    if (std.mem.eql(u8, verb, "focus")) {
        const arg = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, arg, "next")) return .focus_next;
        if (std.mem.eql(u8, arg, "prev")) return .focus_prev;
        if (std.mem.eql(u8, arg, "left")) return .{ .focus_dir = .left };
        if (std.mem.eql(u8, arg, "right")) return .{ .focus_dir = .right };
        if (std.mem.eql(u8, arg, "up")) return .{ .focus_dir = .up };
        if (std.mem.eql(u8, arg, "down")) return .{ .focus_dir = .down };
        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, verb, "kill")) return .kill;
    if (std.mem.eql(u8, verb, "fullscreen")) return .fullscreen;
    if (std.mem.eql(u8, verb, "floating")) return .floating;
    if (std.mem.eql(u8, verb, "tiling")) return .tiling;
    if (std.mem.eql(u8, verb, "rotate")) return .rotate;
    if (std.mem.eql(u8, verb, "quit")) return .quit;

    if (std.mem.eql(u8, verb, "query")) {
        const arg = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, arg, "focused")) return .query_focused;
        if (std.mem.eql(u8, arg, "workspaces")) return .query_workspaces;
        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, verb, "split")) {
        const arg = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, arg, "h") or std.mem.eql(u8, arg, "horizontal"))
            return .{ .split = .horizontal };
        if (std.mem.eql(u8, arg, "v") or std.mem.eql(u8, arg, "vertical"))
            return .{ .split = .vertical };
        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, verb, "ratio")) {
        const arg = it.next() orelse return ParseError.MissingArgument;
        const v = std.fmt.parseFloat(f32, arg) catch return ParseError.BadFloat;
        return .{ .ratio = v };
    }

    if (std.mem.eql(u8, verb, "gap")) {
        const sub = it.next() orelse return ParseError.MissingArgument;
        const val = parseUint(&it) catch return ParseError.BadInteger;
        if (std.mem.eql(u8, sub, "inner")) return .{ .gap_inner = val };
        if (std.mem.eql(u8, sub, "outer")) return .{ .gap_outer = val };
        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, verb, "border")) {
        const sub = it.next() orelse return ParseError.MissingArgument;

        // --- Width ---

        if (std.mem.eql(u8, sub, "width") or std.mem.eql(u8, sub, "inner_width")) {
            const val = parseUint(&it) catch return ParseError.BadInteger;
            return .{ .border_width = val };
        }
        if (std.mem.eql(u8, sub, "outer_width")) {
            const val = parseUint(&it) catch return ParseError.BadInteger;
            return .{ .border_outer_width = val };
        }

        // --- Colors ---
        if (std.mem.eql(u8, sub, "color") or std.mem.eql(u8, sub, "inner_color")) {
            const which = it.next() orelse return ParseError.MissingArgument;
            const col = parseHex(&it) catch return ParseError.BadColor;
            if (std.mem.eql(u8, which, "active")) return .{ .border_color_active = col };
            if (std.mem.eql(u8, which, "normal")) return .{ .border_color_normal = col };
            // back-compat outer qualifiers on the old "color" sub-command
            if (std.mem.eql(u8, which, "outer_active")) return .{ .border_outer_color_active = col };
            if (std.mem.eql(u8, which, "outer_normal")) return .{ .border_outer_color_normal = col };
            return ParseError.UnknownCommand;
        }
        if (std.mem.eql(u8, sub, "outer_color")) {
            const which = it.next() orelse return ParseError.MissingArgument;
            const col = parseHex(&it) catch return ParseError.BadColor;
            if (std.mem.eql(u8, which, "active")) return .{ .border_outer_color_active = col };
            if (std.mem.eql(u8, which, "normal")) return .{ .border_outer_color_normal = col };
            return ParseError.UnknownCommand;
        }

        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, verb, "wallpaper")) {
        const sub = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, sub, "color")) {
            const col = parseHex(&it) catch return ParseError.BadColor;
            return .{ .wallpaper_color = col };
        }
        return ParseError.UnknownCommand;
    }

    // --- Decor ---

    if (std.mem.eql(u8, verb, "decor")) {
        const sub = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, sub, "global")) {
            const val = it.next() orelse return ParseError.MissingArgument;
            if (std.mem.eql(u8, val, "on")) return .{ .decor_global = true };
            if (std.mem.eql(u8, val, "off")) return .{ .decor_global = false };
            return ParseError.UnknownCommand;
        }
        if (std.mem.eql(u8, sub, "on")) return .{ .decor_focused = true };
        if (std.mem.eql(u8, sub, "off")) return .{ .decor_focused = false };
        return ParseError.UnknownCommand;
    }

    // --- Workspaces ---

    if (std.mem.eql(u8, verb, "workspaces")) {
        const val = parseUint(&it) catch return ParseError.BadInteger;
        return .{ .workspace_count = val };
    }

    if (std.mem.eql(u8, verb, "workspace")) {
        const sub = it.next() orelse return ParseError.MissingArgument;
        if (std.mem.eql(u8, sub, "goto")) {
            const val = parseUint(&it) catch return ParseError.BadInteger;
            return .{ .workspace_goto = val };
        }
        if (std.mem.eql(u8, sub, "move")) {
            const val = parseUint(&it) catch return ParseError.BadInteger;
            return .{ .workspace_move = val };
        }
        // bare number
        const val = std.fmt.parseInt(u32, sub, 10) catch return ParseError.BadInteger;
        return .{ .workspace_goto = val };
    }

    if (std.mem.eql(u8, verb, "spawn")) {
        const rest = std.mem.trim(u8, it.rest(), " \t");
        if (rest.len == 0) return ParseError.MissingArgument;
        return .{ .spawn = rest };
    }

    return ParseError.UnknownCommand;
}

// --- Helpers ---

fn parseUint(it: *std.mem.SplitIterator(u8, .scalar)) !u32 {
    const s = it.next() orelse return error.MissingArgument;
    return std.fmt.parseInt(u32, s, 10);
}

fn parseHex(it: *std.mem.SplitIterator(u8, .scalar)) !u32 {
    const s = it.next() orelse return error.MissingArgument;
    return std.fmt.parseInt(u32, s, 16);
}
