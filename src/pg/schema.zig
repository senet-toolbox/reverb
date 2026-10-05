//! Schema — comptime DDL generator from a model struct.
//!
//! Two ways to declare schema info on a model:
//!
//! 1. Type-inferred (no explicit `.schema`): each Zig field maps via a default
//!    Zig→PG type table. Optional Zig types become nullable columns. Useful
//!    for quick prototyping.
//!
//! 2. Explicit `.schema` decl on `pub const orm`: per-column overrides for
//!    type, length, primary_key, unique, not_null, default. Anything not
//!    listed falls back to the inferred type.
//!
//! Example:
//! ```zig
//! const User = struct {
//!     id: i32,
//!     email: []const u8,
//!     name: []const u8,
//!     power: i32,
//!     created_at: ?i64 = null,
//!
//!     pub const orm = .{
//!         .table = "users",
//!         .primary_key = .id,
//!         .schema = .{
//!             .id = .{ .type = .serial, .primary_key = true },
//!             .email = .{ .type = .varchar, .length = 255, .unique = true, .not_null = true },
//!             .name = .{ .type = .text, .not_null = true },
//!             .power = .{ .type = .int, .default = "0" },
//!             .created_at = .{ .type = .timestamptz, .default = "now()" },
//!         },
//!     };
//! };
//!
//! const ddl = comptime schema.createTableSql(User);
//! // -> CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, email VARCHAR(255) ...)
//! ```
//!
//! Nothing here executes SQL — feed the generated string to `orm.rawExec`
//! (or `crud.rawQuery`) yourself when you want it applied.

const std = @import("std");
const meta = @import("meta.zig");

/// Supported PostgreSQL column types.
pub const ColumnType = enum {
    int, // INTEGER
    bigint, // BIGINT
    smallint, // SMALLINT
    serial, // SERIAL (auto-inc, implies NOT NULL + sequence)
    bigserial, // BIGSERIAL
    text, // TEXT
    varchar, // VARCHAR(n)
    char, // CHAR(n)
    bool, // BOOLEAN
    real, // REAL (float4)
    double, // DOUBLE PRECISION
    numeric, // NUMERIC
    timestamp, // TIMESTAMP
    timestamptz, // TIMESTAMP WITH TIME ZONE
    date, // DATE
    time, // TIME
    uuid, // UUID
    bytea, // BYTEA
    json, // JSON
    jsonb, // JSONB

    pub fn baseSql(self: ColumnType) []const u8 {
        return switch (self) {
            .int => "INTEGER",
            .bigint => "BIGINT",
            .smallint => "SMALLINT",
            .serial => "SERIAL",
            .bigserial => "BIGSERIAL",
            .text => "TEXT",
            .varchar => "VARCHAR",
            .char => "CHAR",
            .bool => "BOOLEAN",
            .real => "REAL",
            .double => "DOUBLE PRECISION",
            .numeric => "NUMERIC",
            .timestamp => "TIMESTAMP",
            .timestamptz => "TIMESTAMPTZ",
            .date => "DATE",
            .time => "TIME",
            .uuid => "UUID",
            .bytea => "BYTEA",
            .json => "JSON",
            .jsonb => "JSONB",
        };
    }

    /// Serial types imply NOT NULL.
    pub fn isSerial(self: ColumnType) bool {
        return self == .serial or self == .bigserial;
    }
};

/// Per-column override shape (everything optional).
pub const ColumnSpec = struct {
    type: ?ColumnType = null,
    length: ?u32 = null, // for varchar/char
    primary_key: bool = false,
    unique: bool = false,
    not_null: bool = false,
    default: ?DefaultValue = null,
};

/// Typed default expressions for DDL generation.
pub const DefaultValue = union(enum) {
    raw: []const u8,
    null,
    now,
    current_timestamp,
    true_,
    false_,
    gen_random_uuid,
    uuid_generate_v4,

    pub fn sql(self: DefaultValue) []const u8 {
        return switch (self) {
            .raw => |expr| expr,
            .null => "NULL",
            .now => "now()",
            .current_timestamp => "CURRENT_TIMESTAMP",
            .true_ => "true",
            .false_ => "false",
            .gen_random_uuid => "gen_random_uuid()",
            .uuid_generate_v4 => "uuid_generate_v4()",
        };
    }
};

/// Convenience namespace for common typed defaults.
pub const defaults = struct {
    pub const now: DefaultValue = .now;
    pub const current_timestamp: DefaultValue = .current_timestamp;
    pub const true_: DefaultValue = .true_;
    pub const false_: DefaultValue = .false_;
    pub const gen_random_uuid: DefaultValue = .gen_random_uuid;
    pub const uuid_generate_v4: DefaultValue = .uuid_generate_v4;

    pub fn raw(sql_fragment: []const u8) DefaultValue {
        return .{ .raw = sql_fragment };
    }
};

/// Infer a sensible default ColumnType from a Zig field type.
pub fn inferType(comptime FieldType: type) ColumnType {
    const T = switch (@typeInfo(FieldType)) {
        .optional => |o| o.child,
        else => FieldType,
    };

    return switch (@typeInfo(T)) {
        .int => |int_info| switch (int_info.bits) {
            0...16 => .smallint,
            17...32 => .int,
            else => .bigint,
        },
        .float => |float_info| switch (float_info.bits) {
            0...32 => .real,
            else => .double,
        },
        .array => |arr| if (arr.child == u8 and arr.len == 16) .uuid else @compileError("Cannot infer SQL type for " ++ @typeName(T)),
        .bool => .bool,
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) .text else @compileError("Unsupported pointer type for SQL inference: " ++ @typeName(T)),
        else => @compileError("Cannot infer SQL type for " ++ @typeName(T)),
    };
}

/// Whether a Zig field type is `?T` (i.e. nullable column).
pub fn isOptional(comptime FieldType: type) bool {
    return @typeInfo(FieldType) == .optional;
}

/// Build a `CREATE TABLE IF NOT EXISTS ...` string at comptime.
pub fn createTableSql(comptime T: type) []const u8 {
    comptime {
        const Meta = meta.ModelMeta(T);
        const table = Meta.tableName();

        var sql: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ table ++ " (";

        for (Meta.fields, 0..) |field, i| {
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ columnDefinitionSql(T, field);
        }

        sql = sql ++ ")";
        return sql;
    }
}

/// Build a `DROP TABLE IF EXISTS ...` string.
pub fn dropTableSql(comptime T: type) []const u8 {
    comptime {
        const Meta = meta.ModelMeta(T);
        return "DROP TABLE IF EXISTS " ++ Meta.tableName();
    }
}

/// Build a `TRUNCATE TABLE ...` string.
pub fn truncateSql(comptime T: type) []const u8 {
    comptime {
        const Meta = meta.ModelMeta(T);
        return "TRUNCATE TABLE " ++ Meta.tableName();
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Look up the explicit ColumnSpec for a field, if any.
fn columnSpec(comptime T: type, comptime field_name: []const u8) ?ColumnSpec {
    if (!@hasDecl(T, "orm")) return null;
    const orm_config = @field(T, "orm");
    if (!@hasField(@TypeOf(orm_config), "schema")) return null;

    const _schema = orm_config.schema;
    if (!@hasField(@TypeOf(_schema), field_name)) return null;

    const raw = @field(_schema, field_name);
    // Coerce anonymous-struct literal into ColumnSpec.
    var spec: ColumnSpec = .{};
    if (@hasField(@TypeOf(raw), "type")) spec.type = raw.type;
    if (@hasField(@TypeOf(raw), "length")) spec.length = raw.length;
    if (@hasField(@TypeOf(raw), "primary_key")) spec.primary_key = raw.primary_key;
    if (@hasField(@TypeOf(raw), "unique")) spec.unique = raw.unique;
    if (@hasField(@TypeOf(raw), "not_null")) spec.not_null = raw.not_null;
    if (@hasField(@TypeOf(raw), "default")) spec.default = coerceDefaultValue(@TypeOf(raw.default), raw.default);
    return spec;
}

fn coerceDefaultValue(comptime D: type, value: D) DefaultValue {
    if (D == DefaultValue) return value;

    return switch (@typeInfo(D)) {
        .bool => if (value) .true_ else .false_,
        .int, .comptime_int => .{ .raw = std.fmt.comptimePrint("{d}", .{value}) },
        .float, .comptime_float => .{ .raw = std.fmt.comptimePrint("{d}", .{value}) },
        .array => |arr| if (arr.child == u8) .{ .raw = value[0..arr.len] } else @compileError("Unsupported schema default type: " ++ @typeName(D)),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk .{ .raw = value };
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    break :blk .{ .raw = value[0..child_info.array.len] };
                }
            }
            @compileError("Unsupported schema default type: " ++ @typeName(D));
        },
        .optional => |opt| if (opt.child == DefaultValue) if (value) |v| v else .null else @compileError("Unsupported optional schema default type: " ++ @typeName(D)),
        .enum_literal => blk: {
            const result: DefaultValue = value;
            break :blk result;
        },
        else => @compileError("Unsupported schema default type: " ++ @typeName(D)),
    };
}

/// Comptime-build the SQL fragment for one column: `name TYPE [MOD ...]`.
fn columnDefinitionSql(comptime T: type, comptime field: std.builtin.Type.StructField) []const u8 {
    comptime {
        const Meta = meta.ModelMeta(T);
        const field_enum = @field(std.meta.FieldEnum(T), field.name);
        const col_name = Meta.columnName(field_enum);

        const spec = columnSpec(T, field.name) orelse ColumnSpec{};
        const col_type = spec.type orelse inferType(field.type);

        var s: []const u8 = col_name ++ " " ++ col_type.baseSql();

        // Length suffix for varchar/char.
        if (spec.length) |len| {
            if (col_type == .varchar or col_type == .char) {
                s = s ++ "(" ++ std.fmt.comptimePrint("{d}", .{len}) ++ ")";
            }
        }

        // PRIMARY KEY (also from primary_key decl on `orm`).
        const is_pk = spec.primary_key or isPrimaryKey(T, field.name);
        if (is_pk) s = s ++ " PRIMARY KEY";

        // NOT NULL — automatic for serials and pk; explicit when requested
        // and field is not declared optional.
        const auto_not_null = col_type.isSerial() or is_pk;
        if ((spec.not_null or auto_not_null) and !isOptional(field.type)) {
            if (!is_pk) s = s ++ " NOT NULL";
        }

        if (spec.unique) s = s ++ " UNIQUE";

        if (spec.default) |def| s = s ++ " DEFAULT " ++ def.sql();

        return s;
    }
}

/// Check if a given field is the model's declared primary key.
fn isPrimaryKey(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "orm")) return false;
    const orm_config = @field(T, "orm");
    if (!@hasField(@TypeOf(orm_config), "primary_key")) return false;
    return std.mem.eql(u8, @tagName(orm_config.primary_key), field_name);
}

// ============================================================================
// Tests
// ============================================================================

test "createTableSql inferred types" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,
        created_at: ?i64 = null,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    const ddl = comptime createTableSql(User);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, power INTEGER, created_at BIGINT)",
        ddl,
    );
}

test "createTableSql with explicit schema" {
    const User = struct {
        id: i32,
        email: []const u8,
        name: []const u8,
        power: i32,
        created_at: ?i64 = null,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
            .schema = .{
                .id = .{ .type = .serial, .primary_key = true },
                .email = .{ .type = .varchar, .length = 255, .unique = true, .not_null = true },
                .name = .{ .type = .text, .not_null = true },
                .power = .{ .type = .int, .default = "0" },
                .created_at = .{ .type = .timestamptz, .default = "now()" },
            },
        };
    };

    const ddl = comptime createTableSql(User);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, email VARCHAR(255) NOT NULL UNIQUE, name TEXT NOT NULL, power INTEGER DEFAULT 0, created_at TIMESTAMPTZ DEFAULT now())",
        ddl,
    );
}

test "createTableSql with typed defaults and uuid helpers" {
    const Event = struct {
        id: [16]u8,
        is_active: bool = true,
        created_at: i64,

        pub const orm = .{
            .table = "events",
            .primary_key = .id,
            .schema = .{
                .id = .{ .default = defaults.gen_random_uuid },
                .is_active = .{ .default = false },
                .created_at = .{ .type = .timestamptz, .default = defaults.now },
            },
        };
    };

    const ddl = comptime createTableSql(Event);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), is_active BOOLEAN DEFAULT false, created_at TIMESTAMPTZ DEFAULT now())",
        ddl,
    );
}

test "dropTableSql" {
    const User = struct {
        id: i32,
        pub const orm = .{ .table = "users" };
    };
    try std.testing.expectEqualStrings("DROP TABLE IF EXISTS users", comptime dropTableSql(User));
}

test "truncateSql" {
    const User = struct {
        id: i32,
        pub const orm = .{ .table = "users" };
    };
    try std.testing.expectEqualStrings("TRUNCATE TABLE users", comptime truncateSql(User));
}
