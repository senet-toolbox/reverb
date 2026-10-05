const std = @import("std");

// ============================================================================
// Stack Frame
// ============================================================================

pub const FrameType = enum {
    wasm,
    js,
    unknown,
};

pub const StackFrame = struct {
    function: ?[]const u8 = null,
    wasm_function_index: ?u32 = null,
    wasm_offset: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    frame_type: FrameType = .unknown,
    raw: ?[]const u8 = null,
};

// ============================================================================
// WASM Error
// ============================================================================

pub const WasmError = struct {
    type: []const u8,
    message: []const u8,
    is_wasm_trap: bool,
    crash_site: ?StackFrame = null,
    user_stack: []const StackFrame,
};

// ============================================================================
// Trace Event
// ============================================================================

pub const EventType = enum {
    click,
    dblclick,
    hover,
    mousemove,
    input,
    scroll,
    state_change,
};

pub const TraceEvent = struct {
    timestamp: i64,
    event_type: EventType,
    element_id: ?[]const u8,
    serialized_args: []const u8,
};

// ============================================================================
// Request Context — the HTTP request that was in-flight when the error occurred
// ============================================================================

pub const RequestContext = struct {
    method: []const u8 = "GET",
    url: []const u8 = "",
    status_code: ?u32 = null,
    body: ?[]const u8 = null,
    elapsed_ms: ?i64 = null,
};

// ============================================================================
// Error Report (inbound payload from the client)
// ============================================================================

pub const ErrorReport = struct {
    // Core error data
    element_id: ?[]const u8 = null,
    args: ?[]const u8 = null,
    wasmError: WasmError,
    events: []const TraceEvent,
    timestamp: i64,

    // Context: where was the user when it crashed?
    route: ?[]const u8 = null, // App route, e.g. "/dashboard/settings"
    url: ?[]const u8 = null, // Full browser URL including query params
    session_id: ?[]const u8 = null, // Correlate multiple errors from same session
    user_agent: ?[]const u8 = null, // Browser/OS — critical for WASM platform bugs

    // Deployment context: which build/environment?
    environment: ?[]const u8 = null, // "production", "staging", "development"
    release: ?[]const u8 = null, // Version string or commit SHA
    user_id: ?[]const u8 = null, // Who was affected (if auth exists)

    // Optional: the fetch call that triggered the error (if any)
    request_context: ?RequestContext = null,
};

// ============================================================================
// Crash-site helper: extracts nullable fields for DB binding
// ============================================================================

pub const CrashFields = struct {
    function: ?[]const u8,
    file: ?[]const u8,
    line: ?i32,
    column: ?i32,
    wasm_index: ?i32,
    wasm_offset: ?[]const u8,
    frame_type: ?[]const u8,

    pub fn extract(crash: ?StackFrame) CrashFields {
        if (crash) |cs| {
            return .{
                .function = cs.function,
                .file = cs.file,
                .line = if (cs.line) |l| @as(i32, @intCast(l)) else null,
                .column = if (cs.column) |c| @as(i32, @intCast(c)) else null,
                .wasm_index = if (cs.wasm_function_index) |w| @as(i32, @intCast(w)) else null,
                .wasm_offset = cs.wasm_offset,
                .frame_type = @tagName(cs.frame_type),
            };
        }
        return .{
            .function = null,
            .file = null,
            .line = null,
            .column = null,
            .wasm_index = null,
            .wasm_offset = null,
            .frame_type = null,
        };
    }
};

