//! Formats the instruction sources and available skill directories for startup.
const std = @import("std");
const skill_contract = @import("../core/skills/skill_contract.zig");
const text_utils = @import("../core/shared/text_utils.zig");

/// Borrows the selected instruction sources, discovered skill catalog, and row style.
/// Skill entries describe available metadata, not eagerly loaded skill bodies.
pub const Snapshot = struct {
    context_sources: []const []const u8 = &.{},
    skills: []const skill_contract.Skill = &.{},
    context_enabled: bool = true,
    line_style: []const u8 = "",
};

/// Writes the two startup sections from borrowed facts to `writer`.
/// Paths retain their order and escape control bytes to prevent terminal injection.
/// Each nonempty row establishes `line_style` because transcript painting resets
/// terminal attributes between rows. The caller resets attributes after the block.
pub fn write(writer: *std.Io.Writer, snapshot: Snapshot) std.Io.Writer.Error!void {
    try writer.writeAll(snapshot.line_style);
    try writer.writeAll("[Context]\n");
    if (!snapshot.context_enabled) {
        try writer.writeAll(snapshot.line_style);
        try writer.writeAll("  (disabled)\n");
    } else if (snapshot.context_sources.len == 0) {
        try writer.writeAll(snapshot.line_style);
        try writer.writeAll("  (none)\n");
    } else {
        for (snapshot.context_sources) |source| try writePath(writer, source, snapshot.line_style);
    }
    try writer.writeByte('\n');
    try writer.writeAll(snapshot.line_style);
    try writer.writeAll("[Skills]\n");
    if (snapshot.skills.len == 0) {
        try writer.writeAll(snapshot.line_style);
        try writer.writeAll("  (none)\n");
    } else {
        for (snapshot.skills) |skill| try writePath(writer, skill.path, snapshot.line_style);
    }
    try writer.writeByte('\n');
}

/// Writes `path` as one indented row with `line_style`, escaping terminal control bytes.
fn writePath(writer: *std.Io.Writer, path: []const u8, line_style: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(line_style);
    try writer.writeAll("  ");
    var encoder: text_utils.IncrementalTerminalSafeEncoder = .{};
    try encoder.append(writer, path);
    try encoder.finish(writer);
    try writer.writeByte('\n');
}

test "startup inventory lists selected context sources and available skill directories" {
    const skills = [_]skill_contract.Skill{
        .{ .name = "review", .description = "Review code", .path = "/workspace/.fx/skills/review", .source = .workspace_fx },
        .{ .name = "test", .description = "Run tests", .path = "/home/.agents/skills/test", .source = .global_agents },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(&output.writer, .{
        .context_sources = &.{ "/home/.fx/AGENTS.md", "/workspace/AGENTS.md" },
        .skills = &skills,
    });
    try std.testing.expectEqualStrings(
        "[Context]\n  /home/.fx/AGENTS.md\n  /workspace/AGENTS.md\n\n" ++
            "[Skills]\n  /workspace/.fx/skills/review\n  /home/.agents/skills/test\n\n",
        output.written(),
    );
}

test "startup inventory distinguishes empty and disabled context" {
    const cases = [_]struct { snapshot: Snapshot, expected: []const u8 }{
        .{ .snapshot = .{}, .expected = "[Context]\n  (none)\n\n[Skills]\n  (none)\n\n" },
        .{ .snapshot = .{ .context_enabled = false, .context_sources = &.{"/workspace/AGENTS.md"} }, .expected = "[Context]\n  (disabled)\n\n[Skills]\n  (none)\n\n" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try write(&output.writer, case.snapshot);
        try std.testing.expectEqualStrings(case.expected, output.written());
    }
}

test "startup inventory escapes hostile path bytes while preserving Unicode" {
    const skills = [_]skill_contract.Skill{
        .{ .name = "review", .description = "", .path = "/skills/review\x1b[2J\xff", .source = .workspace_fx },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(&output.writer, .{
        .context_sources = &.{"/workspace/日本語\n\tAGENTS.md"},
        .skills = &skills,
    });
    try std.testing.expectEqualStrings(
        "[Context]\n  /workspace/日本語\\x0a\\x09AGENTS.md\n\n" ++
            "[Skills]\n  /skills/review\\x1b[2J\\xff\n\n",
        output.written(),
    );
}
