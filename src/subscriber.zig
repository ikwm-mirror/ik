const std = @import("std");
const swc = @import("swc");
const query = @import("query.zig");

// --- Event mask ---

pub const EVT_WORKSPACE: u32 = 1 << 0;
pub const EVT_FOCUS: u32 = 1 << 1;
pub const EVT_CLIENT: u32 = 1 << 2;
pub const EVT_MODE: u32 = 1 << 3;
pub const EVT_CONFIG: u32 = 1 << 4;
pub const EVT_ALL: u32 = 0xffff_ffff;

pub fn maskFromName(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "workspace")) return EVT_WORKSPACE;
    if (std.mem.eql(u8, name, "focus")) return EVT_FOCUS;
    if (std.mem.eql(u8, name, "client")) return EVT_CLIENT;
    if (std.mem.eql(u8, name, "mode")) return EVT_MODE;
    if (std.mem.eql(u8, name, "config")) return EVT_CONFIG;
    if (std.mem.eql(u8, name, "all")) return EVT_ALL;
    return null;
}

// --- Subscriber ---

pub const Subscriber = struct {
    fd: c_int,
    mask: u32,
    source: *swc.wl_event_source,
    next: ?*Subscriber,
};

// --- Registry ---

pub const Registry = struct {
    head: ?*Subscriber,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .head = null, .alloc = alloc };
    }

    pub fn add(self: *Registry, fd: c_int, mask: u32, source: *swc.wl_event_source) void {
        const s = self.alloc.create(Subscriber) catch return;
        s.* = .{ .fd = fd, .mask = mask, .source = source, .next = self.head };
        self.head = s;
    }

    pub fn emit(self: *Registry, evt_mask: u32, json: []const u8) void {
        var it = self.head;
        var prev_ptr = &self.head;
        while (it) |s| {
            const next = s.next;
            if (s.mask & evt_mask != 0) {
                const n = swc.write(s.fd, json.ptr, json.len);
                if (n <= 0) {
                    _ = swc.wl_event_source_remove(s.source);
                    _ = swc.close(s.fd);
                    prev_ptr.* = next;
                    self.alloc.destroy(s);
                    it = next;
                    continue;
                }
            }
            prev_ptr = &s.next;
            it = next;
        }
    }

    pub fn deinit(self: *Registry) void {
        var it = self.head;
        while (it) |s| {
            const next = s.next;
            _ = swc.wl_event_source_remove(s.source);
            _ = swc.close(s.fd);
            self.alloc.destroy(s);
            it = next;
        }
        self.head = null;
    }
};
