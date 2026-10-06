const std = @import("std");
const print = std.debug.print;
const findIndex = @import("../helpers.zig").findIndex;
const http = std.http;

const Param = struct {
    key: []const u8,
    value: []const u8,
};

const QueryBuilder = @This();
arena: std.mem.Allocator,
params: std.array_list.Managed(Param),
str: []const u8,

/// This function takes a pointer to this QueryBuilder instance.
/// Deinitializes the query builder instance
/// # Parameters:
/// - `target`: *QueryBuilder.
/// - `arena`: std.mem.Allocator.
///
/// # Returns:
/// void.
pub fn init(query_builder: *QueryBuilder, arena: std.mem.Allocator) !void {
    query_builder.* = .{
        .arena = arena,
        .params = std.array_list.Managed(Param).init(arena),
        .str = "",
    };
}

/// This function takes a pointer to this QueryBuilder instance.
/// Deinitializes the query builder instance, loops over the keys and values to free
/// # Parameters:
/// - `target`: *QueryBuilder.
///
/// # Returns:
/// void.
pub fn deinit(query_builder: *QueryBuilder) void {
    for (query_builder.params.items) |param| {
        query_builder.arena.free(param.key);
        query_builder.arena.free(param.value);
    }
    query_builder.params.deinit();
    if (query_builder.str.len > 0) {
        query_builder.arena.free(query_builder.str);
    }
}

/// This function adds a value and key to the query builder.
/// # Example
/// try query.add("client_id", "98f3$j%gw54u4562$");
///
/// # Parameters:
/// - `key`: []const u8.
/// - `value`: []const u8.
///
/// # Returns:
/// void and adds to query builder list.
pub fn add(query_builder: *QueryBuilder, key: []const u8, value: []const u8) !void {
    const key_dup = try query_builder.arena.dupe(u8, key);
    const value_dup = try query_builder.arena.dupe(u8, value);
    try query_builder.params.append(.{ .key = key_dup, .value = value_dup });
}

pub fn clear(query_builder: *QueryBuilder) void {
    query_builder.params.clearRetainingCapacity();
}

/// This function removes a key.
/// # Example
/// try query.remove("client_id");
///
/// # Parameters:
/// - `key`: []const u8.
///
/// # Returns:
/// void
pub fn remove(query_builder: *QueryBuilder, key: []const u8) !void {
    // utils.assert_cm(query_builder.query_param_list.capacity > 0, "QueryBuilder not initilized");
    for (query_builder.params.items, 0..) |query_param, i| {
        if (std.mem.eql(u8, query_param.key, key)) {
            _ = query_builder.query_param_list.orderedRemove(i);
            break;
        }
    }
}

fn decoder(encoded: []const u8, decoded: *std.array_list.Managed(u8)) !void {
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%') {
            // Ensure there's enough room for two hex characters
            if (i + 2 >= encoded.len) {
                return error.InvalidInput;
            }

            const hex = encoded[i + 1 .. i + 3];
            const decodedByte = try std.fmt.parseInt(u8, hex, 16);
            try decoded.append(decodedByte);
            i += 2; // Skip over the two hex characters
        } else if (encoded[i] == '+') {
            // Replace '+' with a space
            try decoded.append(' ');
        } else {
            try decoded.append(encoded[i]);
        }
    }
}

pub fn parseParams(text: []const u8, allocator: *std.mem.Allocator) !?std.StringHashMap([]const u8) {
    // Details
    var params = std.StringHashMap([]const u8).init(allocator.*);

    // Loop
    var pos: usize = 0;
    while (pos < text.len) : (pos += 1) {
        const param_pair_end = findIndex(text[pos..], '&') orelse {
            // We only have one pair hence we add and return
            const seperator = findIndex(text[pos..], '=') orelse return error.SeperatorNotFound;
            const key = text[pos .. seperator + pos];
            var decoded = std.array_list.Managed(u8).init(allocator.*);
            try decoder(text[seperator + pos + 1 .. text.len], &decoded);
            const value = try decoded.toOwnedSlice();
            try params.put(key, value);
            return params;
        };
        // now we find the sperator in this pair and add it to the hashmap and continue on to the next
        // id=123
        const pair = text[pos .. param_pair_end + pos];
        const seperator = findIndex(pair, '=') orelse return error.SeperatorNotFound;
        const key = pair[0..seperator];
        var decoded = std.array_list.Managed(u8).init(allocator.*);
        try decoder(pair[seperator + 1 ..], &decoded);
        const value = try decoded.toOwnedSlice();
        try params.put(key, value);
        pos += param_pair_end;
    }
    return params;
}

/// This function encodes the url pass.
/// # Example
/// try query.urlEncoder("https://accounts.google.com/o/oauth2/v2/auth");
///
/// # Parameters:
/// - `url`: []const u8.
///
/// # Returns:
/// []const u8
pub fn urlEncoder(query_builder: *QueryBuilder, url: []const u8) ![]const u8 {
    var encoded = std.array_list.Managed(u8).init(query_builder.arena);
    defer encoded.deinit();

    for (url) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try encoded.append(c),
            ' ' => try encoded.append('+'),
            else => {
                try encoded.print("%{X:0>2}", .{c});
            },
        }
    }

    return encoded.toOwnedSlice();
}

/// This function encodes the query and set query_builder.str.
/// # Example
/// try query.queryStrEncode();
///
/// # Returns:
/// void
pub fn queryStrEncode(query_builder: *QueryBuilder) !void {
    if (query_builder.params.items.len == 0) {
        query_builder.str = "";
        return;
    }

    var list = std.array_list.Managed(u8).init(query_builder.arena);
    errdefer list.deinit();

    for (query_builder.params.items, 0..) |param, i| {
        if (i > 0) {
            try list.append('&');
        }

        // URL encode key
        const encoded_key = try query_builder.urlEncoder(param.key);
        defer query_builder.arena.free(encoded_key);
        try list.appendSlice(encoded_key);

        try list.append('=');

        // URL encode value
        const encoded_value = try query_builder.urlEncoder(param.value);
        defer query_builder.arena.free(encoded_value);
        try list.appendSlice(encoded_value);
    }

    query_builder.str = try list.toOwnedSlice();
}

/// This function generates the queried url plus the precursor url.
/// # Example
/// try query.generateUrl("https://accounts.google.com/o/oauth2/v2/auth", query.str);
///
/// # Parameters:
/// - `base_url`: []const u8.
/// - `query`: []const u8.
///
/// # Returns:
/// []const u8
pub fn generateUrl(query_builder: *QueryBuilder, base_url: []const u8, query: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(query_builder.arena);
    errdefer result.deinit();

    try result.appendSlice(base_url);
    if (query.len > 0) {
        try result.append('?');
        try result.appendSlice(query);
    }

    return result.toOwnedSlice();
}

// Helper function to get parameters in order
pub fn getParams(query_builder: *QueryBuilder) []const Param {
    return query_builder.params.items;
}
