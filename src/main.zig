const std = @import("std");
const testing = std.testing;

const RLPItem = union(enum) {
    String: []u8,
    List: []RLPItem,
};

const RLPItemType = enum {
    String,
    List,
};

const RlpError = error{InvalidInputFormat};

fn trimTrailingZeroes(bytes: []u8) []u8 {
    var length: usize = bytes.len;
    while (length > 0) {
        if (bytes[length - 1] != 0) {
            break;
        }
        length -= 1;
    }

    return bytes[0..length];
}

fn encode_rlp(input: RLPItem) !std.ArrayList(u8) {
    var rlp_encoding = std.ArrayList(u8).init(std.testing.allocator);

    switch (input) {
        .String => |bytes| {
            if (bytes.len == 1) {
                var first_ele = bytes[0];
                if (first_ele < 128) {
                    try rlp_encoding.append(first_ele);
                } else {
                    return RlpError.InvalidInputFormat;
                }
            } else {
                if (bytes.len <= 55) {
                    var bytes_len: u8 = @intCast(bytes.len);
                    try rlp_encoding.append(0x80 + bytes_len);
                    try rlp_encoding.insertSlice(1, bytes);
                } else if (bytes.len > 55) {
                    var bytes_len_array = std.mem.toBytes(bytes.len);
                    var bytes_len_slice: []u8 = bytes_len_array[0..8];
                    bytes_len_slice = trimTrailingZeroes(bytes_len_slice);

                    try rlp_encoding.append(0xb7 + @as(u8, @intCast(bytes_len_slice.len)));
                    try rlp_encoding.appendSlice(bytes_len_slice);
                    try rlp_encoding.appendSlice(bytes);
                }
            }
        },
        .List => |rlpItems| {
            for (rlpItems) |rlpItem| {
                var result = try encode_rlp(rlpItem);
                defer result.deinit();
                try rlp_encoding.appendSlice(result.items);
            }

            if (rlp_encoding.items.len < 56) {
                try rlp_encoding.insert(0, 0xc0 + @as(u8, @intCast(rlp_encoding.items.len)));
            } else {
                var bytes_len_array = std.mem.toBytes(rlp_encoding.items.len);
                var bytes_len_slice: []u8 = bytes_len_array[0..8];
                bytes_len_slice = trimTrailingZeroes(bytes_len_slice);

                try rlp_encoding.insert(0, 0xf7 + @as(u8, @intCast(bytes_len_slice.len)));
                try rlp_encoding.insertSlice(1, bytes_len_slice);
            }
        },
    }

    return rlp_encoding;
}

fn parseUnsignedFromBytes(input: []u8) usize {
    var result: usize = 0;
    for (input, 0..) |byte, idx| {
        var byte_usize: usize = @intCast(byte);
        result += byte_usize << @intCast((8 * idx));
    }

    return result;
}

const DecodedItemTypeAndLength = struct {
    itemType: RLPItemType,
    itemIdx: usize,
    itemLength: usize,
};

/// retrieve the type, the index from where the payload starts and the length of the payload
fn decodeItemTypeAndLength(input: []u8) !DecodedItemTypeAndLength {
    const first_byte = input[0];
    if (first_byte >= 0 and first_byte <= 0xbf) {
        if (first_byte <= 0x7f) {
            return DecodedItemTypeAndLength{
                .itemType = RLPItemType.String,
                .itemIdx = 0,
                .itemLength = 1,
            };
        } else if (first_byte <= 0xb7) {
            return DecodedItemTypeAndLength{ .itemType = RLPItemType.String, .itemIdx = 1, .itemLength = (first_byte - 0x80) };
        } else {
            const len_bytes = input[1 .. (first_byte - 0xb7) + 1];
            const len = parseUnsignedFromBytes(len_bytes);
            std.debug.print("I do come here {} \n", .{len});
            return DecodedItemTypeAndLength{ .itemType = RLPItemType.String, .itemIdx = (1 + len_bytes.len), .itemLength = len };
        }
    } else {
        if (first_byte <= 0xf7) {
            return DecodedItemTypeAndLength{ .itemType = RLPItemType.List, .itemIdx = 1, .itemLength = first_byte - 0xc0 };
        } else {
            const len_bytes = input[1 .. (first_byte - 0xf7) + 1];
            const len = parseUnsignedFromBytes(len_bytes);
            return DecodedItemTypeAndLength{ .itemType = RLPItemType.List, .itemIdx = (1 + len_bytes.len), .itemLength = len };
        }
    }
}

fn decode_rlp(input: []u8) !RLPItem {
    var index: usize = 0;
    var item: RLPItem = undefined;

    const result = try decodeItemTypeAndLength(input[index..]);
    const item_type = result.itemType;
    const item_idx = result.itemIdx;
    const item_length = result.itemLength;

    if (item_type == RLPItemType.String) {
        item = RLPItem{ .String = input[index + item_idx .. index + item_idx + item_length] };
    } else {
        var rlp_items = std.ArrayList(RLPItem).init(std.testing.allocator);
        defer rlp_items.deinit();

        while (index < input.len) {
            if (item_type == RLPItemType.String) {
                item = RLPItem{ .String = input[index + item_idx .. index + item_idx + item_length] };
            } else {
                var rlp_item = try decode_rlp(input[index + item_idx .. index + item_idx + item_length]);
                try rlp_items.append(rlp_item);
            }

            index += item_idx + item_length;
        }

        item = RLPItem{ .List = try rlp_items.toOwnedSlice() };
    }

    return item;
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "encode_rlp_string_single_byte" {
    var inputBytes = std.ArrayList(u8).init(std.testing.allocator);
    defer inputBytes.deinit();

    try inputBytes.append(42);

    var input = RLPItem{ .String = inputBytes.items };

    var result = try encode_rlp(input);
    defer result.deinit();

    std.debug.assert(result.items[0] == 42);
}

test "encode_rlp_string_less_than_55_byte" {
    var inputBytes = std.ArrayList(u8).init(std.testing.allocator);
    defer inputBytes.deinit();

    try inputBytes.append(42);
    try inputBytes.append(32);

    var input = RLPItem{ .String = inputBytes.items };

    var expected = [_]u8{ 0x80 + 2, 42, 32 };

    var result = try encode_rlp(input);
    defer result.deinit();

    std.debug.assert(std.mem.eql(u8, result.items, &expected));
}

test "encode_rlp_more_than_55_byte" {
    var inputBytes = std.ArrayList(u8).init(std.testing.allocator);
    defer inputBytes.deinit();

    for (0..56) |i| {
        try inputBytes.append(@intCast(i));
    }

    var input = RLPItem{ .String = inputBytes.items };
    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();

    try expected.append(0xb7 + 1);
    try expected.append(56);
    try expected.appendSlice(inputBytes.items);

    var result = try encode_rlp(input);
    defer result.deinit();
}

test "encode_rlp_list_less_than_56_bytes" {
    var inputBytes = std.ArrayList(u8).init(std.testing.allocator);
    defer inputBytes.deinit();

    try inputBytes.append(42);
    try inputBytes.append(32);

    var arr = [_]RLPItem{RLPItem{ .String = inputBytes.items }};
    var runtime_known_zero: usize = 0;
    var input = RLPItem{ .List = arr[runtime_known_zero..] };

    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();

    try expected.append(0xc0 + 3);
    try expected.append(0x80 + 2);
    try expected.append(42);
    try expected.append(32);

    var result = try encode_rlp(input);
    defer result.deinit();

    std.debug.assert(std.mem.eql(u8, result.items, expected.items));
}

test "encode_rlp_list_more_than_55_bytes" {
    var inputBytes = std.ArrayList(u8).init(std.testing.allocator);
    defer inputBytes.deinit();

    for (0..56) |i| {
        try inputBytes.append(@intCast(i));
    }

    var arr = [_]RLPItem{RLPItem{ .String = inputBytes.items }};
    var runtime_known_zero: usize = 0;
    var input = RLPItem{ .List = arr[runtime_known_zero..] };

    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();

    try expected.append(0xf7 + 1);
    try expected.append(58);
    try expected.append(0xb7 + 1);
    try expected.append(56);
    try expected.appendSlice(inputBytes.items);

    var result = try encode_rlp(input);
    defer result.deinit();

    std.debug.assert(std.mem.eql(u8, result.items, expected.items));
}

test "decode_rlp_single_byte" {
    var rlp = std.ArrayList(u8).init(std.testing.allocator);
    defer rlp.deinit();
    try rlp.append(42);

    var result = try decode_rlp(rlp.items);
    std.debug.assert(result.String[0] == 42);
}

test "decode_rlp_string_less_than_55_bytes" {
    var rlp = std.ArrayList(u8).init(std.testing.allocator);
    defer rlp.deinit();

    try rlp.append(0x80 + 2);
    try rlp.append(42);
    try rlp.append(32);

    var result = try decode_rlp(rlp.items);
    std.debug.assert(result.String[0] == 42);
    std.debug.assert(result.String[1] == 32);
}

test "decode_rlp_string_more_than_55_bytes" {
    var rlp = std.ArrayList(u8).init(std.testing.allocator);
    defer rlp.deinit();

    try rlp.append(0xb7 + 1);
    try rlp.append(56);
    for (0..56) |i| {
        try rlp.append(@intCast(i));
    }

    var result = try decode_rlp(rlp.items);

    for (0..56) |i| {
        std.debug.assert(result.String[i] == @as(u8, @intCast(i)));
    }
}

test "decode_rlp_list_less_than_55_bytes" {
    var rlp = std.ArrayList(u8).init(std.testing.allocator);
    defer rlp.deinit();

    try rlp.append(0xc0 + 3);
    try rlp.append(0x80 + 2);
    try rlp.append(42);
    try rlp.append(32);

    var result = try decode_rlp(rlp.items);
    defer std.testing.allocator.free(result.List);

    std.debug.assert(result.List[0].String[0] == 42);
    std.debug.assert(result.List[0].String[1] == 32);
}

test "decode_rlp_list_more_than_55_bytes" {
    var rlp = std.ArrayList(u8).init(std.testing.allocator);
    defer rlp.deinit();

    try rlp.append(0xf7 + 1);
    try rlp.append(58);
    try rlp.append(0xb7 + 1);
    try rlp.append(56);
    for (0..56) |i| {
        try rlp.append(@intCast(i));
    }

    var result = try decode_rlp(rlp.items);
    defer std.testing.allocator.free(result.List);

    for (0..56) |i| {
        std.debug.assert(result.List[0].String[i] == @as(u8, @intCast(i)));
    }
}
