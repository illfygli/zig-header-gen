const std = @import("std");
const builtin = std.builtin;
const TypeInfo = builtin.Type;
const Declaration = TypeInfo.Declaration;
const warn = std.debug.print;

// Provided generators
pub const C_Generator = @import("generators/c.zig").C_Generator;
pub const Python_Generator = @import("generators/python.zig").Python_Generator;
pub const Ordered_Generator = @import("generators/ordered.zig").OrderedGenerator;

const GeneratorInterface = struct {
    fn init() void {}
    fn deinit() void {}
    fn gen_func() void {}
    fn gen_struct() void {}
    fn gen_enum() void {}
    fn gen_union() void {}
};

fn includeSymbol(comptime decl: Declaration) bool {
    if (decl.data == .Type) {
        const T = decl.data.Type;
        const info = @typeInfo(T);

        return switch (info) {
            .Struct => |s| s.layout == .Extern or s.layout == .Packed,
            .Union => |u| u.layout == .Extern,
            .Enum => |e| e.layout == .Extern,
            else => false,
        };
    }

    return false;
}

fn validateGenerator(comptime Generator: type) void {
    comptime {
        const interface = @typeInfo(GeneratorInterface).Struct.decls;

        for (interface) |decl| {
            if (@hasDecl(Generator, decl.name) == false) {
                @compileError("Generator: '" ++
                    @typeName(Generator) ++
                    "' is missing function: " ++
                    decl.name);
            }
        }
    }
}

pub fn HeaderGen(comptime S: type, comptime libname: []const u8) type {
    const all_decls: []const Declaration = @typeInfo(S).Struct.decls;

    return struct {
        decls: @TypeOf(all_decls) = all_decls,
        source_file: []const u8 = libname ++ ".zig",

        const Self = @This();

        pub fn init() Self {
            return Self{};
        }

        pub fn exec(comptime self: Self, comptime Generator: type) void {
            validateGenerator(Generator);

            var cwd = std.fs.cwd();
            cwd.makeDir("headers") catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => @panic("Failed to init header folder"),
            };

            var hdr_dir = cwd.openDir("headers", .{}) catch @panic("Failed to open header dir");
            defer hdr_dir.close();

            var gen = Generator.init(self.source_file, &hdr_dir);
            defer gen.deinit();

            // iterate exported enums
            // do this first in case target lang needs enums defined before use
            inline for (self.decls) |decl| {
                if (@typeInfo(S) == .Type) {
                    const T = S;
                    const info = @typeInfo(T);
                    if (info == .Enum) {
                        const layout = info.Enum.layout;
                        if (layout == .Extern) {
                            gen.gen_enum(decl.name, info.Enum);
                        }
                    }
                }
            }

            // iterate exported structs
            inline for (self.decls) |decl| {
                if (@typeInfo(S) == .Type) {
                    const T = S;
                    const info = @typeInfo(T);
                    if (info == .Struct) {
                        const layout = info.Struct.layout;
                        if (layout == .Extern or layout == .Packed) {
                            gen.gen_struct(decl.name, info.Struct);
                        }
                    }
                }
            }

            inline for (self.decls) |decl| {
                if (@typeInfo(S) == .Type) {
                    const T = decl.data.Type;
                    const info = @typeInfo(T);
                    if (info == .Union) {
                        const layout = info.Union.layout;
                        if (layout == .Extern) {
                            gen.gen_union(decl.name, info.Union);
                        }
                    }
                }
            }

            // iterate exported fns
            inline for (self.decls) |decl| {
                if (@typeInfo(S) == .Fn) {
                    const func = decl.data.Fn;
                    if (func.is_export) {
                        //TODO: Look into parsing file for argument names
                        const fn_meta = @typeInfo(func.fn_type).Fn;
                        gen.gen_func(decl.name, fn_meta);
                    }
                } else if (@typeInfo(S) == .Type) {
                    const fn_meta = @typeInfo(decl.data.Type);

                    if (fn_meta == .Fn) {
                        gen.gen_func(decl.name, fn_meta.Fn);
                    }
                }
            }
        }
    };
}
