const std = @import("std");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const session_summary_codec = @import("session_summary_codec.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const Scope = enum {
    current_workspace,
    all_workspaces,
};

pub const LoadState = enum {
    loading,
    ready,
    failed,
};

pub const ResumeFailure = enum {
    open_elsewhere,
    being_updated,
    unavailable,
};

pub fn filteredCount(summaries: []const session_store.SessionSummary, query: []const u8) usize {
    var count: usize = 0;
    for (summaries) |summary| {
        if (matchesQuery(summary, query)) count += 1;
    }
    return count;
}

pub fn summaryAt(
    summaries: []const session_store.SessionSummary,
    query: []const u8,
    display_index: usize,
) ?*const session_store.SessionSummary {
    var current: usize = 0;
    for (summaries) |*summary| {
        if (!matchesQuery(summary.*, query)) continue;
        if (current == display_index) return summary;
        current += 1;
    }
    return null;
}

/// Whether the resume picker lists `summary` for `query` in `workspace_root`,
/// or in every workspace when it is null.
pub fn pickerLists(
    summary: session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
) bool {
    if (workspace_root) |root| {
        const summary_workspace = summary.workspace_root orelse return false;
        if (!std.mem.eql(u8, summary_workspace, root)) return false;
    }
    return summary.hasResumableContent() and matchesQuery(summary, query);
}

/// One resume picker page from newest-first `summaries`: up to `limit` that
/// the picker lists for `query` in `workspace_root`, after `continuation`.
/// `has_more` is set only when another listed summary follows, so loading
/// more always has a match to show. Caller owns the returned page.
pub fn resumablePage(
    alloc: Allocator,
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: session_store.ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (!pickerLists(summary, workspace_root, query)) continue;
        if (continuation) |position| {
            if (!session_summary_codec.summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn displayTitle(summary: session_store.SessionSummary) []const u8 {
    return summary.title orelse session_display_metadata.fallback_title;
}

pub fn workspacePath(summary: session_store.SessionSummary) []const u8 {
    return summary.workspace_root orelse summary.origin_workspace_root orelse "(unknown workspace)";
}

pub fn relativeActivityAge(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "just now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m ago", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h ago", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d ago", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

// Same buckets as relativeActivityAge without the " ago" suffix, for tight
// single-line layouts: "now", "5m", "2h", "1d".
pub fn relativeActivityAgeCompact(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

fn matchesQuery(summary: session_store.SessionSummary, query: []const u8) bool {
    const query_text = std.mem.trim(u8, query, " \t\r\n");
    if (query_text.len == 0) return true;
    if (text_utils.containsIgnoreCase(displayTitle(summary), query_text)) return true;
    if (text_utils.containsIgnoreCase(workspacePath(summary), query_text)) return true;
    if (summary.preview) |preview| {
        if (text_utils.containsIgnoreCase(preview, query_text)) return true;
    }
    return false;
}

test "session catalog filters titles previews and workspace paths" {
    const summaries = [_]session_store.SessionSummary{
        .{
            .id = @constCast("one"),
            .workspace_root = @constCast("/worktrees/alpha"),
            .title = @constCast("Fix renderer"),
            .preview = @constCast("inspect footer state"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = .literal("en"),
            .history_len = 4,
        },
        .{
            .id = @constCast("two"),
            .workspace_root = @constCast("/worktrees/beta"),
            .title = @constCast("Review sessions"),
            .created_at_ms = 1,
            .updated_at_ms = 3,
            .conversation_language = .literal("en"),
            .history_len = 2,
        },
    };

    try std.testing.expectEqual(@as(usize, 2), filteredCount(&summaries, ""));
    try std.testing.expectEqual(@as(usize, 1), filteredCount(&summaries, "RENDER"));
    try std.testing.expectEqualStrings("two", summaryAt(&summaries, "beta", 0).?.id);
    try std.testing.expectEqualStrings("one", summaryAt(&summaries, "footer", 0).?.id);
    try std.testing.expect(summaryAt(&summaries, "missing", 0) == null);
}

test "session catalog pages checkpoint-only sessions without changing turn counts" {
    const alloc = std.testing.allocator;
    const checkpoint = session_store.SessionSummary{
        .id = @constCast("checkpoint"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 0,
        .has_checkpoint = true,
    };
    var empty = checkpoint;
    empty.id = @constCast("empty");
    empty.has_checkpoint = false;
    var page = try resumablePage(alloc, &.{ checkpoint, empty }, null, "", null, 10);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("checkpoint", page.summaries.items[0].id);
    try std.testing.expect(page.summaries.items[0].has_checkpoint);
    try std.testing.expectEqual(@as(usize, 0), page.summaries.items[0].history_len);
}

test "session catalog pages filter the workspace and preserve append cursor order" {
    var summaries = [_]session_store.SessionSummary{
        .{ .id = @constCast("new"), .workspace_root = @constCast("/workspace"), .created_at_ms = 1, .updated_at_ms = 4, .conversation_language = .literal("en"), .history_len = 1 },
        .{ .id = @constCast("foreign"), .workspace_root = @constCast("/foreign"), .created_at_ms = 1, .updated_at_ms = 3, .conversation_language = .literal("en"), .history_len = 1 },
        .{ .id = @constCast("old"), .workspace_root = @constCast("/workspace"), .created_at_ms = 1, .updated_at_ms = 1, .conversation_language = .literal("en"), .history_len = 1 },
    };
    session_summary_codec.sortSummariesNewestFirst(&summaries);
    var page = try resumablePage(std.testing.allocator, &summaries, "/workspace", "", null, 1);
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("new", page.summaries.items[0].id);
    try std.testing.expect(page.has_more);

    var next = try resumablePage(std.testing.allocator, &summaries, "/workspace", "", .{
        .updated_at_ms = page.summaries.items[0].updated_at_ms,
        .id = page.summaries.items[0].id,
    }, 1);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), next.summaries.items.len);
    try std.testing.expectEqualStrings("old", next.summaries.items[0].id);
    try std.testing.expect(!next.has_more);
}

test "session catalog activity age uses the last update" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", relativeActivityAge(&buf, 1_000, 1_000));
    try std.testing.expectEqualStrings("3m ago", relativeActivityAge(&buf, 1_000, 1_000 + 3 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("2h ago", relativeActivityAge(&buf, 1_000, 1_000 + 2 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("3d ago", relativeActivityAge(&buf, 1_000, 1_000 + 3 * std.time.ms_per_day));
}

test "session catalog compact activity age drops the ago suffix" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("now", relativeActivityAgeCompact(&buf, 1_000, 1_000));
    try std.testing.expectEqualStrings("3m", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 3 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("2h", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 2 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("3d", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 3 * std.time.ms_per_day));
}
