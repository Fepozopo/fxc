//! How images reach the model on one request.
//!
//! `step` is the whole decision: given the turn's state and one event, it
//! returns the next state and the effects to run. It performs no I/O and reads
//! no clock, environment, or global. The orchestrator is its shell: it runs
//! each effect and feeds the result back as an event.
//!
//! `tests/tla/image_route/spec/ImageRoute.tla` models `step` action for
//! action, and `abstract` maps a state onto that model's variables. The laws
//! below are the model's properties; `tests/tla/image_route/design/DESIGN.md`
//! lists where each one is enforced.
//!
//! This file imports only `std`, so the JSON-lines harness in
//! `tests/tla/drivers/image_route/` can build it on its own.
const std = @import("std");

/// Whether the selected model takes images inline.
pub const Support = enum {
    /// The catalog was unavailable or did not list the model.
    unknown,
    /// The catalog lists the model without vision.
    non_native,
    /// The catalog lists the model with vision.
    native,
};

/// What the model catalog said about one model.
pub const CatalogView = union(enum) {
    /// The catalog could not be read: unreachable, refused, or malformed.
    down,
    /// The catalog was read and does not list the model.
    missing,
    listed: Tags,

    pub const Tags = struct {
        vision: bool,
        file_input: bool,
    };
};

/// Images reach the model inline exactly when the catalog lists `vision`.
///
/// fx sends every image, user or tool, in an AI SDK `file` part with an
/// `image/*` media type, which is the AI Gateway's vision input. The
/// catalog's `file-input` tag covers documents such as PDFs and says nothing
/// about images, so it plays no part here.
pub fn supportFromCatalog(view: CatalogView) Support {
    return switch (view) {
        .down, .missing => .unknown,
        .listed => |tags| if (tags.vision) .native else .non_native,
    };
}

/// Where the turn's user images go.
pub const Route = enum {
    /// Inline, as file parts.
    native,
    /// Through the vision tool, as text.
    fallback,
    /// Nowhere: a request with user images fails.
    unavailable,
};

/// How the request offers the vision tool.
pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

/// What happens to the tool images in the request's history.
pub const ToolImages = enum {
    /// The history has none.
    none,
    /// They go inline.
    attached,
    /// Withheld; the model is told to call the vision tool.
    withheld_fallback,
    /// Withheld; the model is told no image path exists.
    withheld_dead_end,
    /// Withheld; the model is told support could not be confirmed.
    withheld_unknown,
};

pub const FailReason = enum {
    /// User images, and the catalog could not confirm image input.
    capability_unknown,
    /// User images, a model without vision, and no vision tool.
    no_native_image,
};

/// What the shell knows about the request it is about to send. Only flags:
/// image bytes never enter the core.
pub const Request = struct {
    /// The turn carries user images, attached now or authorized earlier.
    user_images: bool,
    /// Some of those images still wait for the model's first look.
    pending_images: bool,
    /// The request history holds tool images the session still has.
    tool_images: bool,
    /// The vision tool is configured and registered.
    fallback: bool,
    /// The catalog is known to be unreachable right now.
    catalog_down: bool,
};

pub const State = struct {
    /// The turn's one capability snapshot. Every decision reads it.
    support: Support = .unknown,
    /// This turn already asked for capabilities.
    resolved: bool = false,
    /// This turn already told the user the catalog is down.
    notified: bool = false,
    /// The request waiting for the capability reply.
    pending: ?Request = null,
};

pub const Event = union(enum) {
    /// A turn starts with the capabilities the shell holds. It also ends
    /// whatever the previous turn left: a reply still owed is dropped.
    turn_started: Support,
    /// The shell has built a request's history and is about to send it.
    request_ready: Request,
    /// The reply to `resolve_capabilities`.
    capabilities_resolved: Support,
};

/// One request's image handling, all read from one support value.
pub const Decision = struct {
    route: Route,
    mode: VisionMode,
    tool_images: ToolImages,
};

pub const Effect = union(enum) {
    /// Ask the catalog again, then send `capabilities_resolved`.
    resolve_capabilities,
    /// Tell the user once that tool images wait on the catalog.
    notify_catalog_down,
    /// Send the request as decided.
    send: Decision,
    /// Fail the turn without sending.
    fail: FailReason,
};

pub const max_effects = 2;

pub const Output = struct {
    state: State,
    buffer: [max_effects]Effect = undefined,
    len: usize = 0,

    pub fn effects(self: *const Output) []const Effect {
        return self.buffer[0..self.len];
    }
};

pub fn step(state: State, event: Event) Output {
    return switch (event) {
        .turn_started => |support| .{ .state = .{ .support = support } },
        .request_ready => |request| onRequest(state, request),
        .capabilities_resolved => |support| onResolved(state, support),
    };
}

fn onRequest(state: State, request: Request) Output {
    if (state.pending != null) {
        // Delivered while a reply is owed: the reply answers the newest
        // request, and nothing runs twice.
        var next = state;
        next.pending = request;
        return .{ .state = next };
    }
    if (state.support == .unknown and !state.resolved and (request.user_images or request.tool_images)) {
        var next = state;
        next.resolved = true;
        next.pending = request;
        return withEffects(next, &.{.resolve_capabilities});
    }
    return decide(state, request);
}

fn onResolved(state: State, support: Support) Output {
    // A reply nothing waits for, stale or duplicated, changes nothing.
    const request = state.pending orelse return .{ .state = state };
    var next = state;
    next.support = support;
    next.pending = null;
    return decide(next, request);
}

fn decide(state: State, request: Request) Output {
    const chosen = decision(state.support, request);
    if (request.user_images and chosen.route == .unavailable) {
        const reason: FailReason = if (state.support == .unknown) .capability_unknown else .no_native_image;
        return withEffects(state, &.{.{ .fail = reason }});
    }
    if (chosen.tool_images == .withheld_unknown and request.catalog_down and !state.notified) {
        var next = state;
        next.notified = true;
        return withEffects(next, &.{ .notify_catalog_down, .{ .send = chosen } });
    }
    return withEffects(state, &.{.{ .send = chosen }});
}

/// The image handling `support` implies for `request`.
pub fn decision(support: Support, request: Request) Decision {
    const route: Route = switch (support) {
        .native => .native,
        .unknown => .unavailable,
        .non_native => if (request.fallback) .fallback else .unavailable,
    };
    const mode: VisionMode = if (route != .fallback)
        .unavailable
    else if (request.pending_images)
        .required
    else
        .optional;
    const tool_images: ToolImages = if (!request.tool_images) .none else switch (support) {
        .native => .attached,
        .unknown => .withheld_unknown,
        .non_native => if (route == .fallback) .withheld_fallback else .withheld_dead_end,
    };
    return .{ .route = route, .mode = mode, .tool_images = tool_images };
}

fn withEffects(state: State, list: []const Effect) Output {
    var out: Output = .{ .state = state, .len = list.len };
    @memcpy(out.buffer[0..list.len], list);
    return out;
}

/// The spec's view of a state: `support`, `resolved`, `notified`, and
/// `pending` as a sequence of at most one request.
pub const Abstract = struct {
    support: Support,
    resolved: bool,
    notified: bool,
    pending: []const Request,
};

/// Maps `state` onto the variables of `ImageRoute.tla`. The result borrows
/// `state`.
pub fn abstract(state: *const State) Abstract {
    return .{
        .support = state.support,
        .resolved = state.resolved,
        .notified = state.notified,
        .pending = if (state.pending) |*request| request[0..1] else &.{},
    };
}

fn eachRequest(comptime body: anytype) !void {
    for (0..32) |bits| {
        const request: Request = .{
            .user_images = bits & 1 != 0,
            .pending_images = bits & 2 != 0,
            .tool_images = bits & 4 != 0,
            .fallback = bits & 8 != 0,
            .catalog_down = bits & 16 != 0,
        };
        if (request.pending_images and !request.user_images) continue;
        try body(request);
    }
}

const all_support = [_]Support{ .unknown, .non_native, .native };

test "a catalog that lists vision makes image input native with or without file input" {
    for ([_]bool{ false, true }) |file_input| {
        try std.testing.expectEqual(Support.native, supportFromCatalog(.{ .listed = .{ .vision = true, .file_input = file_input } }));
        try std.testing.expectEqual(Support.non_native, supportFromCatalog(.{ .listed = .{ .vision = false, .file_input = file_input } }));
    }
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.down));
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.missing));
}

test "every decision reads one support value" {
    try eachRequest(struct {
        fn check(request: Request) !void {
            for (all_support) |support| {
                const chosen = decision(support, request);
                try std.testing.expectEqual(chosen.route == .native, support == .native);
                try std.testing.expectEqual(chosen.route == .fallback, chosen.mode != .unavailable);
                try std.testing.expectEqual(chosen.tool_images == .none, !request.tool_images);
                if (chosen.tool_images == .attached) try std.testing.expectEqual(Support.native, support);
                if (chosen.tool_images == .withheld_unknown) try std.testing.expectEqual(Support.unknown, support);
                if (chosen.tool_images == .withheld_fallback) try std.testing.expectEqual(Route.fallback, chosen.route);
                if (chosen.tool_images == .withheld_dead_end) try std.testing.expect(support == .non_native and chosen.route == .unavailable);
                if (chosen.route == .fallback) try std.testing.expectEqual(request.pending_images, chosen.mode == .required);
            }
        }
    }.check);
}

test "a turn asks for capabilities at most once and answers the request it held" {
    try eachRequest(struct {
        fn check(request: Request) !void {
            const started = step(.{}, .{ .turn_started = .unknown });
            const first = step(started.state, .{ .request_ready = request });
            if (!request.user_images and !request.tool_images) {
                try std.testing.expectEqual(@as(usize, 1), first.len);
                try std.testing.expect(first.effects()[0] == .send);
                return;
            }
            try std.testing.expectEqual(@as(usize, 1), first.len);
            try std.testing.expect(first.effects()[0] == .resolve_capabilities);
            // A duplicate delivery while the reply is owed runs nothing.
            const duplicate = step(first.state, .{ .request_ready = request });
            try std.testing.expectEqual(@as(usize, 0), duplicate.len);
            const answered = step(duplicate.state, .{ .capabilities_resolved = .unknown });
            try std.testing.expect(answered.state.pending == null);
            for (answered.effects()) |effect| try std.testing.expect(effect != .resolve_capabilities);
            // A stale reply changes nothing.
            const stale = step(answered.state, .{ .capabilities_resolved = .native });
            try std.testing.expectEqual(@as(usize, 0), stale.len);
            try std.testing.expectEqualDeep(answered.state, stale.state);
            // The next request in the turn does not ask again.
            const again = step(stale.state, .{ .request_ready = request });
            for (again.effects()) |effect| try std.testing.expect(effect != .resolve_capabilities);
        }
    }.check);
}

test "the catalog-down notice reaches the user once per turn" {
    const request: Request = .{ .user_images = false, .pending_images = false, .tool_images = true, .fallback = true, .catalog_down = true };
    var state = step(.{}, .{ .turn_started = .unknown }).state;
    var notices: usize = 0;
    for (0..3) |_| {
        var out = step(state, .{ .request_ready = request });
        if (out.len == 1 and out.effects()[0] == .resolve_capabilities) out = step(out.state, .{ .capabilities_resolved = .unknown });
        for (out.effects()) |effect| {
            if (effect == .notify_catalog_down) notices += 1;
        }
        state = out.state;
    }
    try std.testing.expectEqual(@as(usize, 1), notices);
    const next_turn = step(state, .{ .turn_started = .unknown });
    try std.testing.expect(!next_turn.state.notified and !next_turn.state.resolved);
}

test "user images without a route fail the request and never send" {
    for (all_support) |support| {
        const request: Request = .{ .user_images = true, .pending_images = true, .tool_images = true, .fallback = false, .catalog_down = false };
        const out = step(.{ .support = support, .resolved = true }, .{ .request_ready = request });
        try std.testing.expectEqual(@as(usize, 1), out.len);
        switch (support) {
            .native => try std.testing.expect(out.effects()[0] == .send),
            .unknown => try std.testing.expectEqual(Effect{ .fail = .capability_unknown }, out.effects()[0]),
            .non_native => try std.testing.expectEqual(Effect{ .fail = .no_native_image }, out.effects()[0]),
        }
    }
}

test "abstract maps the pending request onto a sequence of at most one" {
    const request: Request = .{ .user_images = true, .pending_images = false, .tool_images = false, .fallback = true, .catalog_down = false };
    const idle: State = .{};
    try std.testing.expectEqual(@as(usize, 0), abstract(&idle).pending.len);
    const waiting: State = .{ .resolved = true, .pending = request };
    const view = abstract(&waiting);
    try std.testing.expectEqual(@as(usize, 1), view.pending.len);
    try std.testing.expectEqualDeep(request, view.pending[0]);
}

test "requests carry flags, not image bytes" {
    inline for (@typeInfo(Request).@"struct".field_types) |field_type| {
        try std.testing.expect(field_type == bool);
    }
}
