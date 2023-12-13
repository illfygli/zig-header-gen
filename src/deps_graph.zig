const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;

pub fn DepsGraph(comptime T: type) type {
    return struct {
        allocator: Allocator,
        // All the pointers to symbols inside this struct are owned by this struct
        // More specifically, they sould be freed when removed from the symbols
        // hash map. And they should only be removed from there when there are
        // no references to them in the dependants_of hash map
        symbols: StringHashMap(*Symbol),
        // *Symbol owned by self.symbols
        dependants_of: StringHashMap(ArrayList(*Symbol)),
        // ?*Symbol owned by self.symbols
        current_symbol: ?*Symbol,
        // Queue containing symbols ready to be emitted
        // Can be updated each time after calling endSymbol()
        emitted: TailQueue(EmittedSymbol),

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .symbols = StringHashMap(*Symbol).init(allocator),
                .dependants_of = StringHashMap(ArrayList(*Symbol)).init(allocator),
                .current_symbol = null,
                .emitted = TailQueue(EmittedSymbol){},
            };
        }

        pub fn deinit(self: *Self) void {
            var s_iter = self.symbols.iterator();
            while (s_iter.next()) |entry| {
                // Here entry.value is a *Symbol, so we deinit the symbol
                entry.value_ptr.*.deinit(self.allocator);

                // And free the pointer
                self.allocator.destroy(entry.value_ptr.*);
            }

            self.symbols.deinit();

            var d_iter = self.dependants_of.iterator();
            while (d_iter.next()) |entry| {
                // Here entry.value is an ArrayList(*Symbol), so we simply
                // deinit the array list (since the pointers were freed already)
                entry.value_ptr.*.deinit();
            }

            self.dependants_of.deinit();

            while (self.emitted.popFirst()) |node| {
                self.allocator.destroy(node);
            }

            self.current_symbol = null;
        }

        pub fn isBlocking(self: *Self, symbol_name: []const u8) bool {
            // A symbol_name can be blocking if either:
            //  1. There is no symbol declared with that name yet
            //  2. There is a symbol, but it is blocked by some dependencies too
            const symbol = self.symbols.get(symbol_name) orelse return true;

            // TODO Should a symbol be able to depend on itself?
            // If so, what to do in that case? For now, it blocks itself
            // if (symbol == self.current_symbol) return false;

            return symbol.hasDependenciesOfType(.Linear);
        }

        pub const BeginSymbolError = error{ DuplicateSymbol, OutOfMemory };

        pub fn beginSymbol(self: *Self, name: []const u8, payload: T) BeginSymbolError!void {
            const result = try self.symbols.getOrPut(name);

            if (result.found_existing) {
                return error.DuplicateSymbol;
            }

            // Since the allocation can fail, we do not want to leave the state
            // inconsistent (with a KV whose value is empty)
            errdefer std.debug.assert(self.symbols.remove(name));

            result.value_ptr.* = try self.allocator.create(Symbol);

            result.value_ptr.*.* = Symbol.init(self.allocator, name, payload);

            self.current_symbol = result.value_ptr.*;
        }

        pub const AddDependencyError = error{ NoSymbol, OutOfMemory };

        pub fn addDependency(self: *Self, dependency_name: []const u8) AddDependencyError!void {
            // If the dependency is not blocking, then there's no need to add it
            if (!self.isBlocking(dependency_name)) return;

            var current_symbol = self.current_symbol orelse return error.NoSymbol;

            // If a symbol depends on itself, whatever, not our business
            if (std.mem.eql(u8, dependency_name, current_symbol.name)) return;

            var already_added: bool = false;
            var is_circular: bool = false;

            // Checks if there are other symbols that depend on dependency_name
            var result = try self.dependants_of.getOrPut(dependency_name);

            // Creates or retrieves the array list that contains what symbols
            // depend on dependency_name. Also checks if this symbol is already there
            if (result.found_existing) {
                for (result.value_ptr.items) |symbol| {
                    if (symbol == current_symbol) {
                        already_added = true;
                    }
                }
            } else {
                result.value_ptr.* = ArrayList(*Symbol).init(self.allocator);
            }

            if (!already_added) {
                try result.value_ptr.append(current_symbol);

                if (self.dependants_of.getEntry(current_symbol.name)) |dependants| {
                    for (dependants.value_ptr.items) |dep| {
                        if (std.mem.eql(u8, dep.name, dependency_name)) {
                            try dep.addDependency(.{ .Circular = current_symbol.name });

                            is_circular = true;

                            break;
                        }
                    }
                }

                if (is_circular) {
                    try current_symbol.addDependency(.{ .Circular = dependency_name });
                } else {
                    try current_symbol.addDependency(.{ .Linear = dependency_name });
                }
            }
        }

        pub const EndSymbolError = error{OutOfMemory};

        pub fn createNode(comptime V: type, data: V, allocator: Allocator) !*TailQueue(V).Node {
            const node = try allocator.create(TailQueue(V).Node);
            node.* = .{ .data = data };
            return node;
        }

        pub fn endSymbol(self: *Self) EndSymbolError!void {
            var current_symbol = self.current_symbol orelse return;

            var unblock_queue = std.TailQueue(EmittedSymbol){};

            if (!self.isBlocking(current_symbol.name)) {
                const node = try createNode(EmittedSymbol, .{
                    .symbol = current_symbol,
                    .partial = current_symbol.hasDependencies(),
                }, self.allocator);

                unblock_queue.append(node);
            }

            // All items in unblock_queue have already been unblocked, and so
            // should be emitted. Also, any dependants of them should be checked
            // if they themselves can be unblocked as well
            while (unblock_queue.popFirst()) |symbol_node| {
                self.emitted.append(symbol_node);

                const symbol = symbol_node.data.symbol;

                if (self.dependants_of.getEntry(symbol.name)) |kv| {
                    for (kv.value_ptr.items) |dependant| {
                        if (dependant.removeDependency(symbol.name)) |_| {
                            const unblock_dep = (!dependant.emitted and !dependant.hasDependenciesOfType(.Linear)) or !dependant.hasDependencies();

                            if (!unblock_dep) continue;

                            dependant.emitted = true;

                            const node = try createNode(EmittedSymbol, .{
                                .symbol = dependant,
                                .partial = dependant.hasDependencies(),
                            }, self.allocator);

                            unblock_queue.append(node);
                        }
                    }
                }
            }

            self.current_symbol = null;
        }

        pub fn readEmitted(self: *Self) ?EmittedSymbol {
            const symbol_node = self.emitted.popFirst() orelse return null;

            const symbol = symbol_node.data;

            self.allocator.destroy(symbol_node);

            return symbol;
        }

        pub fn blockedIterator(self: *Self) BlockedSymbolsIterator {
            return BlockedSymbolsIterator.init(self);
        }

        const Dependency = union(enum) {
            Linear: []const u8,
            Circular: []const u8,

            pub fn getName(self: Dependency) []const u8 {
                return switch (self) {
                    .Linear => |n| n,
                    .Circular => |n| n,
                };
            }

            pub fn eql(self: Dependency, other: Dependency) bool {
                switch (self) {
                    .Linear => |n| return other == .Linear and std.mem.eql(u8, other.Linear, n),
                    .Circular => |n| return other == .Circular and std.mem.eql(u8, other.Circular, n),
                }
            }

            pub fn eqlName(self: Dependency, other: Dependency) bool {
                return std.mem.eql(u8, self.getName(), other.getName());
            }
        };

        const EmittedSymbol = struct {
            symbol: *Symbol,
            partial: bool,
        };

        const Symbol = struct {
            // Not owned
            name: []const u8,
            // Slices not owned
            dependencies: ArrayList(Dependency),
            emitted: bool = false,
            payload: T,

            pub fn init(allocator: Allocator, name: []const u8, payload: T) Symbol {
                return .{
                    .name = name,
                    .dependencies = ArrayList(Dependency).init(allocator),
                    .payload = payload,
                };
            }

            pub fn deinit(self: *Symbol, allocator: Allocator) void {
                _ = allocator;
                self.dependencies.deinit();
            }

            pub fn addDependency(self: *Symbol, dependency: Dependency) !void {
                for (self.dependencies.items) |*existing| {
                    if (dependency.eqlName(existing.*)) {
                        existing.* = dependency;

                        return;
                    }
                }

                try self.dependencies.append(dependency);
            }

            pub fn removeDependency(self: *Symbol, dependency_name: []const u8) ?Dependency {
                _ = dependency_name;
                var maybe_dep_index: ?usize = null;

                for (self.dependencies.items, 0..) |dependency, i| {
                    if (dependency.eqlName(dependency)) {
                        maybe_dep_index = i;
                        break;
                    }
                }

                if (maybe_dep_index) |dep_index| {
                    // Since dependencies are not stored in any particurarly
                    // important order, we can use swapRemove which is more
                    // efficient than orderedRemove
                    return self.dependencies.swapRemove(dep_index);
                }

                return null;
            }

            pub fn getDependency(self: *Symbol, dependency_name: []const u8) ?Dependency {
                _ = dependency_name;
                for (self.dependencies.items) |dependency| {
                    if (dependency.eqlName(dependency)) {
                        return dependency;
                    }
                }

                return null;
            }

            pub fn hasDependencies(self: *Symbol) bool {
                return self.dependencies.items.len > 0;
            }

            pub fn hasDependenciesOfType(self: *Symbol, tag: std.meta.TagType(Dependency)) bool {
                for (self.dependencies.items) |dep| {
                    if (dep == tag) return true;
                }

                return false;
            }
        };

        pub const BlockedSymbolsIterator = struct {
            graph: *Self,
            hash_iter: StringHashMap(*Symbol).Iterator,

            pub fn init(graph: *Self) BlockedSymbolsIterator {
                return .{
                    .graph = graph,
                    .hash_iter = graph.symbols.iterator(),
                };
            }

            pub fn next(self: *BlockedSymbolsIterator) ?*Symbol {
                while (self.hash_iter.next()) |symbol| {
                    if (symbol.value_ptr.*.hasDependenciesOfType(.Linear)) {
                        return symbol.value_ptr.*;
                    }
                }

                return null;
            }
        };
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectSymbol(emitted: ?DepsGraph(void).EmittedSymbol, expected_name: []const u8, expected_partial: bool) !void {
    try expect(emitted != null);
    try expectEqualStrings(expected_name, emitted.?.symbol.name);
    try expectEqual(expected_partial, emitted.?.partial);
}

test "Simple dependency graph with circular dependencies" {
    const allocator = std.testing.allocator;

    var deps = DepsGraph(void).init(allocator);

    try deps.beginSymbol("SourceMap", {});
    try deps.addDependency("TextSpan");
    try deps.endSymbol();
    try expect(deps.readEmitted() == null);

    try deps.beginSymbol("TextSpan", {});
    try deps.addDependency("TextPosition");
    try deps.endSymbol();
    try expect(deps.readEmitted() == null);

    try deps.beginSymbol("TextPosition", {});
    try deps.addDependency("TextSpan");
    try deps.endSymbol();

    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "TextPosition");
        try expectEqual(s.partial, true);
    }

    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "TextSpan");
        try expectEqual(s.partial, false);
    }

    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "SourceMap");
        try expectEqual(s.partial, false);
    }

    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "TextPosition");
        try expectEqual(s.partial, false);
    }

    try expect(deps.readEmitted() == null);

    deps.deinit();
}

test "Blocked symbols iterator" {
    const allocator = std.testing.allocator;

    var deps = DepsGraph(void).init(allocator);

    try deps.beginSymbol("SourceMap", {});
    try deps.addDependency("TextSpan");
    try deps.endSymbol();
    try expect(deps.readEmitted() == null);

    try deps.beginSymbol("TextSpan", {});
    try deps.endSymbol();
    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "TextSpan");
        try expectEqual(s.partial, false);
    }
    try expect(deps.emitted.first != null);
    if (deps.readEmitted()) |s| {
        try expectEqualStrings(s.symbol.name, "SourceMap");
        try expectEqual(s.partial, false);
    }
    try expect(deps.readEmitted() == null);

    try deps.beginSymbol("TextPosition", {});
    try deps.addDependency("Cursor");
    try deps.endSymbol();
    try expect(deps.readEmitted() == null);

    var iter = deps.blockedIterator();
    const symbol = iter.next();

    try expect(symbol != null);
    try expectEqualStrings(symbol.?.name, "TextPosition");
    try expect(iter.next() == null);

    deps.deinit();
}

test "Three tier circular dependencies" {
    const allocator = std.testing.allocator;

    var deps = DepsGraph(void).init(allocator);

    try deps.beginSymbol("LookMaAnEnum", {});
    try deps.endSymbol();

    try deps.beginSymbol("WackType", {});
    try deps.addDependency("LameType");
    try deps.endSymbol();

    try deps.beginSymbol("LameType", {});
    try deps.addDependency("WackType");
    try deps.addDependency("WhatsAUnion");
    try deps.endSymbol();

    try deps.beginSymbol("WhatsAUnion", {});
    try deps.addDependency("LameType");
    try deps.endSymbol();

    try expectSymbol(deps.readEmitted(), "LookMaAnEnum", false);
    try expectSymbol(deps.readEmitted(), "WhatsAUnion", true);
    try expectSymbol(deps.readEmitted(), "LameType", true);
    try expectSymbol(deps.readEmitted(), "WackType", false);
    try expectSymbol(deps.readEmitted(), "WhatsAUnion", false);
    try expectSymbol(deps.readEmitted(), "LameType", false);

    try expect(deps.readEmitted() == null);

    deps.deinit();
}
