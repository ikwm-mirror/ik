const std = @import("std");
const swc = @import("swc");
const bsp = @import("bsp.zig");

// --- Types ---

pub const Command = union(enum) {
    node: NodeCmd,
    desktop: DesktopCmd,
    config: ConfigCmd,
    bind: BindCmd,
    mode: ModeCmd,
    wm: WmCmd,
    query: QueryCmd,
    follow: FollowCmd,
};

pub const NodeCmd = union(enum) {
    focus: FocusTarget,
    kill,
    close,
    fullscreen,
    floating,
    tiling,
    split: bsp.Dir,
    rotate,
    ratio: f32,
    swap: FocusTarget,
};

pub const FocusTarget = enum { next, prev, left, right, up, down };

pub const DesktopCmd = union(enum) {
    focus: u32,
    send: u32,
    count: u32,
};

pub const ConfigCmd = union(enum) {
    get: ConfigKey,
    set: ConfigSet,
};

pub const ConfigKey = enum {
    border_width,
    border_outer_width,
    border_color_active,
    border_color_normal,
    border_outer_color_active,
    border_outer_color_normal,
    gap_inner,
    gap_outer,
    wallpaper_color,
    decor,
    decor_default,
    workspace_count,
    motion_throttle_hz,
};

pub const ConfigSet = union(enum) {
    border_width: u32,
    border_outer_width: u32,
    border_color_active: u32,
    border_color_normal: u32,
    border_outer_color_active: u32,
    border_outer_color_normal: u32,
    gap_inner: u32,
    gap_outer: u32,
    wallpaper_color: u32,
    decor: bool,
    decor_default: bool,
    workspace_count: u32,
    motion_throttle_hz: u32,
};

pub const BindCmd = union(enum) {
    add: BindDef,
    list: []const u8,
};

pub const BindDef = struct {
    mode: []const u8,
    key: BindKey,
    command: []const u8,
};

pub const BindRemove = struct {
    mode: []const u8,
    key: BindKey,
};

pub const BindKey = struct {
    mods: u32,
    sym: u32,
};

pub const ModeCmd = union(enum) {
    enter: []const u8,
    leave,
    define: []const u8,
    remove: []const u8,
};

pub const WmCmd = union(enum) {
    quit,
    spawn: []const u8,
    reload,
};

pub const QueryCmd = union(enum) {
    focused,
    workspaces,
    clients: ClientScope,
    mode,
    binds: []const u8,
    config,
    status,
};

pub const ClientScope = enum { current, all };

// follow <events...>
pub const FollowCmd = struct {
    mask: u32,
};

pub const BindCmd2 = BindCmd; // alias

// --- Errors ---

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    BadInteger,
    BadFloat,
    BadColor,
    BadKey,
};

// --- Tokenizer ---

pub const Tokenizer = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(s: []const u8) Tokenizer {
        return .{ .buf = std.mem.trim(u8, s, " \t\r") };
    }

    pub fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.buf.len and self.buf[self.pos] == ' ') self.pos += 1;
        if (self.pos >= self.buf.len) return null;
        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != ' ') self.pos += 1;
        return self.buf[start..self.pos];
    }

    pub fn rest(self: *Tokenizer) []const u8 {
        while (self.pos < self.buf.len and self.buf[self.pos] == ' ') self.pos += 1;
        return self.buf[self.pos..];
    }

    pub fn require(self: *Tokenizer) ParseError![]const u8 {
        return self.next() orelse error.MissingArgument;
    }
};

// --- Comptime Helpers ---

fn matchEnum(comptime E: type, s: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
    }
    return null;
}

fn requireEnum(comptime E: type, t: *Tokenizer) ParseError!E {
    return matchEnum(E, try t.require()) orelse error.UnknownCommand;
}

fn parseUint(t: *Tokenizer) ParseError!u32 {
    return std.fmt.parseInt(u32, try t.require(), 10) catch error.BadInteger;
}

fn parseFloat(t: *Tokenizer) ParseError!f32 {
    return std.fmt.parseFloat(f32, try t.require()) catch error.BadFloat;
}

fn parseHex(t: *Tokenizer) ParseError!u32 {
    return std.fmt.parseInt(u32, try t.require(), 16) catch error.BadColor;
}

fn parseBool(t: *Tokenizer) ParseError!bool {
    const s = try t.require();
    if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false")) return false;
    return error.UnknownCommand;
}

fn parseAs(comptime T: type, t: *Tokenizer) ParseError!T {
    return switch (T) {
        u32 => parseHex(t) catch parseUint(t),
        f32 => parseFloat(t),
        bool => parseBool(t),
        else => @compileError("unhandled config type: " ++ @typeName(T)),
    };
}

// --- Key Parsing ---

pub const MOD_CTRL: u32 = swc.SWC_MOD_CTRL; // 1 << 0
pub const MOD_ALT: u32 = swc.SWC_MOD_ALT; // 1 << 1
pub const MOD_SUPER: u32 = swc.SWC_MOD_LOGO; // 1 << 2
pub const MOD_SHIFT: u32 = swc.SWC_MOD_SHIFT; // 1 << 3

fn parseMod(s: []const u8) ?u32 {
    if (std.mem.eql(u8, s, "shift")) return MOD_SHIFT;
    if (std.mem.eql(u8, s, "ctrl") or std.mem.eql(u8, s, "control")) return MOD_CTRL;
    if (std.mem.eql(u8, s, "alt") or std.mem.eql(u8, s, "mod1")) return MOD_ALT;
    if (std.mem.eql(u8, s, "super") or std.mem.eql(u8, s, "mod4") or
        std.mem.eql(u8, s, "windows")) return MOD_SUPER;
    return null;
}

extern fn xkb_keysym_from_name(name: [*:0]const u8, flags: u32) u32;
const XKB_KEYSYM_NO_FLAGS: u32 = 0;
const XKB_KEY_NoSymbol: u32 = 0;

pub fn parseBindKey(s: []const u8) ParseError!BindKey {
    var mods: u32 = 0;
    var tail = s;

    while (std.mem.indexOf(u8, tail, "+")) |plus| {
        const part = tail[0..plus];
        const m = parseMod(part) orelse break;
        mods |= m;
        tail = tail[plus + 1 ..];
    }

    var sym_buf: [64:0]u8 = undefined;
    const copy_len = @min(tail.len, sym_buf.len - 1);
    @memcpy(sym_buf[0..copy_len], tail[0..copy_len]);
    sym_buf[copy_len] = 0;

    const sym = xkb_keysym_from_name(&sym_buf, XKB_KEYSYM_NO_FLAGS);
    if (sym == XKB_KEY_NoSymbol) return error.BadKey;
    return .{ .mods = mods, .sym = sym };
}

// --- Domain Parsers ---

fn parseNode(t: *Tokenizer) ParseError!NodeCmd {
    const verb = try t.require();
    if (std.mem.eql(u8, verb, "focus")) return .{ .focus = try requireEnum(FocusTarget, t) };
    if (std.mem.eql(u8, verb, "swap")) return .{ .swap = try requireEnum(FocusTarget, t) };
    if (std.mem.eql(u8, verb, "kill")) return .kill;
    if (std.mem.eql(u8, verb, "close")) return .close;
    if (std.mem.eql(u8, verb, "fullscreen")) return .fullscreen;
    if (std.mem.eql(u8, verb, "floating")) return .floating;
    if (std.mem.eql(u8, verb, "tiling")) return .tiling;
    if (std.mem.eql(u8, verb, "rotate")) return .rotate;
    if (std.mem.eql(u8, verb, "ratio")) return .{ .ratio = try parseFloat(t) };
    if (std.mem.eql(u8, verb, "split")) {
        const s = try t.require();
        if (std.mem.eql(u8, s, "h") or std.mem.eql(u8, s, "horizontal")) return .{ .split = .horizontal };
        if (std.mem.eql(u8, s, "v") or std.mem.eql(u8, s, "vertical")) return .{ .split = .vertical };
    }
    return error.UnknownCommand;
}

fn parseDesktop(t: *Tokenizer) ParseError!DesktopCmd {
    const verb = try t.require();
    if (std.mem.eql(u8, verb, "focus")) return .{ .focus = try parseUint(t) };
    if (std.mem.eql(u8, verb, "send")) return .{ .send = try parseUint(t) };
    if (std.mem.eql(u8, verb, "count")) return .{ .count = try parseUint(t) };
    return error.UnknownCommand;
}

fn parseConfig(t: *Tokenizer) ParseError!ConfigCmd {
    const verb = try t.require();

    if (std.mem.eql(u8, verb, "get")) {
        return .{ .get = matchEnum(ConfigKey, try t.require()) orelse return error.UnknownCommand };
    }

    if (std.mem.eql(u8, verb, "set")) {
        const key = try t.require();
        inline for (@typeInfo(ConfigSet).@"union".fields) |f| {
            if (std.mem.eql(u8, f.name, key)) {
                return .{ .set = @unionInit(ConfigSet, f.name, try parseAs(f.type, t)) };
            }
        }
        return error.UnknownCommand;
    }

    return error.UnknownCommand;
}

fn parseBind(t: *Tokenizer) ParseError!BindCmd {
    const verb = try t.require();

    if (std.mem.eql(u8, verb, "add")) {
        const first = try t.require();
        var mode: []const u8 = "default";
        var key_str: []const u8 = first;
        if (!std.mem.containsAtLeast(u8, first, 1, "+") and parseMod(first) == null) {
            mode = first;
            key_str = try t.require();
        }
        const key = try parseBindKey(key_str);
        const cmd = t.rest();
        if (cmd.len == 0) return error.MissingArgument;
        return .{ .add = .{ .mode = mode, .key = key, .command = cmd } };
    }

    if (std.mem.eql(u8, verb, "list")) {
        return .{ .list = t.next() orelse "default" };
    }

    return error.UnknownCommand;
}

fn parseMode(t: *Tokenizer) ParseError!ModeCmd {
    const verb = try t.require();
    if (std.mem.eql(u8, verb, "enter")) return .{ .enter = try t.require() };
    if (std.mem.eql(u8, verb, "leave")) return .leave;
    if (std.mem.eql(u8, verb, "define")) return .{ .define = try t.require() };
    if (std.mem.eql(u8, verb, "remove")) return .{ .remove = try t.require() };
    return error.UnknownCommand;
}

fn parseWm(t: *Tokenizer) ParseError!WmCmd {
    const verb = try t.require();
    if (std.mem.eql(u8, verb, "quit")) return .quit;
    if (std.mem.eql(u8, verb, "reload")) return .reload;
    if (std.mem.eql(u8, verb, "spawn")) {
        const cmd = t.rest();
        if (cmd.len == 0) return error.MissingArgument;
        return .{ .spawn = cmd };
    }
    return error.UnknownCommand;
}

fn parseQuery(t: *Tokenizer) ParseError!QueryCmd {
    const sub = try t.require();
    if (std.mem.eql(u8, sub, "focused")) return .focused;
    if (std.mem.eql(u8, sub, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, sub, "mode")) return .mode;
    if (std.mem.eql(u8, sub, "config")) return .config;
    if (std.mem.eql(u8, sub, "status")) return .status;
    if (std.mem.eql(u8, sub, "binds")) {
        return .{ .binds = t.next() orelse "default" };
    }
    if (std.mem.eql(u8, sub, "clients")) {
        const scope = t.next() orelse "current";
        if (std.mem.eql(u8, scope, "all")) return .{ .clients = .all };
        return .{ .clients = .current };
    }
    return error.UnknownCommand;
}

fn parseFollow(t: *Tokenizer) ParseError!FollowCmd {
    const sub = @import("subscriber.zig");
    var mask: u32 = 0;
    while (t.next()) |tok| {
        mask |= sub.maskFromName(tok) orelse return error.UnknownCommand;
    }
    if (mask == 0) mask = sub.EVT_ALL;
    return .{ .mask = mask };
}

// --- Entry Point ---

pub fn parse(line: []const u8) ParseError!Command {
    var t = Tokenizer.init(line);
    const domain = try t.require();

    if (std.mem.eql(u8, domain, "node")) return .{ .node = try parseNode(&t) };
    if (std.mem.eql(u8, domain, "desktop")) return .{ .desktop = try parseDesktop(&t) };
    if (std.mem.eql(u8, domain, "config")) return .{ .config = try parseConfig(&t) };
    if (std.mem.eql(u8, domain, "bind")) return .{ .bind = try parseBind(&t) };
    if (std.mem.eql(u8, domain, "mode")) return .{ .mode = try parseMode(&t) };
    if (std.mem.eql(u8, domain, "wm")) return .{ .wm = try parseWm(&t) };
    if (std.mem.eql(u8, domain, "query")) return .{ .query = try parseQuery(&t) };
    if (std.mem.eql(u8, domain, "follow")) return .{ .follow = try parseFollow(&t) };

    return error.UnknownCommand;
}
