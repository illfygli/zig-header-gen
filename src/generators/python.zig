const std = @import("std");
const Dir = std.fs.Dir;
const warn = std.debug.print;
const rt = @import("../runtime.zig");
const FnDecl = rt.TypeInfo.Declaration.Data.FnDecl;
const FnMeta = rt.TypeInfo.Fn;
const StructMeta = rt.TypeInfo.Struct;
const EnumMeta = rt.TypeInfo.Enum;
const UnionMeta = rt.TypeInfo.Union;
const SymbolPhase = @import("ordered.zig").SymbolPhase;

pub const Python_Generator = struct {
    pub const symbols_order: bool = false;

    file: std.fs.File,

    const Self = @This();

    pub fn init(comptime src_file: []const u8, dst_dir: *Dir) Self {
        const file = dst_dir.createFile(comptime filebase(src_file) ++ ".py", .{}) catch
            @panic("Failed to create header file for source: " ++ src_file);

        var res = Self{ .file = file };

        res.write(
            \\import ctypes            
            \\import enum
            \\
        );

        res.write("lib = ctypes.cdll.LoadLibrary(\"" ++ comptime filebase(src_file) ++ ".dll\")\n\n");

        return res;
    }

    fn filebase(src_file: []const u8) []const u8 {
        const filebaseext = std.fs.path.basename(src_file);
        return filebaseext[0 .. filebaseext.len - 4];
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    pub fn gen_func(self: *Self, name: []const u8, meta: FnMeta) void {
        self.print("lib.{s}.argtypes = [", .{name});

        for (meta.params, 0..) |arg, i| {
            if (arg.type) |t| {
                self.writeType(t.*);
            } else {
                self.write("None");
            }

            if (i != meta.params.len - 1) {
                self.write(", ");
            }
        }

        self.write("]\n");

        self.print("lib.{s}.restype = ", .{name});
        if (meta.return_type) |return_type| {
            self.writeType(return_type.*);
        } else {
            self.write("None");
        }
        self.write("\n\n");
    }

    pub fn _gen_fields(self: *Self, name: []const u8, fields: anytype, phase: SymbolPhase) void {
        const prefix = "\t            ";

        if (phase == .Body) {
            self.print("{s}._fields_ = [", .{name});
        } else {
            self.write("\t_fields_ = [");
        }

        for (fields, 0..) |field, i| {
            if (i > 0) {
                self.write(prefix);
            }

            self.print("(\"{s}\", ", .{field.name});

            self.writeType(field.field_type.*);

            self.write(")");

            if (i != fields.len - 1) {
                self.write(",\n");
            }
        }

        self.write("]\n");
    }

    pub fn gen_struct(self: *Self, name: []const u8, meta: StructMeta, phase: SymbolPhase) void {
        if (phase != .Body) {
            self.print("class {s}(ctypes.Structure):\n", .{name});

            if (meta.layout == .Packed) {
                self.write("\t_pack_ = 1\n");
            }
        }

        if (phase != .Signature) {
            self._gen_fields(name, meta.fields, phase);
        } else if (meta.layout != .Packed) {
            self.write("\tpass\n");
        }

        self.write("\n");
    }

    pub fn gen_enum(self: *Self, name: []const u8, meta: EnumMeta, phase: SymbolPhase) void {
        _ = phase;
        self.print("class {s}(enum.IntEnum):\n", .{name});

        for (meta.fields) |field| {
            self.write("\t");
            self.writeScreamingSnakeCase(field.name);
            self.print(" = {}\n", .{field.value});
        }

        if (meta.fields.len == 0) {
            self.write("\tpass");
        }

        self.write("\n");
    }

    pub fn gen_union(self: *Self, name: []const u8, meta: UnionMeta, phase: SymbolPhase) void {
        if (phase != .Body) {
            self.print("class {s}(ctypes.Union):\n", .{name});
        }

        if (phase != .Signature) {
            self._gen_fields(name, meta.fields, phase);
        } else {
            self.write("\tpass\n");
        }

        self.write("\n");
    }

    fn writeType(self: *Self, meta: rt.TypeInfo) void {
        switch (meta) {
            .Void => self.write("None"),
            .Bool => self.write("ctypes.c_bool"),
            // .usize => self.writeCtype("c_usize"), // TODO
            // .isize => self.writeCtype("c_isize"), // TODO
            .Int => |i| {
                switch (i.signedness == .signed) {
                    true => self.print("ctypes.c_int{}", .{i.bits}),
                    false => self.print("ctypes.c_uint{}", .{i.bits}),
                }
            },
            .Float => |f| {
                switch (f.bits) {
                    32 => self.write("c_float"),
                    64 => self.write("c_double"),
                    128 => self.write("c_longdouble"),
                    else => self.print("ctypes.c_f{}", .{f.bits}),
                }
            },
            .Struct => |s| self.write(s.name orelse "__unknown__"),
            .Union => |s| self.write(s.name orelse "__unknown__"),
            .Enum => |s| self.write(s.name orelse "__unknown__"),
            .Pointer => |p| {
                const childmeta = p.child.*;
                self.writeCtype("POINTER(");
                if (childmeta == .Struct and childmeta.Struct.layout != .Extern) {
                    self.writeCtype("c_size_t");
                } else {
                    self.writeType(childmeta);
                }
                self.write(")");
            },
            .Optional => self.writeType(meta.Optional.child.*),
            .Array => |a| {
                self.writeType(a.child.*);
                self.print(" * {}", .{a.len});
            },
            else => self.write(@tagName(meta)), // TODO!!!!!
        }
    }

    fn writeScreamingSnakeCase(self: *Self, str: []const u8) void {
        var new_word: bool = false;
        var was_lower: bool = false;
        var is_upper: bool = undefined;

        for (str, 0..) |char, i| {
            is_upper = std.ascii.isUpper(char);

            if (char == '_' and i > 0) {
                new_word = true;
                continue;
            }

            if (new_word == true or (is_upper and was_lower)) {
                new_word = false;
                was_lower = false;

                self.writeChar('_');
            } else {
                was_lower = !is_upper;
            }

            self.writeChar(std.ascii.toUpper(char));
        }
    }

    fn writeCtype(self: *Self, comptime str: []const u8) void {
        self.write("ctypes." ++ str);
    }

    fn writeChar(self: *Self, char: u8) void {
        self.write(&[1]u8{char});
    }

    fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.file.writer().print(fmt, args) catch unreachable;
    }

    fn write(self: *Self, str: []const u8) void {
        _ = self.file.writeAll(str) catch unreachable;
    }
};
