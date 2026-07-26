const std = @import("std");
const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree.
pub fn generate(allocator: std.mem.Allocator, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "const std = @import(\"std\");\n");
    try out.appendSlice(allocator, "const goose = @import(\"goose\");\n");
    try out.appendSlice(allocator, "const proxy = goose.proxy;\n");
    try out.appendSlice(allocator, "const GStr = goose.core.value.GStr;\n");
    try out.appendSlice(allocator, "const GPath = goose.core.value.GPath;\n");
    try out.appendSlice(allocator, "const GSig = goose.core.value.GSig;\n");
    try out.appendSlice(allocator, "const GUFd = goose.core.value.GUFd;\n");
    try out.appendSlice(allocator, "const GVariant = goose.core.value.GVariant;\n\n");

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try out.appendSlice(allocator, "pub const ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy = struct {\n");
        try out.appendSlice(allocator, "    inner: proxy.Proxy,\n\n");

        try out.appendSlice(allocator, "    pub fn init(conn: *goose.Connection");
        if (dest == null) try out.appendSlice(allocator, ", dest: [:0]const u8");
        if (path == null) try out.appendSlice(allocator, ", path: [:0]const u8");
        try out.appendSlice(allocator, ") ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy {\n");
        try out.appendSlice(allocator, "        return .{ .inner = proxy.Proxy.init(conn, ");
        if (dest) |d| {
            try out.print(allocator, "\"{s}\"", .{d});
        } else {
            try out.appendSlice(allocator, "dest");
        }
        try out.appendSlice(allocator, ", ");
        if (path) |p| {
            try out.print(allocator, "\"{s}\"", .{p});
        } else {
            try out.appendSlice(allocator, "path");
        }
        try out.appendSlice(allocator, ", \"");
        try out.appendSlice(allocator, iface.name);
        try out.appendSlice(allocator, "\") };\n");
        try out.appendSlice(allocator, "    }\n\n");

        for (iface.methods) |method| {
            try out.appendSlice(allocator, "    pub fn ");
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "(self: ");
            try out.appendSlice(allocator, short_name);
            try out.appendSlice(allocator, "Proxy");

            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{in_idx});
                    }
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, try dbusTypeToZig(temp_alloc, arg.type, true));
                    in_idx += 1;
                }
            }

            // Return type
            var out_sig: ?[]const u8 = null;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "out")) {
                    out_sig = arg.type;
                    break;
                }
            }

            const out_type = if (out_sig) |s| try dbusTypeToZig(temp_alloc, s, false) else "void";
            const is_method_result = std.mem.eql(u8, out_type, "proxy.MethodResult");

            try out.appendSlice(allocator, ") !");
            try out.appendSlice(allocator, out_type);
            try out.appendSlice(allocator, " {\n");

            if (is_method_result) {
                try out.appendSlice(allocator, "        const res = try self.inner.call(\"");
            } else {
                try out.appendSlice(allocator, "        var res = try self.inner.call(\"");
            }
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "\", .{");

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    if (!first) try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try out.appendSlice(allocator, "});\n");

            if (std.mem.eql(u8, out_type, "void")) {
                try out.appendSlice(allocator, "        res.deinit();\n");
            } else if (is_method_result) {
                try out.appendSlice(allocator, "        return res;\n");
            } else {
                try out.appendSlice(allocator, "        defer res.deinit();\n");
                try out.appendSlice(allocator, "        return res.expectAlloc(");
                try out.appendSlice(allocator, out_type);
                try out.appendSlice(allocator, ");\n");
            }
            try out.appendSlice(allocator, "    }\n");
        }

        for (iface.signals) |signal| {
            try out.appendSlice(allocator, "    pub fn connect");
            try out.appendSlice(allocator, signal.name);
            try out.appendSlice(allocator, "(\n");
            try out.appendSlice(allocator, "        self: ");
            try out.appendSlice(allocator, short_name);
            try out.appendSlice(allocator, "Proxy,\n");
            try out.appendSlice(allocator, "        ctx: anytype,\n");
            try out.appendSlice(allocator, "        comptime callback: fn (@TypeOf(ctx), @Tuple(&[_]type{");

            var first = true;
            for (signal.args) |arg| {
                if (!first) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, try dbusTypeToZig(temp_alloc, arg.type, false));
                first = false;
            }

            try out.appendSlice(allocator, "})) void,\n    ) !void {\n");
            try out.appendSlice(allocator, "        try self.inner.connectSignal(@Tuple(&[_]type{");

            first = true;
            for (signal.args) |arg| {
                if (!first) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, try dbusTypeToZig(temp_alloc, arg.type, false));
                first = false;
            }

            try out.appendSlice(allocator, "}), \"");
            try out.appendSlice(allocator, signal.name);
            try out.appendSlice(allocator, "\", ctx, callback);\n    }\n");
        }

        try out.appendSlice(allocator, "};\n\n");
    }

    return out.toOwnedSlice(allocator);
}

fn matchBasicType(sig: []const u8) ?[]const u8 {
    if (sig.len != 1) return null;
    return switch (sig[0]) {
        'y' => "u8",
        'b' => "bool",
        'n' => "i16",
        'q' => "u16",
        'i' => "i32",
        'u' => "u32",
        'x' => "i64",
        't' => "u64",
        'd' => "f64",
        's' => "GStr",
        'o' => "GPath",
        'g' => "GSig",
        'h' => "GUFd",
        'v' => "GVariant",
        else => null,
    };
}

fn nextSingleSig(sig: []const u8) ?[]const u8 {
    if (sig.len == 0) return null;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return sig[0..1],
        'a' => {
            const child = nextSingleSig(sig[1..]) orelse return null;
            return sig[0 .. 1 + child.len];
        },
        '(', '{' => {
            var depth: usize = 0;
            const open_char = sig[0];
            const close_char: u8 = if (open_char == '(') ')' else '}';
            for (sig, 0..) |c, idx| {
                if (c == open_char) depth += 1;
                if (c == close_char) {
                    depth -= 1;
                    if (depth == 0) {
                        return sig[0 .. idx + 1];
                    }
                }
            }
            return null;
        },
        else => return null,
    }
}

fn dbusTypeToZig(allocator: std.mem.Allocator, sig: []const u8, is_param: bool) ![]const u8 {
    if (matchBasicType(sig)) |basic| {
        return basic;
    }

    // Dictionaries: a{kv}
    if (sig.len >= 4 and std.mem.startsWith(u8, sig, "a{") and sig[sig.len - 1] == '}') {
        const key_char = sig[2];
        const val_sig = sig[3 .. sig.len - 1];
        const val_type = try dbusTypeToZig(allocator, val_sig, false);

        const key_type = matchBasicType(sig[2..3]) orelse "u32";

        if (key_char == 's' or key_char == 'o' or key_char == 'g') {
            return try std.fmt.allocPrint(allocator, "std.StringHashMap({s})", .{val_type});
        } else {
            return try std.fmt.allocPrint(allocator, "std.AutoHashMap({s}, {s})", .{ key_type, val_type });
        }
    }

    // Arrays: a... (excluding dictionaries handled above)
    if (std.mem.startsWith(u8, sig, "a")) {
        const child_sig = sig[1..];
        const child_type = try dbusTypeToZig(allocator, child_sig, false);
        if (std.mem.eql(u8, child_type, "proxy.MethodResult") or std.mem.eql(u8, child_type, "anytype")) {
            if (is_param) return "anytype";
            return "proxy.MethodResult";
        }
        return try std.fmt.allocPrint(allocator, "[]const {s}", .{child_type});
    }

    // Structs / Tuples: (...)
    if (sig.len >= 2 and sig[0] == '(' and sig[sig.len - 1] == ')') {
        var inner = sig[1 .. sig.len - 1];
        var tuple_types = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        while (inner.len > 0) {
            const field_sig = nextSingleSig(inner) orelse break;
            const field_type = try dbusTypeToZig(allocator, field_sig, false);
            if (std.mem.eql(u8, field_type, "proxy.MethodResult") or std.mem.eql(u8, field_type, "anytype")) {
                if (is_param) return "anytype";
                return "proxy.MethodResult";
            }
            try tuple_types.append(allocator, field_type);
            inner = inner[field_sig.len..];
        }

        if (tuple_types.items.len > 0 and inner.len == 0) {
            var tuple_buf = try std.ArrayList(u8).initCapacity(allocator, 64);
            try tuple_buf.appendSlice(allocator, "@Tuple(&[_]type{ ");
            for (tuple_types.items, 0..) |t, idx| {
                if (idx > 0) try tuple_buf.appendSlice(allocator, ", ");
                try tuple_buf.appendSlice(allocator, t);
            }
            try tuple_buf.appendSlice(allocator, " })");
            return tuple_buf.toOwnedSlice(allocator);
        }
    }

    if (is_param) return "anytype";
    return "proxy.MethodResult";
}

test "dbusTypeToZig mappings" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("u8", try dbusTypeToZig(alloc, "y", false));
    try testing.expectEqualStrings("i32", try dbusTypeToZig(alloc, "i", false));
    try testing.expectEqualStrings("GStr", try dbusTypeToZig(alloc, "s", false));
    try testing.expectEqualStrings("GPath", try dbusTypeToZig(alloc, "o", false));
    try testing.expectEqualStrings("GVariant", try dbusTypeToZig(alloc, "v", false));

    // Arrays
    try testing.expectEqualStrings("[]const GStr", try dbusTypeToZig(alloc, "as", false));
    try testing.expectEqualStrings("[]const []const u8", try dbusTypeToZig(alloc, "aay", false));

    // Dictionaries
    try testing.expectEqualStrings("std.StringHashMap(GVariant)", try dbusTypeToZig(alloc, "a{sv}", false));
    try testing.expectEqualStrings("std.AutoHashMap(u32, u32)", try dbusTypeToZig(alloc, "a{uu}", false));
    try testing.expectEqualStrings("std.StringHashMap(std.StringHashMap(GVariant))", try dbusTypeToZig(alloc, "a{sa{sv}}", false));

    // Structs / Tuples
    try testing.expectEqualStrings("@Tuple(&[_]type{ i32, i32 })", try dbusTypeToZig(alloc, "(ii)", false));
    try testing.expectEqualStrings("@Tuple(&[_]type{ i32, GStr })", try dbusTypeToZig(alloc, "(is)", false));
    try testing.expectEqualStrings("@Tuple(&[_]type{ GStr, std.StringHashMap(GVariant) })", try dbusTypeToZig(alloc, "(sa{sv})", false));
    try testing.expectEqualStrings("[]const @Tuple(&[_]type{ i32, GStr })", try dbusTypeToZig(alloc, "a(is)", false));
    try testing.expectEqualStrings("@Tuple(&[_]type{ i32, @Tuple(&[_]type{ GStr, GStr }) })", try dbusTypeToZig(alloc, "(i(ss))", false));

    // Unrecognized fallbacks
    try testing.expectEqualStrings("anytype", try dbusTypeToZig(alloc, "z", true));
    try testing.expectEqualStrings("proxy.MethodResult", try dbusTypeToZig(alloc, "z", false));
}
