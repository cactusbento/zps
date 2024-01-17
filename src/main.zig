const std = @import("std");
const blt = @import("builtin");

const usage =
    \\usage: pkgsrc <command> ...
    \\
    \\commands:
    \\    search [terms...]        Search package names and descriptions.
    \\                             Terms after the first will further filter
    \\                             the output.
    \\                             If available, fzf will be used.
    \\    install [packages...]    Install one or more packages
    \\    uninstall [packages...]  Uninstall one or more packages
;

const pkgsrcloc =
    \\PKGSRCLOC is not defined
    \\clone https://github.com/NetBSD/pkgsrc into a location
    \\and set PKGSRCLOC to that location.
    \\
    \\For Example:
    \\    ~\$ git clone https://github.com/NetBSD/pkgsrc ~/.local/pkgsrc
    \\    ~\$ set -U PKGSRCLOC ~/.local/pkgsrc
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const ttycfg = std.io.tty.detectConfig(std.io.getStdOut());

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        try stdout.print("{s}\n", .{usage});
        try bw.flush();
        return error.NoCommandSpecified;
    }

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    if (env.get("PKGSRCLOC")) |loc| {
        var pkgsrc = try std.fs.openDirAbsolute(loc, .{ .iterate = true });
        defer pkgsrc.close();

        const cmd = std.meta.stringToEnum(Command, argv[1]) orelse {
            try stdout.print("{s}\n", .{usage});
            try bw.flush();
            return error.InvalidCommand;
        };
        switch (cmd) {
            .search => {
                var packages = std.MultiArrayList(Package){};
                defer {
                    var slice = packages.slice();
                    for (slice.items(.name), slice.items(.category), slice.items(.description)) |name, cat, desc| {
                        allocator.free(name);
                        allocator.free(cat);
                        allocator.free(desc);
                    }
                    slice.deinit(allocator);
                }

                var pkgsrc_iter = pkgsrc.iterate();
                while (try pkgsrc_iter.nextLinux()) |cat_entry| {
                    if (cat_entry.kind != .directory) continue; // ignore files
                    var cat = try pkgsrc.openDir(cat_entry.name, .{ .iterate = true });
                    defer cat.close();

                    var cat_iter = cat.iterate();
                    while (try cat_iter.nextLinux()) |pkg_entry| {
                        if (pkg_entry.kind != .directory) continue; // ignore files
                        var pkg = try cat.openDir(pkg_entry.name, .{});
                        defer pkg.close();

                        _ = pkg.statFile("DESCR") catch |err| switch (err) {
                            error.FileNotFound => continue,
                            else => |e| return e,
                        };

                        try packages.append(allocator, try Package.read(
                            allocator,
                            cat_entry.name,
                            pkg_entry.name,
                            pkg,
                        ));
                    }
                }
                var index_List = std.ArrayList(usize).init(allocator);
                defer index_List.deinit();

                for (packages.items(.name), packages.items(.description), 0..) |name, desc, i| {
                    const search_terms = argv[2..];
                    for (search_terms) |term| {
                        const in_name = std.mem.indexOf(u8, name, term) != null;
                        const in_desc = std.mem.indexOf(u8, desc, term) != null;

                        if (in_name or in_desc) {
                            try index_List.append(i);
                        }
                    }
                }
                for (index_List.items) |i| {
                    try ttycfg.setColor(stdout, .cyan);
                    try stdout.print("{s}", .{
                        packages.items(.category)[i],
                    });
                    try ttycfg.setColor(stdout, .reset);
                    try stdout.print("/", .{});
                    try ttycfg.setColor(stdout, .bright_white);
                    try stdout.print("{s}\n", .{
                        packages.items(.name)[i],
                    });
                    try ttycfg.setColor(stdout, .reset);
                    try stdout.print("{s}\n\n", .{
                        packages.items(.description)[i],
                    });
                    try ttycfg.setColor(stdout, .reset);
                }
                try bw.flush();
            },
            .install => {},
            .uninstall => {},
        }
    } else {
        try stdout.print("{s}\n", .{pkgsrcloc});
        try bw.flush();

        return error.PKGSRCLOCNotSet;
    }
}

const Command = enum {
    search,
    install,
    uninstall,
};

const Package = struct {
    category: []const u8,
    name: []const u8,
    description: []const u8,

    pub fn read(allocator: std.mem.Allocator, cat: []const u8, name: []const u8, pkg_dir: std.fs.Dir) !Package {
        const description = try pkg_dir.readFileAlloc(allocator, "DESCR", 4096);
        defer allocator.free(description);

        var ci = std.mem.splitScalar(u8, description, '.');

        const pkgname = try allocator.dupe(u8, name);
        const pkgcat = try allocator.dupe(u8, cat);

        return .{
            .name = pkgname,
            .category = pkgcat,
            .description = try allocator.dupe(
                u8,
                std.mem.trim(u8, ci.first(), &std.ascii.whitespace),
            ),
        };
    }
};
