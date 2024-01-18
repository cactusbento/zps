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
        switch (cmd) {
            .search => {
                var index_List = std.ArrayList(usize).init(allocator);
                defer index_List.deinit();

                for (packages.items(.name), packages.items(.description), 0..) |name, desc, i| {
                    const search_terms = argv[2..];
                    for (search_terms) |term| {
                        const lc_name = try std.ascii.allocLowerString(allocator, name);
                        defer allocator.free(lc_name);
                        const lc_desc = try std.ascii.allocLowerString(allocator, desc);
                        defer allocator.free(lc_desc);
                        const lc_term = try std.ascii.allocLowerString(allocator, term);
                        defer allocator.free(lc_term);

                        const in_name = std.mem.indexOf(u8, lc_name, lc_term) != null;
                        const in_desc = std.mem.indexOf(u8, lc_desc, lc_term) != null;

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
            .install => {
                const which_res = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "which", "bmake" },
                });
                defer {
                    allocator.free(which_res.stdout);
                    allocator.free(which_res.stderr);
                }
                if (which_res.term != .Exited) {
                    try stdout.print(
                        \\ Command "bmake" not found.
                        \\
                        \\ Is "pkgsrc" installed?
                        \\ Is "bmake" in your PATH?
                    , .{});
                    try bw.flush();
                    return error.CommandNotFound;
                }
                const pkgs_to_install = argv[2..];
                for (pkgs_to_install) |pkg_name| {
                    const pkg_index = indexOfSlice(u8, packages.items(.name), pkg_name) orelse {
                        try stdout.print("Package not found: {s}\n", .{pkg_name});
                        try bw.flush();
                        return error.PackageNotFound;
                    };

                    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                        packages.items(.category)[pkg_index],
                        packages.items(.name)[pkg_index],
                    });
                    defer allocator.free(pkg_path);

                    var pkg_dir = try pkgsrc.openDir(pkg_path, .{ .iterate = true });
                    defer pkg_dir.close();

                    const bmake_res = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{"bmake"},
                        .cwd_dir = pkg_dir,
                    });
                    defer {
                        allocator.free(bmake_res.stdout);
                        allocator.free(bmake_res.stderr);
                    }
                    if (bmake_res.term != .Exited) {
                        try stdout.print("bmake failed: \n{s}\n", .{bmake_res.stdout});
                        try bw.flush();
                        return error.bmakeFail;
                    }

                    const bmake_install_res = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "bmake", "install" },
                        .cwd_dir = pkg_dir,
                    });
                    defer {
                        allocator.free(bmake_install_res.stdout);
                        allocator.free(bmake_install_res.stderr);
                    }
                    if (bmake_install_res.term != .Exited) {
                        try stdout.print("bmake install failed: \n{s}\n", .{bmake_install_res.stdout});
                        try bw.flush();
                        return error.bmakeInstallFail;
                    }

                    const bmake_clean_res = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "bmake", "clean" },
                        .cwd_dir = pkg_dir,
                    });
                    defer {
                        allocator.free(bmake_clean_res.stdout);
                        allocator.free(bmake_clean_res.stderr);
                    }
                    if (bmake_clean_res.term != .Exited) {
                        try stdout.print("bmake clean failed: \n{s}\n", .{bmake_clean_res.stdout});
                        try bw.flush();
                        return error.bmakeCleanFail;
                    }

                    const bmake_cleandep_res = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "bmake", "clean-depends" },
                        .cwd_dir = pkg_dir,
                    });
                    defer {
                        allocator.free(bmake_cleandep_res.stdout);
                        allocator.free(bmake_cleandep_res.stderr);
                    }
                    if (bmake_cleandep_res.term != .Exited) {
                        try stdout.print("bmake clean-depends failed: \n{s}\n", .{bmake_cleandep_res.stdout});
                        try bw.flush();
                        return error.bmakeCleanDependsFail;
                    }
                }
            },
            .uninstall => {
                const pkgs_to_uninstall = argv[2..];
                for (pkgs_to_uninstall) |pkg_name| {
                    const pkg_delete_res = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "pkg_delete", pkg_name },
                    });
                    defer {
                        allocator.free(pkg_delete_res.stdout);
                        allocator.free(pkg_delete_res.stderr);
                    }
                    if (pkg_delete_res.term != .Exited) {
                        try stdout.print("pkg_delete failed: \n{s}\n", .{pkg_delete_res.stdout});
                        try bw.flush();
                        return error.pkgDeleteFail;
                    }
                }
            },
        }
    } else {
        try stdout.print("{s}\n", .{pkgsrcloc});
        try bw.flush();

        return error.PKGSRCLOCNotSet;
    }
}

fn indexOfSlice(comptime T: type, a: []const []const T, b: []const T) ?usize {
    for (a, 0..) |str, i| {
        if (std.mem.eql(T, str, b)) {
            return i;
        }
    }
    return null;
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
