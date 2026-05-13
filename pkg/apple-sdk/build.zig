const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}

pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const target = step.rootModuleTarget();
    if (!target.os.tag.isDarwin()) return;

    const libc = try std.zig.LibCInstallation.findNative(b.allocator, b.graph.io, .{
        .target = &target,
        .environ_map = &b.graph.environ_map,
        .verbose = false,
    });

    var libc_contents: std.Io.Writer.Allocating = .init(b.allocator);
    defer libc_contents.deinit();
    try libc.render(&libc_contents.writer);

    const write_files = b.addWriteFiles();
    const libc_file = write_files.add("libc.txt", libc_contents.written());
    step.setLibCFile(libc_file);

    const sys_include = libc.sys_include_dir orelse return error.AppleSDKNotFound;
    const sdk_usr = std.fs.path.dirname(sys_include) orelse return error.AppleSDKNotFound;
    const sdk_root = std.fs.path.dirname(sdk_usr) orelse return error.AppleSDKNotFound;

    step.root_module.addSystemIncludePath(.{ .cwd_relative = sys_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = try std.fs.path.join(
        b.allocator,
        &.{ sdk_usr, "lib" },
    ) });
    step.root_module.addSystemFrameworkPath(.{ .cwd_relative = try std.fs.path.join(
        b.allocator,
        &.{ sdk_root, "System", "Library", "Frameworks" },
    ) });
}
