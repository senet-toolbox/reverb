const std = @import("std");
const Allocator = std.mem.Allocator;
const Tripwire = @import("Tripwire.zig");
const TrackingAllocator = @import("TrackingAllocator.zig");
const posix = std.posix;
const system = std.posix.system;
const print = std.debug.print;
const log = std.log.scoped(.tcp_demo);
const Parsed = std.json.Parsed;
const net = std.net;
const helpers = @import("helpers.zig");
const WebSocket = @import("loom").WebSocket;
const Abstractions = @import("Abstractions.zig");
const builtin = @import("builtin");

// const Loom = @import("engine/Loom.zig");
// const Scheduler = @import("engine/async/Scheduler.zig");
const Radix = @import("trees/radix.zig");
const Cors = @import("core/Cors.zig");
const Context = @import("context.zig");
const Metrics = @import("metrics.zig");
const Buckets = @import("metrics/Buckets.zig");
const getAllRoutes = Metrics.getAllRoutes;
const healthCheck = Metrics.healthCheck;
const EndPoints = Metrics.EndPoints;
// const handle = @import("handler.zig").handler;
const Ctx_pm = @import("handler.zig").Ctx_pm;
const StringBuilder = @import("core/builders.zig").String;
const ContentType = @import("helpers.zig").ContentType;
const WSS = @import("wss.zig").WSS;
const loompkg = @import("loom");
const Logger = loompkg.Logger;
const Loom = loompkg.Loom;
const Client = loompkg.Client;

pub fn Server(comptime Config: type) type {
    return struct {
        const Reverb = @This();
        pub const MAX_RECV_SIZE: usize = (Config{}).max_body_size;

        var use_cors: bool = false;
        // Radix tree
        routes: [5]Radix,
        arena: Allocator,
        config: Config,
        tracking_allocator: ?*TrackingAllocator = null,
        // cors: ?Cors = null,
        logger: Logger = undefined,
        // Event Loop
        loom: Loom(*Reverb),
        tripwire: Tripwire = undefined,
        wss: ?WSS = null,
        context_pool: Abstractions.ManagedMemoryPool(Context),
        context_slots: []*Context,
        request_buffers: []RequestBuffer,

        // ctx: *Context = undefined,

        const HandlerFunc = *const fn (*Context) anyerror!void;
        pub const Next = *const fn (*Context) anyerror!void;
        pub const MiddleFunc = *const fn (Next, *Context) anyerror!HandlerFunc;
        pub const GroupRoute = struct {
            path: []const u8,
            method: Methods,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        };

        const MethodLookup = struct {
            // First level lookup based on the first character of the method.
            first_char: [256]u8,

            /// Initializes a lookup table with predefined values for known HTTP methods.
            pub fn init() @This() {
                var table = @This(){
                    // Create an array of 256 bytes, all initialized to 0.
                    .first_char = [_]u8{0} ** 256,
                };

                // Assign a unique integer for each known HTTP method based on its first letter.
                // Note: If multiple methods share the same first letter (e.g. POST and PATCH),
                // they will both map to the same value.
                table.first_char['G'] = 0; // GET
                table.first_char['P'] = 1; // POST (or PATCH)
                table.first_char['D'] = 2; // DELETE
                table.first_char['H'] = 3; // HEAD
                table.first_char['O'] = 4; // OPTIONS
                table.first_char['C'] = 5; // CONNECT
                table.first_char['T'] = 6; // TRACE

                return table;
            }

            /// Returns the associated integer for a given HTTP method.
            /// If the method is empty or unknown, returns 0 (the default value).
            pub fn lookup(self: *const MethodLookup, method: []const u8) u8 {
                if (method.len == 0) return 0;
                return self.first_char[method[0]];
            }
        }.init();

        fn parseMiddleWare(reverb: *Reverb, func_num: usize, my_Handler: HandlerFunc, middleswares: []const MiddleFunc, ctx: *Context) !void {
            if (func_num + 1 > middleswares.len) {
                my_Handler(ctx) catch |err| {
                    log.debug("Handler error: {any}", .{err});
                    return err;
                };
            } else {
                const first_func = middleswares[func_num];
                const wrappedFunc = first_func(my_Handler, ctx) catch |err| {
                    return err;
                };
                try reverb.parseMiddleWare(func_num + 1, wrappedFunc, middleswares, ctx);
            }
        }

        const Methods = enum {
            GET,
            POST,
            DELETE,
            HEAD,
            OPTIONS,
            CONNECT,
            TRACE,
        };

        const RequestBuffer = struct {
            socket: ?posix.socket_t = null,
            read_timeout: i64 = 0,
            data: ?[]u8 = null,
            len: usize = 0,

            fn reset(self: *RequestBuffer, allocator: Allocator) void {
                if (self.data) |data| {
                    allocator.free(data);
                }
                self.* = .{};
            }

            fn bytes(self: *const RequestBuffer) []const u8 {
                const data = self.data orelse return "";
                return data[0..self.len];
            }

            fn append(
                self: *RequestBuffer,
                allocator: Allocator,
                client: *Client,
                chunk: []const u8,
                max_len: usize,
            ) !void {
                if (self.socket == null or
                    self.socket.? != client.socket or
                    self.read_timeout != client.read_timeout)
                {
                    self.reset(allocator);
                    self.socket = client.socket;
                    self.read_timeout = client.read_timeout;
                }

                if (chunk.len > max_len - self.len) return error.RequestTooLarge;
                try self.ensureCapacity(allocator, self.len + chunk.len, max_len);

                const data = self.data.?;
                @memcpy(data[self.len .. self.len + chunk.len], chunk);
                self.len += chunk.len;
            }

            fn ensureCapacity(
                self: *RequestBuffer,
                allocator: Allocator,
                needed: usize,
                max_len: usize,
            ) !void {
                if (self.data) |data| {
                    if (needed <= data.len) return;

                    const next_cap = @min(max_len, @max(needed, data.len * 2));
                    const next = try allocator.alloc(u8, next_cap);
                    @memcpy(next[0..self.len], data[0..self.len]);
                    allocator.free(data);
                    self.data = next;
                    return;
                }

                const initial_cap = @min(max_len, @max(needed, @as(usize, 4096)));
                self.data = try allocator.alloc(u8, initial_cap);
            }
        };

        /// This function adds the route to the reverb radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `method`: Methods,
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn addRoute(
            reverb: *Reverb,
            path: []const u8,
            method: Methods,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            std.log.info("addRoute {s} {s}", .{ path, method });
            // const idx = MethodLookup.first_char[method[0]];
            var radix = reverb.routes[@as(usize, @intFromEnum(method))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            switch (method) {
                .GET => try addToEndpoints(&Metrics.end_points.GET, route_path, reverb.arena),
                .POST => try addToEndpoints(&Metrics.end_points.POST, route_path, reverb.arena),
                .DELETE => try addToEndpoints(&Metrics.end_points.DELETE, route_path, reverb.arena),
                else => return error.CouldNotMatchMethod,
            }
            return;
        }

        /// This function adds the route to the reverb Get radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn get(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.GET))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.GET, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the reverb Get radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn all(
            reverb: *Reverb,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.GET))];
            radix.universal_mode = true;
            try radix.addUniversalRoute(handler, middlewares);
            radix.universal_mode = true;
            reverb.routes[@as(usize, @intFromEnum(Methods.GET))] = radix;
            return;
        }

        /// This function adds the route to the reverb Delete radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn delete(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.DELETE))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.DELETE, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the POST radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn post(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.POST))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.POST, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the reverb Head radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn head(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.HEAD))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.HEAD, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the reverb Options radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn options(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.OPTIONS))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.OPTIONS, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the reverb Connect radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn connect(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.CONNECT))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.CONNECT, route_path, reverb.arena);
            return;
        }

        /// This function adds the route to the reverb Trace radix tree.
        /// Deinitializes the reverb instance recursively calls routes deinit routes from radix tree
        /// # Parameters:
        /// - `target`: *Reverb.
        /// - `path`: []const u8
        /// - `handler`: HandlerFunc
        /// - `middlewares`: []const MiddleFunc
        ///
        /// # Returns:
        /// !void.
        pub fn trace(
            reverb: *Reverb,
            path: []const u8,
            handler: HandlerFunc,
            middlewares: []const MiddleFunc,
        ) !void {
            var radix = reverb.routes[@as(usize, @intFromEnum(Methods.TRACE))];
            const out = try std.fmt.allocPrint(reverb.arena, "{s}", .{path});
            try radix.addRoute(out, handler, middlewares);
            const end_colon_op = std.mem.indexOf(u8, path, "/:");
            var route_path: []const u8 = path;
            if (end_colon_op) |end_colon| {
                route_path = path[0..end_colon];
            }
            // Add the path to the appropriate endpoints array
            try addToEndpoints(&Metrics.end_points.TRACE, route_path, reverb.arena);
            return;
        }

        /// Helper function to add a path to the respective endpoints array
        fn addToEndpoints(endpoints: *?[][]const u8, path: []const u8, allocator: std.mem.Allocator) !void {
            if (endpoints.*) |existing| {
                // Resize the existing array to accommodate one more path
                var new_endpoints = try allocator.realloc(existing, existing.len + 1);
                // Duplicate the path string to ensure it's owned by the endpoints
                new_endpoints[existing.len] = try allocator.dupe(u8, path);
                endpoints.* = new_endpoints;
            } else {
                // Create a new array with one path
                var new_endpoints = try allocator.alloc([]const u8, 1);
                new_endpoints[0] = try allocator.dupe(u8, path);
                endpoints.* = new_endpoints;
            }
        }

        pub fn groupRoutes(
            reverb: *Reverb,
            group_path: []const u8,
            grouped_routes: []const GroupRoute,
        ) !void {
            // pick a sane upper bound for your paths:
            // const MaxPathLen = 256;
            // var buf: [MaxPathLen]u8 = undefined;

            for (grouped_routes) |gr| {
                const out = try std.fmt.allocPrint(reverb.arena, "{s}{s}", .{ group_path, gr.path });
                try reverb.addRoute(out, gr.method, gr.handler, gr.middlewares);
            }
        }

        pub fn detectConfig(file: std.Io.File) Config {
            const force_color: ?bool = if (builtin.os.tag == .wasi)
                null // wasi does not support environment variables
            else if (std.process.Environ.containsConstant("NO_COLOR"))
                false
            else if (std.process.Environ.containsConstant("CLICOLOR_FORCE"))
                true
            else
                null;

            if (force_color == false) return .no_color;

            if (file.getOrEnableAnsiEscapeSupport()) return .escape_codes;

            return if (force_color == true) .escape_codes else .no_color;
        }

        // Radix is a Radix tree routes is a hashmap with the method, each method has a radix tree
        pub fn callRoute(reverb: *Reverb, ctx_pm: Ctx_pm, passed_ctx: *Context) !void {
            const idx = MethodLookup.first_char[ctx_pm.method[0]];
            var radix = reverb.routes[idx];

            // this cuts almost half
            const entry = radix.searchRoute(ctx_pm.path) catch return error.SearchRoute;

            if (entry == null) {
                // const ret_addr = @returnAddress();
                // // const debug_info = std.debug.getSelfDebugInfo() catch @panic("Could not get debug_info");
                // // // 1) Prepare a big enough buffer on the stack
                // var buffer: [512]u8 = undefined;
                // var stream = std.Io.Writer.fixed(&buffer);
                // const writer = &stream;
                // //
                // // // 3) Call printSourceAtAddress into *your* writer
                // // const tty = detectConfig(std.fs.File.stderr());
                // // try std.debug.printSourceAtAddress(debug_info, writer, ret_addr, tty);
                //
                // var threaded: std.Io.Threaded = .init(reverb.arena, .{});
                // const io = threaded.io();
                // defer threaded.deinit();
                //
                // var text_arena = std.heap.ArenaAllocator.init());
                // defer text_arena.deinit();
                //
                // const debug_info = std.debug.getSelfDebugInfo() catch @panic("Could not get debug_info");
                //
                // std.debug.printSourceAtAddress(
                //     io,
                //     &text_arena,
                //     debug_info,
                //     .{ .writer = writer }, // or detect from stderr
                //     .{ .address = ret_addr },
                // ) catch {};
                //
                // const outSlice = buffer[0..stream.end];
                // const start = std.mem.indexOf(u8, outSlice, "src") orelse std.mem.indexOf(u8, outSlice, "std") orelse 0;
                // const src = buffer[start..stream.end];
                // var sections = std.mem.splitScalar(u8, src, ':');
                // var indents = std.mem.splitScalar(u8, src, '\n');
                // const file_name = sections.next() orelse return;
                // const line = sections.next() orelse return;
                // const u32_line_n: u32 = std.fmt.parseInt(u32, line, 10) catch return;
                // _ = indents.next().?;
                // const fn_name = indents.next().?;
                // const err_str = try std.fmt.allocPrint(reverb.arena, "{any}", .{error.MethodNotSupported});
                // const function_name = try std.fmt.allocPrint(reverb.arena, "{s}", .{fn_name[0 .. fn_name.len - 2]});
                // const file_name_alloc = try std.fmt.allocPrint(reverb.arena, "{s}", .{file_name});
                // _ = Tripwire.Error{
                //     .timestamp = std.time.timestamp(),
                //     .error_name = err_str,
                //     .line = u32_line_n,
                //     .file = file_name_alloc,
                //     .request = ctx_pm.path,
                //     .function = function_name,
                // };
                // Reverb.instance.tripwire.recordError(payload);
                return error.RouteNotSupported;
            }
            if (entry.?.route_func == null) {
                return error.MethodNotSupported;
            }
            const entry_fn = entry.?.route_func.?.handler_func;
            const middlewares = entry.?.route_func.?.middlewares;
            const param_args_op = entry.?.param_args;
            if (param_args_op) |param_args| {
                if (param_args.items.len > 0) {
                    for (param_args.items) |param| {
                        passed_ctx.addQueryParam(param.param, param.value) catch |err| {
                            try reverb.logger.err("AppendQueryParam Error: {any}", .{err}, null);
                            return error.AppendQueryParam;
                        };
                    }
                }
            }

            if (middlewares.len > 0) {
                reverb.parseMiddleWare(0, entry_fn, middlewares, passed_ctx) catch return error.ParsingMiddleware;
            } else {
                entry_fn(passed_ctx) catch |err| {
                    // const ret_addr = @intFromPtr(entry_fn);
                    // const debug_info = std.debug.getSelfDebugInfo() catch @panic("Could not get debug_info");
                    // // 1) Prepare a big enough buffer on the stack
                    // // 1) Prepare a big enough buffer on the stack
                    // var buffer: [512]u8 = undefined;
                    // var stream = std.Io.Writer.fixed(&buffer);
                    // const writer = &stream;
                    //
                    // // 3) Call printSourceAtAddress into *your* writer
                    // const tty = std.io.tty.detectConfig(std.fs.File.stderr());
                    // try std.debug.printSourceAtAddress(debug_info, writer, ret_addr, tty);
                    // const outSlice = buffer[0..stream.end];
                    // const start = std.mem.indexOf(u8, outSlice, "src") orelse std.mem.indexOf(u8, outSlice, "std") orelse 0;
                    // const src = buffer[start..stream.end];
                    // var sections = std.mem.splitScalar(u8, src, ':');
                    // var indents = std.mem.splitScalar(u8, src, '\n');
                    // const file_name = sections.next() orelse return;
                    // const file_name_alloc = try std.fmt.allocPrint(reverb.arena, "{s}", .{file_name});
                    // const line = sections.next() orelse return;
                    // const u32_line_n: u32 = try std.fmt.parseInt(u32, line, 10);
                    // _ = indents.next().?;
                    // const fn_name = indents.next().?;
                    // const err_str = try std.fmt.allocPrint(reverb.arena, "{any}", .{error.MethodNotSupported});
                    // const function_name = try std.fmt.allocPrint(reverb.arena, "{s}", .{fn_name[0 .. fn_name.len - 2]});
                    // _ = Tripwire.Error{
                    //     .timestamp = std.time.timestamp(),
                    //     .error_name = err_str,
                    //     .line = u32_line_n,
                    //     .file = file_name_alloc,
                    //     .request = ctx_pm.path,
                    //     .function = function_name,
                    // };
                    // Reverb.instance.tripwire.recordError(payload);
                    return err;
                };
            }
        }

        // Radix is a Radix tree routes is a hashmap with the method, each method has a radix tree
        pub fn getRoute(t: *Reverb, ctx_pm: Ctx_pm) !?HandlerFunc {
            const idx = MethodLookup.first_char[ctx_pm.method[0]];
            var radix = t.routes[idx];
            // var op_method_rdx_tree: ?Radix = null;
            // op_method_rdx_tree = reverb.routes.get(ctx_pm.method);
            // var rdx_tree = op_method_rdx_tree orelse return null;
            // // const path = try reverb.arena.dupe(u8, ctx_pm.path);
            const entry = try radix.searchRoute(ctx_pm.path);
            if (entry == null) {
                return error.MethodNotSupported;
            }
            if (entry.?.route_func == null) {
                return error.MethodNotSupported;
            }
            const entry_fn: HandlerFunc = @ptrCast(entry.?.route_func.?.handler_func);
            // return apiTest;
            return entry_fn;
        }

        // fn createContext(reverb: *Reverb, comptime T: type, data: T) !Context {
        //     const ctx = try Context.init(reverb.arena, data);
        //     return ctx;
        // }

        /// This is the Cors struct default set to null
        pub var cors: ?Cors = null;
        pub fn new(target: *Reverb, config: Config, arena: Allocator) !void {
            var radix1: Radix = undefined;
            try radix1.init(arena);

            var radix2: Radix = undefined;
            try radix2.init(arena);

            var radix3: Radix = undefined;
            try radix3.init(arena);

            var radix4: Radix = undefined;
            try radix4.init(arena);

            var radix5: Radix = undefined;
            try radix5.init(arena);

            const routes_map = [5]Radix{ radix1, radix2, radix3, radix4, radix5 };

            // An optional field, so existing Config types keep loom's own
            // default of 0.0.0.0 and only callers that ask for a specific
            // interface get one.
            const server_addr = if (@hasField(Config, "host")) config.host else "0.0.0.0";

            var loom: Loom(*Reverb) = undefined;
            try loom.new(.{
                .server_addr = server_addr,
                .server_port = config.port,
                .max = config.max,
                .max_body_size = config.max_body_size,
            }, arena, target);

            var logger: Logger = undefined;
            logger.init();
            // Buckets.init(arena);

            // var buckets_thread = try std.Thread.spawn(.{}, Buckets.loop, .{});
            // buckets_thread.detach();

            target.* = .{
                .arena = arena,
                .routes = routes_map,
                .logger = logger,
                .loom = loom,
                .config = config,
                .context_pool = Abstractions.ManagedMemoryPool(Context).init(arena),
                .context_slots = try arena.alloc(*Context, config.max),
                .request_buffers = try arena.alloc(RequestBuffer, config.max),
            };

            for (target.request_buffers) |*request_buffer| {
                request_buffer.* = .{};
            }

            for (0..target.context_slots.len) |i| {
                const ctx_op = try target.context_pool.create();
                ctx_op.* = try Context.init(
                    target.arena,
                    "",
                    "",
                    null,
                    null,
                    ContentType.None,
                    null,
                    20,
                );
                target.context_slots[i] = ctx_op;
            }
        }

        pub fn deinit(self: *Reverb) void {
            for (&self.routes) |*radix| {
                radix.deinit();
            }
            for (self.request_buffers) |*request_buffer| {
                request_buffer.reset(self.arena);
            }
            self.arena.free(self.request_buffers);
            self.loom.deinit();
            if (Metrics.end_points.GET) |ep_get| {
                for (ep_get) |elem| {
                    self.arena.free(elem);
                }
                self.arena.free(ep_get);
            }
            if (Metrics.end_points.POST) |ep_post| {
                for (ep_post) |elem| {
                    self.arena.free(elem);
                }
                self.arena.free(ep_post);
            }
            if (Metrics.end_points.PATCH) |ep_patch| {
                for (ep_patch) |elem| {
                    self.arena.free(elem);
                }
                self.arena.free(ep_patch);
            }
        }

        fn getOrCreateContextForClient(reverb: *Reverb, client: *Client) !*Context {
            const slot_index = client.slot;
            if (slot_index >= reverb.context_slots.len) return error.ContextSlotOutOfRange;
            return reverb.context_slots[slot_index];
        }

        pub fn process(reverb: *Reverb, new_client: *Client, new_recv_data: []const u8) !void {
            handle(reverb, new_client, new_recv_data) catch |err| {
                return err;
            };
        }

        pub fn useWss(reverb: *Reverb, wss_config: WSS.Config) !void {
            reverb.wss = try WSS.init(wss_config);
        }

        fn initTripwire(reverb: *Reverb) !void {
            reverb.tripwire.init(reverb.arena);
        }

        pub fn useTripwire(reverb: *Reverb) !void {
            reverb.tripwire.init(reverb.arena);
        }
        //
        fn initMetrics(reverb: *Reverb) !void {
            // try metrics.mapRoutes();
            try reverb.addRoute("/metrics/allroutes", .GET, getAllRoutes, &[_]MiddleFunc{});
            try reverb.addRoute("/metrics/healthcheck", .GET, healthCheck, &[_]MiddleFunc{});
            // try nimbus.addRoute("/metrics/allroutes", "GET", Metrics.allEndPoints, &[_]MiddleFunc{});
            // try nimbus.addRoute("/metrics/server-status", "GET", dashboard.serverStatus, &[_]MiddleFunc{});
            // try nimbus.addRoute("/dashboard/request-metrics", "GET", dashboard.requestMetrics, &[_]MiddleFunc{});
        }

        pub fn useCors(_: *Reverb, corsConfig: Cors) !void {
            cors = corsConfig;
            use_cors = true;
        }

        pub fn useStatic(reverb: *Reverb, dir: []const u8) !void {
            const path = try std.fmt.allocPrint(reverb.arena, "/{s}/:file", .{dir});
            defer reverb.arena.free(path);
            try reverb.addRoute(path, .GET, staticHandler, &[_]MiddleFunc{});
        }

        threadlocal var buf: [524288]u8 = undefined;
        var file_path: [512]u8 = undefined;

        // Add a simple in-memory cache for small files
        // const FileCache = struct {
        //     data: []const u8 = ,
        //     content_type: []const u8,
        // }{};

        fn staticHandler(static_ctx: *Context) !void {
            file_path[0] = '.';
            @memcpy(file_path[1 .. static_ctx.route.len + 1], static_ctx.route);
            const file = try std.fs.cwd().openFile(file_path[0 .. static_ctx.route.len + 1], .{});
            defer file.close();
            const bytes_read = try std.posix.pread(file.handle, &buf, 0);
            try static_ctx.FILE(buf[0..bytes_read]);
        }

        fn readCompleteHttpRequest(
            reverb: *Reverb,
            client: *Client,
            recv_data: []const u8,
            scratch: []u8,
            used_request_buffer: *bool,
        ) !?[]const u8 {
            if (client.slot >= reverb.request_buffers.len) return error.ContextSlotOutOfRange;

            const max_request_size = Reverb.MAX_RECV_SIZE + helpers.MAX_HEADER_SIZE;
            const request_buffer = &reverb.request_buffers[client.slot];

            if (request_buffer.len == 0) {
                if (!helpers.isSupportedHttpMethodPrefix(recv_data)) return error.MalformedRequest;

                if (try helpers.expectedHttpRequestLength(recv_data, Reverb.MAX_RECV_SIZE)) |request_len| {
                    if (request_len <= scratch.len) {
                        @memcpy(scratch[0..request_len], recv_data[0..request_len]);
                        return scratch[0..request_len];
                    }
                }
            }

            try request_buffer.append(reverb.arena, client, recv_data, max_request_size);
            used_request_buffer.* = true;

            const buffered = request_buffer.bytes();
            if (try helpers.expectedHttpRequestLength(buffered, Reverb.MAX_RECV_SIZE)) |request_len| {
                return buffered[0..request_len];
            }

            return null;
        }

        /// This function calls listen on the Reverb instance.
        ///
        /// # Returns:
        /// !void.
        pub fn listen(reverb: *Reverb) !void {
            if (use_cors) {
                var str_builder = StringBuilder.new();
                try cors.?.checkHeadersStr(&str_builder);
                Context.cors_headers = str_builder.contents[str_builder.start..str_builder.len];
            }

            try reverb.loom.listen();
        }

        pub fn handle(
            reverb: *Reverb,
            new_client: *Client,
            new_recv_data: []const u8,
        ) !void {
            var recv_buf: [Reverb.MAX_RECV_SIZE]u8 = undefined;
            const client = new_client;
            const recv_data = new_recv_data;
            var ctx_pm = Ctx_pm{};
            if (recv_data.len == 0) {
                // Browsers (or firefox?) attempt to optimize for speed
                // by opening a connection to the server once a user highlights
                // a link, but doesn't start sending the request until it's
                // clicked. The request eventually times out so we just
                // go agane.
                // try reverb.logger.warn("Got connection but no header!", .{}, @src());
                return;
            }

            const ctx = reverb.context_slots[client.slot];

            defer ctx.clear();

            ctx.client = client;

            if (client.client_type == .WebSocket) {
                if (recv_data.len > recv_buf.len) return error.MalformedRequest;
                @memcpy(recv_buf[0..recv_data.len], recv_data[0..]);
                ctx.client.?.msg = recv_buf[0..recv_data.len];

                var ws = client.ws orelse {
                    print("Parser not found\n", .{});
                    return;
                };

                // Feed the received data into the parser
                ws.parser.feed(recv_buf[0..recv_data.len]) catch |err| {
                    print("Parser feed error: {any}\n", .{err});
                    return;
                };

                // Now try to parse the message
                const message = ws.receiveMessage(true) catch |err| {
                    if (err == error.IncompleteFrame) {
                        // Need more data - this is normal, just wait for next recv
                        return;
                    }
                    print("Parser ReceiveMessage WebSocket: Error: {any}\n", .{err});
                    return;
                };

                var wss: WSS = reverb.wss orelse {
                    std.debug.print("No wss\n", .{});
                    return;
                };

                try wss.onMessage(ws, message, ctx);
                return;
            }

            var used_request_buffer = false;
            const request_data = (readCompleteHttpRequest(
                reverb,
                client,
                recv_data,
                recv_buf[0..],
                &used_request_buffer,
            ) catch |err| {
                if (client.slot < reverb.request_buffers.len) {
                    reverb.request_buffers[client.slot].reset(reverb.arena);
                }

                const resp = switch (err) {
                    error.BodyTooLarge, error.RequestTooLarge => "HTTP/1.1 413 Request Entity Too Large\r\n" ++
                        "Content-Type: text/html\r\n" ++
                        "Content-Length: 0\r\n\r\n",
                    error.HeaderTooLarge => "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                        "Content-Type: text/html\r\n" ++
                        "Content-Length: 0\r\n\r\n",
                    else => "HTTP/1.1 404 MALFORMED REQUEST\r\n" ++
                        "Content-Type: text/html\r\n" ++
                        "Content-Length: 0\r\n\r\n",
                };

                ctx.RAW(resp) catch |write_err| {
                    return write_err;
                };
                return err;
            }) orelse return;
            defer if (used_request_buffer) {
                reverb.request_buffers[client.slot].reset(reverb.arena);
            };

            ctx.client.?.msg = request_data;

            // switching to a http_header inside ctx reduces by 10k req/s
            helpers.parseHeaders(request_data, &ctx_pm, &ctx.http_header) catch |err| {
                print("Malformed Request: {any} {any}\n", .{ err, error.ParsingHeaders });
                print("recv_buf[0..recv_data.len] {s}\n", .{request_data});
                const resp = "HTTP/1.1 404 MALFORMED REQUEST\r\n" ++
                    "Content-Type: text/html\r\n" ++
                    "Content-Length: 0\r\n\r\n";
                ctx.RAW(resp) catch |write_err| {
                    print("Client Write Error: {any}\n", .{write_err});
                };
                return error.MalformedRequest;
            };

            // we need to consider this;
            ctx.method = ctx_pm.method;
            ctx.route = ctx_pm.path;
            ctx.http_header.path = ctx_pm.path;
            ctx.http_header.method = ctx_pm.method;
            const http_header = ctx.http_header;

            if (http_header.content_length > reverb.loom.config.max_body_size) {
                reverb.logger.err("Request body too large", .{}, null) catch |log_err| {
                    std.log.err("-----{any}", .{log_err});
                };
                const resp = "HTTP/1.1 413 Request body too large\r\n" ++
                    "Content-Type: text/html\r\n" ++
                    "Content-Length: 0\r\n";
                ctx.RAW(resp) catch |write_err| {
                    print("Client Write Error: {any}\n", .{write_err});
                };
                return;
            }

            if (http_header.content_length > 0) {
                ctx.content_length = http_header.content_length;
                if (http_header.body.len < http_header.content_length) return error.MalformedRequest;
                ctx.payload = http_header.body[0..http_header.content_length];
                ctx.http_payload = ctx.payload;
            }

            if (request_data[0] == 'O') {
                try ctx.OPTIONS();
                return;
            }

            if (helpers.findIndex(http_header.connection, 'U') != null) {
                const result = try WebSocket.handleUpgrade(http_header.ws_client_key, null);

                var response_buf: [512]u8 = undefined;
                const response = try WebSocket.buildUpgradeResponse(result, &response_buf);
                try client.write(response);

                const ws: *WebSocket = reverb.arena.create(WebSocket) catch unreachable;
                ws.* = WebSocket.init(
                    client,
                    reverb.arena,
                    reverb.loom.config.max_body_size,
                    .{},
                    // result.deflate_config, // <-- Pass the negotiated config here!
                ) catch |err| {
                    print("Error: {any}\n", .{err});
                    return;
                };

                client.state = .Idle;
                client.client_type = .WebSocket;
                client.ws = ws;

                var wss: WSS = reverb.wss orelse {
                    std.debug.print("No wss\n", .{});
                    return;
                };

                try wss.onConnection(client.ws.?, ctx);
                return;
            }

            if (http_header.cookie_str.len > 0) {
                helpers.parseCookies(ctx, http_header.cookie_str) catch {
                    // reverb.logger.err("Cookie parsing {any}\n", .{ err }) catch |log_err| {
                    //     std.log.err("Cookie {any}", .{log_err});
                    // };
                };
            }

            const lookup_route_op = blk: {
                break :blk helpers.parseParams(ctx, ctx_pm.path) catch |err| {
                    reverb.logger.err("Params parsing error: {any}", .{err}, null) catch |log_err| {
                        std.log.err("Lookup {any}", .{log_err});
                    };
                    break :blk null; // or some default ParamDetails value
                };
            };
            if (lookup_route_op) |lookup_route| {
                ctx_pm.path = lookup_route;
            }

            ctx.http_header = http_header;

            reverb.callRoute(ctx_pm, ctx) catch |err| {
                reverb.logger.err("{any} Method: {s} Path: {s}", .{ err, ctx_pm.method, ctx_pm.path }, null) catch |log_err| {
                    std.log.err("Logger Error: {any}", .{log_err});
                };
                ctx.ERROR(404, "") catch |write_err| {
                    return write_err;
                };
                return error.BrokenPipe;
            };
        }
    };
}
