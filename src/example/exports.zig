const header_gen = @import("header_gen");

export fn thing(one: usize, two: *LameType, three: [*]u16) bool {
    _ = three;
    _ = two;
    return one == 1;
}

export fn break_point(v: [*]u8) callconv(.Naked) void {
    _ = v;
    @breakpoint();
}

const WackType = packed struct {
    mr_field: *LameType,
};

const LameType = extern struct {
    blah: WackType,
    bleh: *WhatsAUnion,
};
const WhatsAUnion = extern union {
    a: *LameType,
    b: u64,
};

const ThisWillBeVoid = struct {
    a: u64,
};

const LookMaAnEnum = enum(c_int) {
    one = 1,
    three = 3,
    four,
    five = 5,
};

pub fn main() void {
    comptime var gen = header_gen.HeaderGen(@This(), "lib").init();

    gen.exec(header_gen.C_Generator);
    gen.exec(header_gen.Ordered_Generator(header_gen.Python_Generator));
}
