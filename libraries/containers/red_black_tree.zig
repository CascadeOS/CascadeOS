// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const bitjuggle = @import("bitjuggle");

const Direction = enum(u1) {
    left = 0,
    right = 1,

    inline fn fromValue(value: u1) Direction {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return @enumFromInt(value);
    }

    inline fn toValue(self: Direction) u1 {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return @intFromEnum(self);
    }

    inline fn otherDirection(direction: Direction) Direction {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return Direction.fromValue(1 - direction.toValue());
    }
};

const Color = enum(u1) {
    red = 0,
    black = 1,

    inline fn fromValue(value: u1) Color {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return @enumFromInt(value);
    }

    inline fn toValue(self: Color) u1 {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return @intFromEnum(self);
    }
};

pub const Node = struct {
    children: [2]?*Node = .{ null, null },

    // As @alignOf(Node) is 8 this parent pointer has 3 unused bits, allowing us to store the color in the bottom bit.
    // A new node is always red, which matches up with the pointer being null.
    _parent: usize = 0,

    const ALL_BITS_EXCEPT_FIRST: usize = ~@as(usize, 1);

    inline fn getParent(self: *const Node) ?*Node {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return @ptrFromInt(self._parent & ALL_BITS_EXCEPT_FIRST);
    }

    inline fn setParent(self: *Node, parent: ?*Node) void {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        self._parent = @intFromPtr(parent) | self.getColor().toValue();
    }

    inline fn getColor(self: *const Node) Color {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return Color.fromValue(@truncate(self._parent));
    }

    inline fn setColor(self: *Node, color: Color) void {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        bitjuggle.setBit(&self._parent, 0, color.toValue());
    }

    /// Get direction from parent.
    fn directionWithParent(self: *const Node, parent: *const Node) Direction {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return Direction.fromValue(@intFromBool(parent.children[Direction.right.toValue()] == self));
    }

    /// Get direction from parent. If parent is null, returns left.
    fn direction(self: *const Node) Direction {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        if (self.getParent()) |parent| {
            return directionWithParent(self, parent);
        }

        return .left;
    }

    fn sibling(self: *const Node) ?*Node {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        if (self.getParent()) |parent| {
            return parent.children[self.directionWithParent(parent).otherDirection().toValue()];
        }

        return null;
    }

    inline fn setParentAndColorForRoot(self: *Node) void {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        self._parent = Color.black.toValue();
    }

    fn colorOrBlack(self: ?*const Node) Color {
        // SAFETY: function is always safe
        @setRuntimeSafety(false);

        return (self orelse return .black).getColor();
    }

    comptime {
        // validate the assumptions we make in order to squeeze the color bit into `_parent`
        if (@alignOf(Node) != 8) @compileError("'Node' is not 8 byte aligned");
        if (Color.red.toValue() != 0) @compileError("Color `RED` is not 0");
    }
};

pub fn Tree(
    comptime compareFn: fn (node: *const Node, other_node: *const Node) core.OrderedComparison,
) type {
    return struct {
        root: ?*Node = null,

        const Self = @This();

        /// Insert a node into the tree.
        pub fn insert(self: *Self, node: *Node) error{AlreadyPresent}!void {
            node.* = .{}; // sets color to red

            if (self.root) |root| {
                var parent_node: *Node = undefined; // as we have a root, we know there is at least one node

                var direction: Direction = .left;

                var opt_current_node: ?*Node = root;

                while (opt_current_node) |current_node| {
                    direction = switch (compareFn(node, current_node)) {
                        .match => return error.AlreadyPresent,
                        .less => .left,
                        .greater => .right,
                    };
                    parent_node = current_node;
                    opt_current_node = current_node.children[direction.toValue()];
                }

                parent_node.children[direction.toValue()] = node;
                node.setParent(parent_node);

                self.fixInsertion(node);
            } else {
                node.setParentAndColorForRoot();
                self.root = node;
            }
        }

        /// Maintain red black tree invariants after insertion.
        fn fixInsertion(self: *Self, node: *Node) void {
            // Situation we are trying to fix: double red
            // According to red black tree invariants, only
            //
            //           G(X)       Cast
            //          /   \       C - current node   (R) - red
            //       P(R)   U(X)    P - parent         (B) - black
            //      /               G - grandparent    (X) - color unknown
            //   C(R)               U - uncle
            //

            var current: *Node = node;

            while (current.getParent()) |parent| {
                // if parent is black, there is no double red. See diagram above.
                if (parent.getColor() == .black) {
                    break;
                }

                const opt_uncle = parent.sibling();

                // root has to be black, and as parent is red, grandparent should exist
                const grandparent = parent.getParent().?;

                const direction = current.directionWithParent(parent);

                if (Node.colorOrBlack(opt_uncle) == .black) {
                    const parent_direction = parent.direction();

                    if (parent_direction == direction) {
                        //           G(B)                   P(B)
                        //          /   \                  /   \
                        //       P(R)   U(B)  ------>   C(R)   G(R)
                        //      /                                \
                        //   C(R)                                U(B)
                        //
                        // If uncle is black, grandparent has to be black, as parent is red.
                        // If grandparent was red, both of its children would have to be black,
                        // but parent is red.
                        // Grandparent color is updated later. Black height on path to B has not
                        // changed
                        // (before: grandparent black and uncle black, now P black and U black)

                        self.rotate(grandparent, direction.otherDirection());
                        parent.setColor(.black);
                    } else {
                        //          G(B)                  G(B)               C(B)
                        //        /     \                /   \              /   \
                        //      P(R)   U(B)   ---->    C(R)  U(B)   --->  P(R)  G(R)
                        //        \                   /                          \
                        //         C(R)             P(R)                         U(B)
                        //
                        // Black height on path to U has not changed
                        // (before: G and U black, after: C and U black)
                        // On the old track in P direction, nothing has changed as well

                        self.rotate(parent, direction.otherDirection());
                        self.rotate(grandparent, direction);
                        current.setColor(.black);
                    }

                    grandparent.setColor(.red);

                    break;
                } else {
                    //           G(B)                  G(R) <- potential double red fix needed
                    //         /     \               /     \
                    //       P(R)   U(R)   ---->   P(B)    U(B)
                    //      /                     /
                    //   C(R)                   C(R)
                    //
                    // The solution for the case in which uncle is red is to "push blackness down".
                    // We recolor parent and uncle to black and grandparent to red.
                    // It is easy to verify that black heights for all nodes have not changed.
                    // The only problem we have encountered is that grandparent's parent is red.
                    // If that is the case, we can have double red again. As such, we continue
                    // fixing by setting `current` to grandparent

                    parent.setColor(.black);
                    opt_uncle.?.setColor(.black); // if uncle is red, it is not null
                    grandparent.setColor(.red);
                    current = grandparent;
                }
            }

            self.root.?.setParentAndColorForRoot();
        }

        /// Rotate the subtree at `node` in `direction`.
        fn rotate(self: *Self, node: *Node, direction: Direction) void {
            const other_direction = direction.otherDirection();

            const new_top = node.children[other_direction.toValue()].?; // required to exist as we are rotating
            const opt_mid = new_top.children[direction.toValue()];
            const opt_parent = node.getParent();
            const new_direction = node.direction();

            node.children[other_direction.toValue()] = opt_mid;
            if (opt_mid) |mid| {
                mid.setParent(node);
            }

            new_top.children[direction.toValue()] = node;
            node.setParent(new_top);

            if (opt_parent) |parent| {
                parent.children[new_direction.toValue()] = new_top;
                new_top.setParent(parent);
            } else {
                new_top.setParentAndColorForRoot();
                self.root = new_top;
            }
        }

        /// Remove a node from the tree.
        ///
        /// NOTE: It is the caller's responsibility to ensure that the node is in the tree.
        pub fn remove(self: *Self, node: *Node) void {
            // we only handle deletion of a node with at most one child,
            // so we need to check if we have two and find a replacement
            self.replaceIfNeeded(node);

            const opt_node_parent = node.getParent();

            // get node's only child if any
            var opt_node_child: ?*Node =
                node.children[Direction.left.toValue()] orelse
                node.children[Direction.right.toValue()];

            if (opt_node_child) |child| {
                // if child exists and is the only child, it must be red

                if (opt_node_parent) |parent| {
                    parent.children[node.directionWithParent(parent).toValue()] = child;
                    child.setParent(parent);
                    child.setColor(.black);
                } else {
                    child.setParentAndColorForRoot();
                    self.root = child;
                }

                return;
            }

            if (node.getColor() == .red) {
                // if color is red, node is not root, and parent should exist
                const parent = opt_node_parent.?;

                parent.children[node.directionWithParent(parent).toValue()] = null;

                return;
            }

            if (opt_node_parent) |parent| {
                // hard case: double black
                self.fixDoubleBlack(node);
                parent.children[node.directionWithParent(parent).toValue()] = null;

                return;
            }

            // node is root with no children
            self.root = null;
        }

        /// Ensure that node to delete has at most one child
        fn replaceIfNeeded(self: *Self, node: *Node) void {
            if (node.children[Direction.left.toValue()] != null and node.children[Direction.right.toValue()] != null) {
                const replacement = blk: {
                    var current: *Node = node.children[Direction.left.toValue()].?; // checked above
                    while (current.children[Direction.right.toValue()]) |next| {
                        current = next;
                    }
                    break :blk current;
                };

                pointerSwap(self, node, replacement);
            }
        }

        /// Swap node with replacement found by `replaceIfNeeded`
        ///
        /// NOTE: `replacement` must have no right child.
        fn pointerSwap(self: *Self, node: *Node, replacement: *Node) void {
            core.debugAssert(node.children[Direction.left.toValue()] != null and
                node.children[Direction.right.toValue()] != null); // node should have two children

            // swap node colors
            const node_color = node.getColor();
            node.setColor(replacement.getColor());
            replacement.setColor(node_color);

            const original_node_parent = node.getParent();
            const original_replacement_parent = replacement.getParent();

            const original_node_direction = node.direction();

            core.debugAssert(replacement.children[Direction.right.toValue()] == null); // ensured by `replaceIfNeeded`

            if (node.children[Direction.left.toValue()] == replacement) {
                // case 1: replacement is left child of node

                const original_node_right_child = node.children[Direction.right.toValue()];

                // swap children
                node.children = replacement.children;

                // as right child is null (assert above), only check left children.
                if (node.children[Direction.left.toValue()]) |repl_child| {
                    repl_child.setParent(node);
                }

                // replacement's left child should be node now as roles have been exchanged
                replacement.children[Direction.left.toValue()] = node;

                // as node and replacement swapped roles node's parent is now replacement
                node.setParent(replacement);

                // right child of replacement remains unchanged from node
                replacement.children[Direction.right.toValue()] = original_node_right_child;

                if (replacement.children[Direction.right.toValue()]) |node_child| {
                    node_child.setParent(replacement);
                }
            } else {
                // case 2: replacement is not a child of node

                const original_replacement_direction = replacement.direction();

                // TODO: If this is `const original_replacement_child = replacement.children;` then there is a miscompilation :(
                // No upstream zig bug has been filed yet
                const original_replacement_child_left = replacement.children[Direction.left.toValue()];
                const original_replacement_child_right = replacement.children[Direction.right.toValue()];

                // swap children
                replacement.children = node.children;

                // they are both not null, as node has two children
                replacement.children[Direction.left.toValue()].?.setParent(replacement);
                replacement.children[Direction.right.toValue()].?.setParent(replacement);

                node.children = .{ original_replacement_child_left, original_replacement_child_right };

                // replacement can only have left child, update its parent if needed
                if (node.children[Direction.left.toValue()]) |repl_child| {
                    repl_child.setParent(node);
                }

                node.setParent(original_replacement_parent);

                // replacement parent should exist, as it is up the tree from node
                original_replacement_parent.?.children[original_replacement_direction.toValue()] = node;
            }

            // update parent link for replacement
            replacement.setParent(original_node_parent);

            if (original_node_parent) |parent| {
                // node wasn't root, change link from parent
                parent.children[original_node_direction.toValue()] = replacement;
            } else {
                // node was root, set tree root to replacement
                replacement.setParentAndColorForRoot();
                self.root = replacement;
            }
        }

        /// Maintain red black tree invariants after deletion.
        fn fixDoubleBlack(self: *Self, node: *Node) void {
            // situation: node is a black leaf
            // simply deleteing node will harm blackness height rule
            //
            //        P(X)  Cast:
            //       /      C - current node   P - parent   (R) - red   (X) - unknown
            //      C(B)    S - sibling        N - newphew  (B) - black
            //
            // the solution is to push double black up the tree until fixed
            // think of current_node as node we want to recolor as red
            // (removing node has the same effect on black height)

            var current_node = node;

            while (current_node.getParent()) |current_node_parent| {
                const current_node_direction = current_node.directionWithParent(current_node_parent);

                var current_node_sibling = current_node.sibling();

                // red sibling case. Make it black sibling case
                //
                //         P(X)                S(B)
                //       /     \    ----->    /   \
                //     C(B)    S(R)         P(R)   Z(B)
                //             / \          / \
                //           W(B) Z(B)  C(B)  W(B)
                //
                // W and Z should be black, as S is red (check rbtree invariants)
                // This transformation leaves us with black sibling
                if (current_node_sibling) |sibling| {
                    if (sibling.getColor() == .red) {
                        self.rotate(current_node_parent, current_node_direction);
                        sibling.setColor(.black);
                        current_node_parent.setColor(.red);
                        current_node_sibling = current_node.sibling();
                    }
                }

                // p subtree at this exact moment
                //
                //       P(X)
                //      /   \
                //    C(B)  S(B) (W is renamed to S)
                //

                // sibling must exist, otherwise there are two paths from parent with different black heights
                var sibling = current_node_sibling.?;

                // if both children of sibling are black, and parent is black too, there is easy fix
                const left_sibling_black = Node.colorOrBlack(sibling.children[Direction.left.toValue()]) == .black;
                const right_sibling_black = Node.colorOrBlack(sibling.children[Direction.right.toValue()]) == .black;

                if (left_sibling_black and right_sibling_black) {
                    if (current_node_parent.getColor() == .black) {
                        //       P(B)                            P(B)
                        //      /   \                           /    \
                        //    C(B)  S(B)       -------->      C(B)  S(R)
                        //
                        // if parent is already black, we can't compensate changing S color to red
                        // (which changes black height) locally. Instead we jump to a new iteration
                        // of the loop, requesting to recolor P to red

                        sibling.setColor(.red);
                        current_node = current_node_parent;

                        continue;
                    } else {
                        //       P(R)                            P(B)
                        //      /   \                           /    \
                        //    C(B)  S(B)       -------->      C(B)  S(R)
                        //
                        // in this case there is no need to fix anything else, as we compensated for
                        // changing S color to R with changing N's color to black. This means that
                        // black height on this path won't change at all.

                        current_node_parent.setColor(.black);
                        sibling.setColor(.red);

                        return;
                    }
                }

                const parent_color = current_node_parent.getColor();

                // check if red nephew has the same direction from parent
                if (Node.colorOrBlack(sibling.children[current_node_direction.toValue()]) == .red) {
                    //        P(X)                      P(X)
                    //       /   \                     /   \
                    //     C(B)  S(B)                C(B)  N(B)
                    //           /  \     ----->          /   \
                    //        N(R) Z(X)                X(B)   S(R)
                    //       /   \                           /   \
                    //     X(B)  Y(B)                      Y(B)  Z(X)
                    //
                    // exercise for the reader: check that black heights
                    // on paths from P to X, Y, and Z remain unchanged
                    // the purpose is to make this case right newphew case
                    // (in which direction of red nephew is opposite to direction of node)
                    self.rotate(sibling, current_node_direction.otherDirection());
                    sibling.setColor(.red);

                    // nephew exists and it will be a new subling
                    sibling = current_node.sibling().?;
                    sibling.setColor(.black);
                }

                //     P(X)                 S(P's old color)
                //    /   \                     /     \
                //  C(B)  S(B)    ----->      P(B)   N(B)
                //       /   \               /   \
                //     Y(X) N(R)           C(B)  Y(X)
                //
                // The black height on path from P to Y is the same as on path from S to Y in a new
                // tree. The black height on path from P to N is the same as on path from S to N in
                // a new tree. We only increased black height on path from P/S to C. But that is
                // fine, since recoloring C to red or deleting it is our final goal

                self.rotate(current_node_parent, current_node_direction);
                current_node_parent.setColor(.black);
                sibling.setColor(parent_color);

                if (sibling.children[current_node_direction.otherDirection().toValue()]) |nephew| {
                    nephew.setColor(.black);
                }

                return;
            }
        }

        /// Returns the first node encountered for which `whereFn` returns `OrderedComparison.match`.
        ///
        /// If no node is found, returns null.
        ///
        /// NOTE: In the case of no match the `whereFn` *must* return the same value as the `compareFn` would when
        /// comparing the `other_node` to the target node.
        pub fn findFirstMatch(
            self: *const Self,
            context: anytype,
            comptime whereFn: fn (context: @TypeOf(context), other_node: *const Node) core.OrderedComparison,
        ) ?*Node {
            const root = self.root orelse return null;

            var opt_current_node: ?*Node = root;

            while (opt_current_node) |current_node| {
                const direction: Direction = switch (whereFn(context, current_node)) {
                    .match => return current_node,
                    .less => .left,
                    .greater => .right,
                };
                opt_current_node = current_node.children[direction.toValue()];
            }

            return null;
        }

        /// Returns the last node encountered for which `whereFn` returns a `ComparisonAndMatch` where
        /// `counts_as_a_match` is true, if `comparison` is `.match` then that node is returned.
        ///
        /// If no node is found, returns null.
        ///
        /// NOTE:
        ///   - The `whereFn` *must* return the same `comparison` value as the `compareFn` would when comparing
        ///     the `other_node` to the target node.
        pub fn findLastMatch(
            self: *const Self,
            context: anytype,
            comptime whereFn: fn (context: @TypeOf(context), other_node: *const Node) ComparisonAndMatch,
        ) ?*Node {
            const root = self.root orelse return null;

            var opt_current_node: ?*Node = root;

            var last_matching_node: ?*Node = null;

            while (opt_current_node) |current_node| {
                const comparison = whereFn(context, current_node);

                const direction: Direction = switch (comparison.comparison) {
                    .match => return current_node,
                    .less => .left,
                    .greater => .right,
                };

                if (comparison.counts_as_a_match) last_matching_node = current_node;

                opt_current_node = current_node.children[direction.toValue()];
            }

            return last_matching_node;
        }

        pub fn iterator(self: *const Self) Iterator {
            return Iterator.init(self.root);
        }
    };
}

pub const ComparisonAndMatch = struct {
    comparison: core.OrderedComparison,
    counts_as_a_match: bool,
};

pub const Iterator = struct {
    next_node: ?*Node,

    fn init(root_node: ?*Node) Iterator {
        var node = root_node orelse return .{ .next_node = null };

        while (node.children[Direction.left.toValue()]) |left_child| {
            node = left_child;
        }

        return .{
            .next_node = node,
        };
    }

    pub fn next(self: *Iterator) ?*Node {
        const node = self.next_node orelse return null;

        if (node.children[Direction.right.toValue()]) |right_child| {
            // next is left most child

            var next_node = right_child;

            while (next_node.children[Direction.left.toValue()]) |left_child| {
                next_node = left_child;
            }

            self.next_node = next_node;

            return node;
        }

        var child_node = node;

        while (true) {
            const parent = child_node.getParent() orelse {
                self.next_node = null;
                return node;
            };

            const direction_from_parent = child_node.directionWithParent(parent);

            switch (direction_from_parent) {
                .left => {
                    self.next_node = parent;
                    return node;
                },
                .right => child_node = parent,
            }
        }
    }
};

test Tree {
    var tree: Tree(Item.compareNodes) = .{};

    var items = [_]Item{
        .{ .value = 34 },
        .{ .value = 12 },
        .{ .value = 1045 },
        .{ .value = 0 },
        .{ .value = 67 },
        .{ .value = 1939 },
        .{ .value = 49384983940824 },
        .{ .value = 17 },
        .{ .value = 2065 },
    };

    // insertion
    {
        try std.testing.expect(tree.root == null);
        try std.testing.expectEqual(@as(usize, 0), countNodes(tree));

        for (&items) |*item| {
            try tree.insert(&item.node);
        }

        try std.testing.expect(tree.root != null);
        try std.testing.expectEqual(@as(usize, items.len), countNodes(tree));
    }

    // order
    {
        var ordered_items = items;
        std.sort.heap(Item, &ordered_items, {}, Item.lessThan);

        var iterator = tree.iterator();
        var i: usize = 0;

        while (iterator.next()) |node| : (i += 1) {
            const item = @fieldParentPtr(Item, "node", node);
            try std.testing.expectEqual(ordered_items[i].value, item.value);
        }
    }

    // find - exact match
    {
        try std.testing.expect(tree.findFirstMatch(
            @as(usize, 42),
            Item.findEqlNode,
        ) == null);

        try std.testing.expect(tree.findFirstMatch(
            @as(usize, 12),
            Item.findEqlNode,
        ) != null);

        try std.testing.expect(tree.findFirstMatch(
            @as(usize, 34),
            Item.findEqlNode,
        ) != null);
    }

    // find - first less than
    {
        var less_than_node = tree.findFirstMatch(
            @as(usize, 15),
            Item.findFirstLessThanEqualNode,
        );
        try std.testing.expect(less_than_node != null);
        var less_than_item = @fieldParentPtr(Item, "node", less_than_node.?);
        try std.testing.expectEqual(@as(usize, 12), less_than_item.value);

        tree.remove(less_than_node.?);

        less_than_node = tree.findFirstMatch(
            @as(usize, 15),
            Item.findFirstLessThanEqualNode,
        );
        try std.testing.expect(less_than_node != null);
        less_than_item = @fieldParentPtr(Item, "node", less_than_node.?);
        try std.testing.expectEqual(@as(usize, 0), less_than_item.value);
    }

    // find - last less than
    {
        var less_than_node = tree.findLastMatch(
            @as(usize, 40),
            Item.findLastLessThanEqualNode,
        );
        try std.testing.expect(less_than_node != null);
        var less_than_item = @fieldParentPtr(Item, "node", less_than_node.?);
        try std.testing.expectEqual(@as(usize, 0), less_than_item.value);

        tree.remove(less_than_node.?);

        less_than_node = tree.findLastMatch(
            @as(usize, 40),
            Item.findLastLessThanEqualNode,
        );
        try std.testing.expect(less_than_node != null);
        less_than_item = @fieldParentPtr(Item, "node", less_than_node.?);
        try std.testing.expectEqual(@as(usize, 17), less_than_item.value);
    }
}

fn countNodes(tree: anytype) usize {
    var count: usize = 0;

    var iterator = tree.iterator();

    while (iterator.next()) |_| {
        count += 1;
    }

    return count;
}

const Item = struct {
    value: usize,
    node: Node = .{},

    fn findEqlNode(context: usize, other_node: *const Node) core.OrderedComparison {
        const other_item = @fieldParentPtr(Item, "node", other_node);

        return if (context < other_item.value)
            core.OrderedComparison.less
        else if (context > other_item.value)
            core.OrderedComparison.greater
        else
            core.OrderedComparison.match;
    }

    fn findFirstLessThanEqualNode(context: usize, other_node: *const Node) core.OrderedComparison {
        const other_item = @fieldParentPtr(Item, "node", other_node);

        if (other_item.value <= context) return .match;

        return .less;
    }

    fn findLastLessThanEqualNode(context: usize, other_node: *const Node) ComparisonAndMatch {
        const other_item = @fieldParentPtr(Item, "node", other_node);

        const less_than_or_equal = other_item.value <= context;

        return .{
            .comparison = if (less_than_or_equal) .less else .greater,
            .counts_as_a_match = less_than_or_equal,
        };
    }

    fn compareNodes(node: *const Node, other_node: *const Node) core.OrderedComparison {
        const item = @fieldParentPtr(Item, "node", node);
        const other = @fieldParentPtr(Item, "node", other_node);

        return if (item.value < other.value)
            .less
        else if (item.value > other.value)
            .greater
        else
            .match;
    }

    fn lessThan(_: void, lhs: Item, rhs: Item) bool {
        return lhs.value < rhs.value;
    }
};

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        return;
    }
}
