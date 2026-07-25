const std = @import("std");
const goose = @import("goose");
const GVariant = goose.core.value.GVariant;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Simulate reading a DBus message body containing an array of dict-entries (a{sv})

    // For testing, let's create an encoder and encode an array of dict entries manually,
    // then decode it using GVariant.
    const GStr = goose.core.value.GStr;

    var dict = std.StringHashMap(GVariant).init(allocator);
    try dict.put("key1", .{ .string = GStr.new("value1") });
    try dict.put("key2", .{ .int32 = 69 });

    const encoded = try goose.message.BodyEncoder.encode(allocator, dict);
    defer @constCast(&encoded).deinit();

    const sig = encoded.signature();
    const body = encoded.body();

    var decoder = goose.message.BodyDecoder.init(allocator, body, sig, .little);

    // Decode directly into std.StringHashMap (matches a{sv})
    var decoded = try decoder.decodeAlloc(std.StringHashMap(GVariant));
    defer decoded.deinit();
    std.debug.print("Count: {d}\n", .{decoded.count()});
    var it = decoded.iterator();
    while (it.next()) |item| {
        std.debug.print("Key: {s}\n", .{item.key_ptr.*});
        if (item.value_ptr.* == .string) {
            std.debug.print("Value: \"{s}\"\n", .{item.value_ptr.*.string.s});
        } else if (item.value_ptr.* == .int32) {
            std.debug.print("Value: #{d}\n", .{item.value_ptr.*.int32});
        }
    }

    std.debug.print("\n:: Testing User-Defined Union in StringHashMap\n", .{});
    const MyUnion = union(enum) {
        text: GStr,
        number: i32,
        flag: bool,
    };

    var union_dict = std.StringHashMap(MyUnion).init(allocator);
    try union_dict.put("custom_string", .{ .text = GStr.new("hello from union") });
    try union_dict.put("custom_int", .{ .number = 42 });
    try union_dict.put("custom_bool", .{ .flag = true });

    const u_encoded = try goose.message.BodyEncoder.encode(allocator, union_dict);
    defer @constCast(&u_encoded).deinit();

    var u_decoder = goose.message.BodyDecoder.init(allocator, u_encoded.body(), u_encoded.signature(), .little);
    var u_decoded = try u_decoder.decodeAlloc(std.StringHashMap(MyUnion));
    defer u_decoded.deinit();

    std.debug.print("Union Map Count: {d}\n", .{u_decoded.count()});
    var u_it = u_decoded.iterator();
    while (u_it.next()) |u_item| {
        std.debug.print("Key: {s} -> ", .{u_item.key_ptr.*});
        switch (u_item.value_ptr.*) {
            .text => |val| std.debug.print("text: \"{s}\"\n", .{val.s}),
            .number => |val| std.debug.print("number: {d}\n", .{val}),
            .flag => |val| std.debug.print("flag: {}\n", .{val}),
        }
    }

    std.debug.print("\n:: Testing User-Defined Union in AutoHashMap (a{{uv}})\n", .{});
    var auto_union_dict = std.AutoHashMap(u32, MyUnion).init(allocator);
    try auto_union_dict.put(100, .{ .text = GStr.new("hello from auto map") });
    try auto_union_dict.put(200, .{ .number = 999 });
    try auto_union_dict.put(300, .{ .flag = false });

    const au_encoded = try goose.message.BodyEncoder.encode(allocator, auto_union_dict);
    defer @constCast(&au_encoded).deinit();

    var au_decoder = goose.message.BodyDecoder.init(allocator, au_encoded.body(), au_encoded.signature(), .little);
    var au_decoded = try au_decoder.decodeAlloc(std.AutoHashMap(u32, MyUnion));
    defer au_decoded.deinit();

    std.debug.print("Auto Union Map Count: {d}\n", .{au_decoded.count()});
    var au_it = au_decoded.iterator();
    while (au_it.next()) |au_item| {
        std.debug.print("Key: #{d} -> ", .{au_item.key_ptr.*});
        switch (au_item.value_ptr.*) {
            .text => |val| std.debug.print("text: \"{s}\"\n", .{val.s}),
            .number => |val| std.debug.print("number: {d}\n", .{val}),
            .flag => |val| std.debug.print("flag: {}\n", .{val}),
        }
    }
}
