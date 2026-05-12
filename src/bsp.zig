const std = @import("std");

pub const Dir = enum { horizontal, vertical };

pub const Node = struct {
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,

    client: ?*anyopaque = null,

    split_dir: Dir = .horizontal,
    ratio: f32 = 0.5,

    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Tree = struct {
    root: ?*Node = null,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Tree {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Tree) void {
        if (self.root) |r| self.freeNode(r);
    }

    fn freeNode(self: *Tree, n: *Node) void {
        if (n.left) |l| self.freeNode(l);
        if (n.right) |r| self.freeNode(r);
        self.alloc.destroy(n);
    }

    fn newNode(self: *Tree) !*Node {
        const n = try self.alloc.create(Node);
        n.* = .{};
        return n;
    }

    pub fn insert(self: *Tree, client: *anyopaque, focused: ?*Node) !*Node {
        const leaf = try self.newNode();
        leaf.client = client;

        if (self.root == null) {
            self.root = leaf;
            return leaf;
        }

        const raw_target = focused orelse self.root.?;
        const target = if (raw_target.client != null) raw_target else firstLeaf(raw_target);

        const internal = try self.newNode();
        internal.parent = target.parent;
        internal.ratio = 0.5;
        internal.x = target.x;
        internal.y = target.y;
        internal.w = target.w;
        internal.h = target.h;

        internal.left = target;
        internal.right = leaf;
        target.parent = internal;
        leaf.parent = internal;

        if (internal.parent) |p| {
            if (p.left == target) p.left = internal else p.right = internal;
        } else {
            self.root = internal;
        }

        return leaf;
    }

    pub fn remove(self: *Tree, leaf: *Node) void {
        const parent = leaf.parent orelse {
            // was root
            self.root = null;
            self.alloc.destroy(leaf);
            return;
        };

        const sibling: *Node = if (parent.left == leaf) parent.right.? else parent.left.?;
        sibling.parent = parent.parent;

        if (parent.parent) |gp| {
            if (gp.left == parent) gp.left = sibling else gp.right = sibling;
        } else {
            self.root = sibling;
        }

        self.alloc.destroy(leaf);
        self.alloc.destroy(parent);
    }

    pub fn layout(
        self: *Tree,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        inner_gap: u32,
        outer_gap: u32,
        cb: *const fn (client: *anyopaque, x: i32, y: i32, w: u32, h: u32) void,
    ) void {
        const root = self.root orelse return;
        const ox: i32 = x + @as(i32, @intCast(outer_gap));
        const oy: i32 = y + @as(i32, @intCast(outer_gap));
        const ow: u32 = if (w > outer_gap * 2) w - outer_gap * 2 else 0;
        const oh: u32 = if (h > outer_gap * 2) h - outer_gap * 2 else 0;
        layoutNode(root, ox, oy, ow, oh, inner_gap, cb);
    }

    fn layoutNode(
        n: *Node,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        inner_gap: u32,
        cb: *const fn (client: *anyopaque, x: i32, y: i32, w: u32, h: u32) void,
    ) void {
        n.x = x;
        n.y = y;
        n.w = w;
        n.h = h;

        if (n.client) |c| {
            cb(c, x, y, w, h);
            return;
        }

        const left = n.left orelse return;
        const right = n.right orelse return;

        const half_gap = inner_gap / 2;
        const effective_dir: Dir = if (w >= h) .horizontal else .vertical;

        switch (effective_dir) {
            .horizontal => {
                const lw: u32 = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * n.ratio));
                const lw_actual = if (lw >= half_gap) lw - half_gap else 0;
                const rx: i32 = x + @as(i32, @intCast(lw + half_gap));
                const rw: u32 = if (w >= lw + half_gap) w - lw - half_gap else 0;
                layoutNode(left, x, y, lw_actual, h, inner_gap, cb);
                layoutNode(right, rx, y, rw, h, inner_gap, cb);
            },
            .vertical => {
                const th: u32 = @as(u32, @intFromFloat(@as(f32, @floatFromInt(h)) * n.ratio));
                const th_actual = if (th >= half_gap) th - half_gap else 0;
                const by: i32 = y + @as(i32, @intCast(th + half_gap));
                const bh: u32 = if (h >= th + half_gap) h - th - half_gap else 0;
                layoutNode(left, x, y, w, th_actual, inner_gap, cb);
                layoutNode(right, x, by, w, bh, inner_gap, cb);
            },
        }
    }

    pub fn firstLeaf(n: *Node) *Node {
        var cur = n;
        while (cur.left) |l| cur = l;
        return cur;
    }

    pub fn forEachLeaf(self: *Tree, cb: *const fn (node: *Node) void) void {
        if (self.root) |r| walkLeaves(r, cb);
    }

    fn walkLeaves(n: *Node, cb: *const fn (node: *Node) void) void {
        if (n.client != null) {
            cb(n);
            return;
        }
        if (n.left) |l| walkLeaves(l, cb);
        if (n.right) |r| walkLeaves(r, cb);
    }

    pub fn findLeaf(self: *Tree, client: *anyopaque) ?*Node {
        return if (self.root) |r| searchLeaf(r, client) else null;
    }

    fn searchLeaf(n: *Node, client: *anyopaque) ?*Node {
        if (n.client) |c| {
            return if (c == client) n else null;
        }
        if (n.left) |l| if (searchLeaf(l, client)) |found| return found;
        if (n.right) |r| if (searchLeaf(r, client)) |found| return found;
        return null;
    }
};
