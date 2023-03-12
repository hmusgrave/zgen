# zgen (broken till Zig 0.11 is released and we update our async stuff)

A simple generator library for zig

## Purpose

Suspending execution of a function to yield intermediate results makes some
algorithms drastically easier to write. This library automates most of the
boilerplate for writing functions in that style. It supports self-referencing
generators, making it suitable for tree and graph algorithms.

## Installation

Choose your favorite method for vendoring this code into your repository. I
think [git-subrepo](https://github.com/ingydotnet/git-subrepo) strikes a nicer
balance than git-submodules or most other alternatives.

When Zig gets is own builtin package manager we'll be available there as well.

```bash
git subrepo clone git+https://github.com/hmusgrave/zgen.git [optional-subdir]
```

## Examples
```zig
const std = @import("std");
const gen = @import("zgen.zig");

const RangeOptions = struct {
    start: ?u32,
    end: ?u32,
    step: ?u32,
};

// Like Python3's range(), assuming u32 inputs
fn range(c: *gen.Callback(?RangeOptions, u32)) void {
    // This is how we keep track of whether the function has
    // fully executed
    defer c.close();

    // Heterogenous inputs are fine. In this function we initially set up the
    // "range()" execution and then ignore other inputs
    var params = c.yield(0).?;

    // Sensible defaults.
    var i = params.start orelse 0;
    const end = params.end orelse std.math.maxInt(u32);
    const step = params.step orelse 1;

    // Actually do the iteration and yield results
    if (end == 0)
        return;
    while (i < end and std.math.maxInt(u32)-step >= i) : (i += step)
        _ = c.yield(i);
    if (i < end)
        _ = c.yield(i);
}

test "range" {
    std.debug.print("\n", .{});
    var iter = gen.Coro(range){};
    _ = iter.generator.send(RangeOptions{.end = 5});
    while (iter.generator.next()) |x| {
        // prints 0, 1, 2, 3, 4
        std.debug.print("{}\n", .{x});
    }
}
```

To support recursion (for-example, to build a tree-walking iterator), you need
to break the dependency loop in your generator @Frame types referring to
themselves. We do that by storing a pointer to the child frames and requiring
an allocator to place that frame somewhere. Managing allocations is slightly
more painful than not, so if you don't need recursive generators the simpler
`Coro` interface is provided, but `RecursiveCoro` is strictly more powerful.

```zig
const std = @import("std");
const gen = @import("zgen.zig");

fn Node(comptime T: type) type {
    return struct {
        value: T,
        left: ?*Node(T) = null,
        right: ?*Node(T) = null,
    };
}

const InorderData = struct {
    node: ?*Node(u32),
    alloc: Allocator,
};

fn recursive_inorder(c: *gen.Callback(?InorderData, ?u32)) void {
    // Inorder tree traversal
    defer c.close();
    var data = c.yield(null) orelse return;
    const allocator = data.alloc;
    if (data.node) |n| {
        {
            var child = (gen.RecursiveCoro(recursive_inorder).init(allocator) catch return)
                .setup(.{.alloc = allocator, .node = n.left});
            c.yield_from(&child.generator);
        }
        _ = c.yield(n.value);
        {
            var child = (gen.RecursiveCoro(recursive_inorder).init(allocator) catch return)
                .setup(.{.alloc = allocator, .node = n.right});
            c.yield_from(&child.generator);
        }
    }
}

test "recursive inorder traversal" {
    // The easiest way to support partial iteration without memory
    // leaks is to wrap your favorite allocator with an arena.
    // 
    // Depending on the nature of your recursion it might be desirable
    // to further wrap that with something like a dynamic circular buffer
    // allocator or a stack-on-heap allocator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var one = Node(u32){.value = 1};
    var two = Node(u32){.value = 2};
    var three = Node(u32){.value = 3};
    var four = Node(u32){.value = 4};
    two.left = &one;
    two.right = &four;
    four.left = &three;

    var iter = (try RecursiveCoro(recursive_inorder).init(allocator)).setup(.{
        .alloc = allocator,
        .node = &two
    });
    defer iter.deinit();

    // We built a small tree whose in-order traversal
    // should be 1, 2, 3, 4. Verify that it is in fact
    // 1, 2, 3, ..., N and that we stopped at N=4.
    var g = &iter.generator;
    var i: u32 = 1;
    while (g.next()) |x| : (i += 1)
        try expectEqual(x, i);
    try expectEqual(i, 5);
}
```

## Status
Contributions welcome. I'll check back on this repo at least once per month.
Currently targets Zig 0.10.*-dev

Test suite catches:
- [x] Most obvious implementation bugs

Overhead suitable for:
- [x] Typical http requests
- [x] Some graph algorithms
- [ ] High-performance _anything_ (1+ function calls for every data point is
  expensive -- this will likely never be supported)
