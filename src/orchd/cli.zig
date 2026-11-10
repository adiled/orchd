const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Global = struct {
    orchfile: ?[]const u8 = null,
    overlay: []const []const u8 = &.{},
    rootstock: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    grove: ?[]const u8 = null,
    user: bool = false,
    system: bool = false,
    arg: []const []const u8 = &.{},
    verbose: bool = false,
    quiet: bool = false,
};

pub const Grow = struct {
    services: []const []const u8 = &.{},
    no_start: bool = false,
    strict: bool = false,
    force: bool = false,
    reload: bool = false,
};

pub const Survey = struct {
    json: bool = false,
};

pub const Fell = struct {
    services: []const []const u8 = &.{},
    keep_data: bool = false,
};

pub const Logs = struct {
    service: []const u8 = "",
    follow: bool = true,
    lines: u32 = 100,
};

pub const Row = struct {};

pub const Tend = struct {
    service: ?[]const u8 = null,
    spec: ?[]const u8 = null,
    no_start: bool = false,
};

pub const Command = union(enum) {
    grow: Grow,
    survey: Survey,
    fell: Fell,
    logs: Logs,
    sow: Row,
    plant: Row,
    tend: Tend,
};

pub const Cli = struct {
    global: Global,
    command: Command,
};

pub const Parsed = union(enum) {
    run: Cli,
    help: []const u8,
    version,
};

const Flag = struct {
    field: []const u8,
    short: ?u8 = null,
    value: ?[]const u8 = null,
    help: []const u8,
};

const Positional = enum { none, services, service, optional_service };

const Spec = struct {
    name: []const u8,
    about: []const u8,
    positional: Positional = .none,
    positional_help: []const u8 = "",
    flags: []const Flag = &.{},
};

const global_flags = [_]Flag{
    .{ .field = "orchfile", .value = "ORCHFILE", .help = "Path to Orchfile (default: ./Orchfile)" },
    .{ .field = "overlay", .value = "OVERLAY", .help = "Overlay file (repeatable)" },
    .{ .field = "rootstock", .value = "ROOTSTOCK", .help = "Rootstock: what runs each tree. bare, apple, or any orchd-rootstock-<name> beside orchd or on PATH" },
    .{ .field = "platform", .value = "PLATFORM", .help = "Platform: systemd, launchd, orchdi" },
    .{ .field = "state_dir", .value = "STATE_DIR", .help = "State directory (default: ~/.orch)" },
    .{ .field = "project_dir", .value = "PROJECT_DIR", .help = "Project root directory" },
    .{ .field = "data_dir", .value = "DATA_DIR", .help = "Data directory for service storage" },
    .{ .field = "grove", .value = "GROVE", .help = "Grove to plant into: the prefix on every name it generates" },
    .{ .field = "user", .help = "Use user scope (~/.config/systemd/user, ~/Library/LaunchAgents)" },
    .{ .field = "system", .help = "Use system scope (/etc/systemd/system, /Library/LaunchDaemons; root)" },
    .{ .field = "arg", .value = "ARG", .help = "Pass-through arg to orch parse (repeatable, format: key=value)" },
    .{ .field = "verbose", .short = 'v', .help = "Verbose output" },
    .{ .field = "quiet", .short = 'q', .help = "Suppress non-error output" },
};

const commands = [_]Spec{
    .{
        .name = "grow",
        .about = "Bring the grove up: sow, plant, and tend in one step.",
        .positional = .services,
        .positional_help = "Specific services to start (default: all enabled)",
        .flags = &.{
            .{ .field = "no_start", .help = "Write and install but do not start" },
            .{ .field = "strict", .help = "Fail if any service cannot be materialized, instead of warning" },
            .{ .field = "force", .help = "Regenerate even when the Orchfile has not changed" },
            .{ .field = "reload", .help = "Run each living tree's RELOAD instead of restarting it" },
        },
    },
    .{
        .name = "survey",
        .about = "Report the grove: each tree's state.",
        .flags = &.{.{ .field = "json", .help = "Output as JSON instead of a table" }},
    },
    .{
        .name = "fell",
        .about = "Fell trees: cut them down and clear their beds. With no service, the whole grove.",
        .positional = .services,
        .positional_help = "Services to fell (default: the whole grove)",
        .flags = &.{.{ .field = "keep_data", .help = "Keep service data directories" }},
    },
    .{
        .name = "logs",
        .about = "Tail a tree's logs.",
        .positional = .service,
        .positional_help = "Service name",
        .flags = &.{
            .{ .field = "follow", .value = "FOLLOW", .help = "Follow log output [default: true]" },
            .{ .field = "lines", .short = 'n', .value = "LINES", .help = "Number of lines to show initially [default: 100]" },
        },
    },
    .{ .name = "sow", .about = "Row: spec (stdin) -> cuttings (stdout). Pair each service with its ExecSet." },
    .{ .name = "plant", .about = "Row: cuttings (stdin) -> beds (stdout). Render each service's native files." },
    .{
        .name = "tend",
        .about = "Row: beds (stdin) -> running. Write, install, and start. With a service, keep that one tree for its lifetime instead.",
        .positional = .optional_service,
        .positional_help = "Service to keep for its lifetime (the tree keeper)",
        .flags = &.{
            .{ .field = "spec", .value = "SPEC", .help = "Keep a tree from an explicit spec file. Used by launchd and orchdi, which know the path because plant baked it" },
            .{ .field = "no_start", .help = "Write and install but do not start" },
        },
    },
};

pub const ParseError = error{ InvalidArguments, OutOfMemory };

pub fn parse(arena: Allocator, argv: []const []const u8, version: []const u8, problem: *[]const u8) ParseError!Parsed {
    var global: Global = .{};
    var command: ?Command = null;
    var spec: ?Spec = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    var appended: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const word = argv[i];
        if (std.mem.eql(u8, word, "-h") or std.mem.eql(u8, word, "--help")) {
            return .{ .help = try helpFor(arena, spec, version) };
        }
        if (std.mem.eql(u8, word, "-V") or std.mem.eql(u8, word, "--version")) return .version;
        if (std.mem.eql(u8, word, "--") or word.len < 2 or word[0] != '-') {
            if (command == null) {
                if (std.mem.eql(u8, word, "help")) return .{ .help = try helpFor(arena, null, version) };
                inline for (commands, 0..) |c, n| {
                    if (std.mem.eql(u8, word, c.name)) {
                        command = @unionInit(Command, c.name, .{});
                        spec = commands[n];
                    }
                }
                if (command == null) return fail(arena, problem, "unrecognized subcommand '{s}'", .{word});
            } else {
                try positionals.append(arena, word);
            }
            continue;
        }

        const long, const inline_value = splitFlag(word);
        var matched = false;
        inline for (global_flags) |flag| {
            if (!matched and named(flag, long)) {
                matched = true;
                i = try apply(Global, flag, &global, arena, argv, i, inline_value, &appended, problem);
            }
        }
        if (command) |*cmd| switch (cmd.*) {
            inline else => |*options, tag| {
                const flags = comptime commandSpec(@tagName(tag)).flags;
                inline for (flags) |flag| {
                    if (!matched and named(flag, long)) {
                        matched = true;
                        i = try apply(@TypeOf(options.*), flag, options, arena, argv, i, inline_value, &appended, problem);
                    }
                }
            },
        };
        if (!matched) return fail(arena, problem, "unexpected argument '{s}'", .{word});
    }

    if (appended.get("overlay")) |list| global.overlay = list.items;
    if (appended.get("arg")) |list| global.arg = list.items;
    if (global.user and global.system) return fail(arena, problem, "--user cannot be used with --system", .{});

    var cmd = command orelse return .{ .help = try helpFor(arena, null, version) };
    switch (cmd) {
        .grow => |*g| {
            g.services = positionals.items;
            if (g.reload and g.no_start) return fail(arena, problem, "--reload cannot be used with --no-start", .{});
        },
        .fell => |*f| f.services = positionals.items,
        .logs => |*l| {
            if (positionals.items.len != 1) return fail(arena, problem, "logs takes one service", .{});
            l.service = positionals.items[0];
        },
        .tend => |*t| {
            if (positionals.items.len > 1) return fail(arena, problem, "tend takes at most one service", .{});
            if (positionals.items.len == 1) t.service = positionals.items[0];
            if (t.service != null and t.spec != null) return fail(arena, problem, "--spec cannot be used with a service", .{});
        },
        .survey, .sow, .plant => if (positionals.items.len > 0)
            return fail(arena, problem, "unexpected argument '{s}'", .{positionals.items[0]}),
    }
    return .{ .run = .{ .global = global, .command = cmd } };
}

fn commandSpec(comptime name: []const u8) Spec {
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    unreachable;
}

fn splitFlag(word: []const u8) struct { []const u8, ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, word, '=')) |eq| return .{ word[0..eq], word[eq + 1 ..] };
    return .{ word, null };
}

fn named(comptime flag: Flag, word: []const u8) bool {
    if (flag.short) |s| {
        if (word.len == 2 and word[0] == '-' and word[1] == s) return true;
    }
    if (word.len < 3 or !std.mem.startsWith(u8, word, "--")) return false;
    const name = word[2..];
    if (name.len != flag.field.len) return false;
    for (name, flag.field) |a, b| {
        if (a != b and !(a == '-' and b == '_')) return false;
    }
    return true;
}

fn apply(
    comptime T: type,
    comptime flag: Flag,
    target: *T,
    arena: Allocator,
    argv: []const []const u8,
    at: usize,
    inline_value: ?[]const u8,
    appended: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    problem: *[]const u8,
) ParseError!usize {
    const field = &@field(target, flag.field);
    const Field = @TypeOf(field.*);
    var i = at;
    if (flag.value == null) {
        if (inline_value != null) return fail(arena, problem, "--{s} takes no value", .{flag.field});
        field.* = true;
        return i;
    }
    const value = inline_value orelse blk: {
        i += 1;
        if (i >= argv.len) return fail(arena, problem, "a value is required for '--{s} <{s}>'", .{ flag.field, flag.value.? });
        break :blk argv[i];
    };
    switch (Field) {
        ?[]const u8 => field.* = value,
        []const []const u8 => {
            const gop = try appended.getOrPut(arena, flag.field);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, value);
        },
        bool => field.* = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return fail(arena, problem, "invalid value '{s}' for '--{s}': true or false", .{ value, flag.field }),
        u32 => field.* = std.fmt.parseInt(u32, value, 10) catch
            return fail(arena, problem, "invalid value '{s}' for '--{s}': a number", .{ value, flag.field }),
        else => @compileError("no parser for " ++ @typeName(Field)),
    }
    return i;
}

fn fail(arena: Allocator, problem: *[]const u8, comptime fmt: []const u8, args: anytype) ParseError {
    problem.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidArguments;
}

fn helpFor(arena: Allocator, spec: ?Spec, version: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeHelp(w, spec, version) catch return error.OutOfMemory;
    return out.written();
}

fn writeHelp(w: *std.Io.Writer, spec: ?Spec, version: []const u8) std.Io.Writer.Error!void {
    if (spec) |c| {
        try w.print("{s}\n\nUsage: orchd {s} [OPTIONS]", .{ c.about, c.name });
        switch (c.positional) {
            .none => {},
            .services => try w.writeAll(" [SERVICES]..."),
            .service => try w.writeAll(" <SERVICE>"),
            .optional_service => try w.writeAll(" [SERVICE]"),
        }
        try w.writeAll("\n");
        if (c.positional != .none) {
            try w.writeAll("\nArguments:\n");
            try w.print("  {s:<28} {s}\n", .{ if (c.positional == .services) "[SERVICES]..." else "<SERVICE>", c.positional_help });
        }
        try w.writeAll("\nOptions:\n");
        for (c.flags) |flag| try writeFlag(w, flag);
        for (global_flags) |flag| try writeFlag(w, flag);
        try w.print("  {s:<28} {s}\n", .{ "-h, --help", "Print help" });
        return;
    }
    try w.print("Orch execution engine ({s})\n\nUsage: orchd [OPTIONS] <COMMAND>\n\nCommands:\n", .{version});
    for (commands) |c| try w.print("  {s:<8} {s}\n", .{ c.name, c.about });
    try w.writeAll("\nOptions:\n");
    for (global_flags) |flag| try writeFlag(w, flag);
    try w.print("  {s:<28} {s}\n", .{ "-h, --help", "Print help" });
    try w.print("  {s:<28} {s}\n", .{ "-V, --version", "Print version" });
}

fn writeFlag(w: *std.Io.Writer, flag: Flag) std.Io.Writer.Error!void {
    var name_buf: [64]u8 = undefined;
    var name: std.Io.Writer = .fixed(&name_buf);
    if (flag.short) |s| try name.print("-{c}, ", .{s}) else try name.writeAll("    ");
    try name.writeAll("--");
    for (flag.field) |c| try name.writeByte(if (c == '_') '-' else c);
    if (flag.value) |v| try name.print(" <{s}>", .{v});
    try w.print("  {s:<28} {s}\n", .{ name.buffered(), flag.help });
}

fn parsed(arena: Allocator, argv: []const []const u8) !Cli {
    var problem: []const u8 = "";
    return switch (try parse(arena, argv, "test", &problem)) {
        .run => |cli| cli,
        else => error.NotARun,
    };
}

test "fell takes services and --keep-data" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parsed(arena.allocator(), &.{ "fell", "web", "db", "--keep-data" });
    try testing.expectEqual(2, cli.command.fell.services.len);
    try testing.expectEqualStrings("db", cli.command.fell.services[1]);
    try testing.expect(cli.command.fell.keep_data);
}

test "fell bare is the whole grove" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parsed(arena.allocator(), &.{"fell"});
    try testing.expectEqual(0, cli.command.fell.services.len);
}

test "global flags go before or after the command, as --flag value or --flag=value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parsed(arena.allocator(), &.{
        "--grove", "hum", "grow", "web", "--state-dir=/s", "--user", "--arg", "A=1", "--arg=B=2", "--overlay", "o.orch", "-q", "--no-start",
    });
    try testing.expectEqualStrings("hum", cli.global.grove.?);
    try testing.expectEqualStrings("/s", cli.global.state_dir.?);
    try testing.expect(cli.global.user);
    try testing.expect(cli.global.quiet);
    try testing.expectEqual(2, cli.global.arg.len);
    try testing.expectEqualStrings("B=2", cli.global.arg[1]);
    try testing.expectEqualStrings("o.orch", cli.global.overlay[0]);
    try testing.expectEqualStrings("web", cli.command.grow.services[0]);
    try testing.expect(cli.command.grow.no_start);
}

test "tend keeps a tree from a spec, or tends the beds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const keeper = try parsed(arena.allocator(), &.{ "tend", "--spec", "/s/supervise/orch.web.json" });
    try testing.expectEqualStrings("/s/supervise/orch.web.json", keeper.command.tend.spec.?);
    const beds = try parsed(arena.allocator(), &.{ "tend", "--no-start" });
    try testing.expect(beds.command.tend.no_start);
    try testing.expectEqual(null, beds.command.tend.spec);
}

test "logs takes one service, follows by default and counts lines with -n" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parsed(arena.allocator(), &.{ "logs", "web", "-n", "20" });
    try testing.expectEqualStrings("web", cli.command.logs.service);
    try testing.expect(cli.command.logs.follow);
    try testing.expectEqual(20, cli.command.logs.lines);
    const once = try parsed(arena.allocator(), &.{ "logs", "web", "--follow=false" });
    try testing.expect(!once.command.logs.follow);
}

test "conflicting and unknown arguments are refused with a reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";
    try testing.expectError(error.InvalidArguments, parse(a, &.{ "grow", "--reload", "--no-start" }, "t", &problem));
    try testing.expectEqualStrings("--reload cannot be used with --no-start", problem);
    try testing.expectError(error.InvalidArguments, parse(a, &.{ "--user", "--system", "survey" }, "t", &problem));
    try testing.expectError(error.InvalidArguments, parse(a, &.{ "tend", "web", "--spec", "x" }, "t", &problem));
    try testing.expectError(error.InvalidArguments, parse(a, &.{"prune"}, "t", &problem));
    try testing.expectEqualStrings("unrecognized subcommand 'prune'", problem);
    try testing.expectError(error.InvalidArguments, parse(a, &.{ "survey", "--keep-data" }, "t", &problem));
    try testing.expectError(error.InvalidArguments, parse(a, &.{ "grow", "--grove" }, "t", &problem));
    try testing.expectEqualStrings("a value is required for '--grove <GROVE>'", problem);
}

test "help is there for orchd and each command, and version on its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";
    const top = (try parse(a, &.{"--help"}, "0.4.0", &problem)).help;
    try testing.expect(std.mem.indexOf(u8, top, "Orch execution engine (0.4.0)") != null);
    try testing.expect(std.mem.indexOf(u8, top, "  fell     Fell trees") != null);
    const grow = (try parse(a, &.{ "grow", "-h" }, "0.4.0", &problem)).help;
    try testing.expect(std.mem.indexOf(u8, grow, "--no-start") != null);
    try testing.expect(std.mem.indexOf(u8, grow, "--state-dir <STATE_DIR>") != null);
    try testing.expectEqual(.version, try parse(a, &.{"-V"}, "0.4.0", &problem));
}
