const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;

inline fn pCast(comptime T: type, p: anytype) T {
    return @intToPtr(T, @ptrToInt(p));
}

fn extract(comptime T: type, comptime name: []const u8) std.builtin.TypeInfo.StructField {
    inline for (@typeInfo(T).Struct.fields) |f| {
        if (std.mem.eql(u8, f.name, name))
            return f;
    }
    @compileError("{" ++ name ++ "} not found");
}

pub fn Generator(comptime sendT: type, comptime yieldT: type) type {
    return struct {
        sendFn: fn(*@This(), sendT) ?yieldT,
        finishedFn: fn(*@This()) bool,

        pub inline fn send(self: *@This(), message: sendT) ?yieldT {
            return self.sendFn(self, message);
        }

        pub inline fn next(self: *@This()) ?yieldT {
            if (sendT == void) {
                return self.send({});
            } else if (@typeInfo(sendT) == .Optional) {
                return self.send(null);
            } else {
                @compileError("No suitable default value for type");
            }
        }

        pub inline fn finished(self: *@This()) bool {
            return self.finishedFn(self);
        }
    };
}

pub fn Callback(comptime sendT: type, comptime yieldT: type) type {
    return struct {
        next_yield: yieldT = undefined,
        next_send: sendT = undefined,
        frame: anyframe = undefined,
        finished: bool = false,

        pub fn yield(self: *@This(), x: yieldT) sendT {
            self.next_yield = x;
            suspend { self.frame = @frame(); }
            return self.next_send;
        }

        pub fn close(self: *@This()) void {
            self.finished = true;
        }
    };
}

pub fn Coro(comptime f: anytype) type {
    // f(*Callback(sendT, yieldT)) void
    const C = @typeInfo(@typeInfo(@TypeOf(f)).Fn.args[0].arg_type.?).Pointer.child;
    const yieldT = extract(C, "next_yield").field_type;
    const sendT = extract(C, "next_send").field_type;

    return struct {
        callback: C = .{},
        frame: @Frame(f) = undefined,
        started: bool = false,
        generator: Generator(sendT, yieldT) = .{
            .sendFn = send,
            .finishedFn = finished,
        },

        pub fn init() @This() {
            return .{};
        }

        pub fn send(gen: *Generator(sendT, yieldT), message: sendT) ?yieldT {
            const self = @fieldParentPtr(@This(), "generator", gen);
            if (self.callback.finished)
                return null;
            self.callback.next_send = message;
            if (!self.started) {
                self.started = true;
                self.frame = async f(&self.callback);
                if (self.callback.finished)
                    return null;
            }
            defer resume self.callback.frame;
            return self.callback.next_yield;
        }

        pub fn finished(gen: *Generator(sendT, yieldT)) bool {
            const self = @fieldParentPtr(@This(), "generator", gen);
            return self.callback.finished;
        }
    };
}

pub fn RecursiveCoro(comptime f: anytype) type {
    // f(*Callback(sendT, yieldT)) void
    const C = @typeInfo(@typeInfo(@TypeOf(f)).Fn.args[0].arg_type.?).Pointer.child;
    const yieldT = extract(C, "next_yield").field_type;
    const sendT = extract(C, "next_send").field_type;

    return struct {
        callback: C = .{},
        frame: anyframe = undefined,
        started: bool = false,
        allocator: Allocator,
        generator: Generator(sendT, yieldT) = .{
            .sendFn = send,
            .finishedFn = finished,
        },

        pub fn init(allocator: Allocator) !@This() {
            return @This() {
                .allocator = allocator,
                .frame = try allocator.create(@Frame(f)),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.destroy(pCast(*@Frame(f), self.frame));
        }

        pub fn send(gen: *Generator(sendT, yieldT), message: sendT) ?yieldT {
            const self = @fieldParentPtr(@This(), "generator", gen);
            if (self.callback.finished)
                return null;
            self.callback.next_send = message;
            if (!self.started) {
                self.started = true;
                var framePtr = pCast(*@Frame(f), self.frame);
                framePtr.* = async f(&self.callback);
                if (self.callback.finished)
                    return null;
            }
            defer resume self.callback.frame;
            return self.callback.next_yield;
        }

        pub fn finished(gen: *Generator(sendT, yieldT)) bool {
            const self = @fieldParentPtr(@This(), "generator", gen);
            return self.callback.finished;
        }
    };
}

fn ten(c: *Callback(void, u8)) void {
    defer c.close();
    var i: u8 = 0;
    while (i < 10) : (i += 1)
        c.yield(i);
}

test "ten coro" {
    var iter = Coro(ten).init();
    var i: u8 = 0;
    while (iter.generator.send({})) |x| : (i += 1) {
        try expectEqual(i, x);
    }
    try expectEqual(i, 10);
}

test "ten recursive coro" {
    var iter = try RecursiveCoro(ten).init(std.testing.allocator);
    defer iter.deinit();
    var i: u8 = 0;
    while (iter.generator.next()) |x| : (i += 1) {
        try expectEqual(i, x);
    }
    try expectEqual(i, 10);
}

const Data = union(enum) {
    alloc: Allocator,
    data: u32,
    none: void,
};

fn triangular(c: *Callback(Data, ?u32)) void {
    defer c.close();
    var alloc = c.yield(null).alloc;
    var i: u32 = c.yield(null).data;
    if (i == 0) {
        return;
    } else {
        _ = c.yield(i);
    }
    var child = RecursiveCoro(triangular).init(alloc) catch {
        _ = c.yield(null);
        return;
    };
    defer child.deinit();
    _ = child.generator.send(.{.alloc=alloc});
    _ = child.generator.send(.{.data=i-1});
    while (child.generator.send(.none)) |x| {
        _ = c.yield(i + x.?);
    }
}

test "triangular recursive coro" {
    var iter = try RecursiveCoro(triangular).init(std.testing.allocator);
    defer iter.deinit();
    _ = iter.generator.send(.{.alloc = std.testing.allocator});
    _ = iter.generator.send(.{.data = 50});
    var i: u32 = 50;
    var total: u32 = 50;
    while (iter.generator.send(.none)) |x| : ({total += (i-1); i -= 1;}) {
        try expectEqual(total, x.?);
    }
    try expectEqual(total, 1275); // 1+2+..+49+50
}

fn simple_recurse(c: *Callback(void, void)) void {
    defer c.close();
    var child = RecursiveCoro(simple_recurse).init(std.testing.allocator) catch unreachable;
    defer child.deinit();
}

test "simple_recurse" {
    // Exercises the "no-yield" code path for RecursiveCoro
    var iter = try RecursiveCoro(simple_recurse).init(std.testing.allocator);
    defer iter.deinit();
    while (iter.generator.next()) |_| { unreachable; }
}

fn noop_generator(c: *Callback(void, void)) void {
    defer c.close();
}

test "noop_generator" {
    // Exercises the "no-yield" code path for Coro
    var iter = Coro(noop_generator).init();
    while (iter.generator.next()) |_| { unreachable; }
}

fn Node(comptime T: type) type {
    return struct {
        value: T,
        left: ?*Node(T) = null,
        right: ?*Node(T) = null,
    };
}

const InorderData = union(enum) {
    node: ?*Node(u32),
    alloc: Allocator,
};

fn recursive_inorder(c: *Callback(InorderData, ?u32)) void {
    defer c.close();
    const allocator = c.yield(null).alloc;
    var node = c.yield(null).node;
    if (node) |n| {
        {
            var child = RecursiveCoro(recursive_inorder).init(allocator) catch return;
            defer child.deinit();
            _ = child.generator.send(.{.alloc = allocator});
            _ = child.generator.send(.{.node = n.left});
            while (child.generator.send(.{.node = null})) |x|
                _ = c.yield(x);
        }
        _ = c.yield(n.value);
        {
            var child = RecursiveCoro(recursive_inorder).init(allocator) catch return;
            defer child.deinit();
            _ = child.generator.send(.{.alloc = allocator});
            _ = child.generator.send(.{.node = n.right});
            while (child.generator.send(.{.node = null})) |x|
                _ = c.yield(x);
        }
    }
}

test "recursive inorder traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var iter = try RecursiveCoro(recursive_inorder).init(allocator);
    defer iter.deinit();

    var one = Node(u32){.value = 1};
    var two = Node(u32){.value = 2};
    var three = Node(u32){.value = 3};
    var four = Node(u32){.value = 4};
    two.left = &one;
    two.right = &four;
    four.left = &three;

    var g = &iter.generator;
    _ = g.send(.{.alloc = allocator});
    _ = g.send(.{.node = &two});
    var i: u32 = 1;
    while (g.send(.{.node = null})) |x| : (i += 1)
        try expectEqual(x, i);
    try expectEqual(i, 5);
}
