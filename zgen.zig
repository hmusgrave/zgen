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
        sendFn: fn(*@This(), sendT) error{StopIteration}!yieldT,

        pub inline fn send(self: *@This(), message: sendT) !yieldT {
            return self.sendFn(self, message);
        }

        pub inline fn next(self: *@This()) !yieldT {
            if (sendT == void) {
                return self.send({});
            } else if (@typeInfo(sendT) == .Optional) {
                return self.send(null);
            } else {
                @compileError("No suitable default value for type");
            }
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
        generator: Generator(sendT, yieldT) = .{.sendFn = send},

        pub fn init() @This() {
            return .{};
        }

        pub fn send(gen: *Generator(sendT, yieldT), message: sendT) !yieldT {
            const self = @fieldParentPtr(@This(), "generator", gen);
            if (self.callback.finished)
                return error.StopIteration;
            self.callback.next_send = message;
            if (!self.started) {
                self.started = true;
                self.frame = async f(&self.callback);
            }
            defer resume self.callback.frame;
            return self.callback.next_yield;
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
        generator: Generator(sendT, yieldT) = .{.sendFn = send},

        pub fn init(allocator: Allocator) !@This() {
            return @This() {
                .allocator = allocator,
                .frame = try allocator.create(@Frame(f)),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.destroy(pCast(*@Frame(f), self.frame));
        }

        pub fn send(gen: *Generator(sendT, yieldT), message: sendT) !yieldT {
            const self = @fieldParentPtr(@This(), "generator", gen);
            if (self.callback.finished)
                return error.StopIteration;
            self.callback.next_send = message;
            if (!self.started) {
                self.started = true;
                var framePtr = pCast(*@Frame(f), self.frame);
                framePtr.* = async f(&self.callback);
            }
            defer resume self.callback.frame;
            return self.callback.next_yield;
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
    } else |err| {switch(err) {error.StopIteration => {}}}
    try expectEqual(i, 10);
}

test "ten recursive coro" {
    var iter = try RecursiveCoro(ten).init(std.testing.allocator);
    defer iter.deinit();
    var i: u8 = 0;
    while (iter.generator.next()) |x| : (i += 1) {
        try expectEqual(i, x);
    } else |err| {switch(err) {error.StopIteration => {}}}
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
    _ = child.generator.send(.{.alloc=alloc}) catch unreachable;
    _ = child.generator.send(.{.data=i-1}) catch unreachable;
    while (child.generator.send(.none)) |x| {
        _ = c.yield(i + x.?);
    } else |err| {switch(err) {error.StopIteration => {}}}
}

test "triangular recursive coro" {
    std.debug.print("\n", .{});
    var iter = try RecursiveCoro(triangular).init(std.testing.allocator);
    defer iter.deinit();
    _ = try iter.generator.send(.{.alloc = std.testing.allocator});
    _ = try iter.generator.send(.{.data = 50});
    var i: u32 = 50;
    var total: u32 = 50;
    while (iter.generator.send(.none)) |x| : ({total += (i-1); i -= 1;}) {
        try expectEqual(total, x.?);
    } else |err| {switch(err) {error.StopIteration => {}}}
    try expectEqual(total, 1275); // 1+2+..+49+50
}
