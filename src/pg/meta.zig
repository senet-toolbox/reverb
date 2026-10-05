const std = @import("std");

/// Extracts ORM metadata from a model struct
pub fn ModelMeta(comptime T: type) type {
    return struct {
        pub const Model = T;
        pub const fields = std.meta.fields(T);
        pub const field_count = fields.len;

        /// Get table name from model's orm_config config or derive from type name
        pub fn tableName() []const u8 {
            if (@hasDecl(T, "orm")) {
                const orm_config = @field(T, "orm");
                if (@hasField(@TypeOf(orm_config), "table")) {
                    return orm_config.table;
                }
            }
            if (@hasDecl(T, "orm_config")) {
                const orm_config_config = @field(T, "orm_config");
                if (@hasField(@TypeOf(orm_config_config), "table")) {
                    return orm_config_config.table;
                }
            }
            // Fallback: use type name lowercased (at comptime)
            return @typeName(T);
        }

        /// Get primary key field name
        pub fn primaryKey() ?[]const u8 {
            if (@hasDecl(T, "orm")) {
                const orm_config = @field(T, "orm");
                if (@hasField(@TypeOf(orm_config), "primary_key")) {
                    return @tagName(orm_config.primary_key);
                }
            }
            if (@hasDecl(T, "orm_config")) {
                const orm_config_config = @field(T, "orm_config");
                if (@hasField(@TypeOf(orm_config_config), "primary_key")) {
                    return @tagName(orm_config_config.primary_key);
                }
            }
            // Fallback: look for 'id' field
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, "id")) {
                    return "id";
                }
            }
            return null;
        }

        /// Get column name for a field (supports column mapping)
        pub fn columnName(comptime field_enum: std.meta.FieldEnum(T)) []const u8 {
            const field_name = @tagName(field_enum);

            if (@hasDecl(T, "orm")) {
                const orm_config = @field(T, "orm");
                if (@hasField(@TypeOf(orm_config), "columns")) {
                    const _columns = orm_config.columns;
                    if (@hasField(@TypeOf(_columns), field_name)) {
                        return @field(_columns, field_name);
                    }
                }
            }

            if (@hasDecl(T, "orm_config")) {
                const orm_config_config = @field(T, "orm_config");
                if (@hasField(@TypeOf(orm_config_config), "columns")) {
                    const _columns = orm_config_config.columns;
                    if (@hasField(@TypeOf(_columns), field_name)) {
                        return @field(_columns, field_name);
                    }
                }
            }
            // Default: field name equals column name
            return field_name;
        }

        /// Get all column names as a comma-separated string
        pub fn allColumns() []const u8 {
            return comptime blk: {
                var result: []const u8 = "";
                for (fields, 0..) |_, i| {
                    const field_enum: std.meta.FieldEnum(T) = @enumFromInt(i);
                    if (i > 0) result = result ++ ", ";
                    result = result ++ columnName(field_enum);
                }
                break :blk result;
            };
        }

        /// Get column names for specific fields
        pub fn columns(comptime field_enums: anytype) []const u8 {
            return comptime blk: {
                var result: []const u8 = "";
                for (field_enums, 0..) |field_enum, i| {
                    if (i > 0) result = result ++ ", ";
                    result = result ++ columnName(field_enum);
                }
                break :blk result;
            };
        }

        pub fn columnsNames(comptime field_enums: anytype, indicies: [][]const u8) void {
            inline for (field_enums, 0..) |field_enum, i| {
                indicies[i] = columnName(field_enum);
            }
        }

        /// Get field names as an array
        pub fn fieldNames() [field_count][]const u8 {
            comptime {
                var names: [field_count][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    names[i] = field.name;
                }
                return names;
            }
        }

        /// Check if a field exists
        pub fn hasField(name: []const u8) bool {
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return true;
                }
            }
            return false;
        }

        /// Get field type by name
        pub fn FieldType(comptime name: []const u8) type {
            return std.meta.fieldInfo(T, @field(std.meta.FieldEnum(T), name)).type;
        }

        /// Check if field is optional
        pub fn isOptional(comptime field_enum: std.meta.FieldEnum(T)) bool {
            const field_info = std.meta.fields(T)[@intFromEnum(field_enum)];
            return @typeInfo(field_info.type) == .optional;
        }

        /// Get the inner type if optional, otherwise the type itself
        pub fn UnwrappedFieldType(comptime field_enum: std.meta.FieldEnum(T)) type {
            const field_info = std.meta.fields(T)[@intFromEnum(field_enum)];
            const field_type = field_info.type;
            return switch (@typeInfo(field_type)) {
                .optional => |opt| opt.child,
                else => field_type,
            };
        }
    };
}

/// Helper to check if a type has orm_config configuration
pub fn isModel(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and (@hasDecl(T, "orm") or @hasDecl(T, "orm_config"));
}

/// Validate that a type is a valid ORM model
pub fn validateModel(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("ORM model must be a struct");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ModelMeta basic" {
    const User = struct {
        id: i32,
        name: []const u8,
        email: []const u8,

        pub const orm_config = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    const Meta = ModelMeta(User);

    try std.testing.expectEqualStrings("users", Meta.tableName());
    try std.testing.expectEqualStrings("id", Meta.primaryKey().?);
    try std.testing.expectEqual(3, Meta.field_count);
}

test "ModelMeta column mapping" {
    const Post = struct {
        id: i32,
        userId: i32,
        createdAt: i64,

        pub const orm_config = .{
            .table = "posts",
            .primary_key = .id,
            .columns = .{
                .userId = "user_id",
                .createdAt = "created_at",
            },
        };
    };

    const Meta = ModelMeta(Post);

    try std.testing.expectEqualStrings("user_id", Meta.columnName(.userId));
    try std.testing.expectEqualStrings("created_at", Meta.columnName(.createdAt));
    try std.testing.expectEqualStrings("id", Meta.columnName(.id));
}

test "ModelMeta allColumns" {
    const Simple = struct {
        id: i32,
        name: []const u8,

        pub const orm_config = .{
            .table = "simple",
        };
    };

    const Meta = ModelMeta(Simple);
    try std.testing.expectEqualStrings("id, name", Meta.allColumns());
}
