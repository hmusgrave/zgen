# zgen

A simple generator library for zig

## Purpose

Suspending execution of a function to yield intermediate results makes some
algorithms drastically easier to write. This library automates most of the
boilerplate for writing functions in that style.

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
