//! 这是一个工具包，提供根据关键词和一组目录路径找出目录中文件路径和名称中包含关键词的方法

const std = @import("std");

/// 匹配到搜索文本的自定义类型
pub const Matched = struct {
    /// 实体路径
    path: []const u8,
    /// 实体类型
    kind: std.Io.File.Kind,
};

/// 搜索工具入口方法
pub fn search(init: std.process.Init) !void {
    const args_slice = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args_slice);

    const stdout_file = std.Io.File.stdout();
    var info_buf: [4096]u8 = undefined;
    var stdout_impl = stdout_file.writer(init.io, &info_buf);
    const stdout = &stdout_impl.interface;

    const info_str = blk: switch (args_slice.len) {
        1 => "缺少搜索字符串和搜索目录路径",
        2 => "缺少搜索目录路径",
        3 => break :blk "",
        else => "参数过多",
    };

    if (info_str.len > 0) {
        try stdout.print("{s}\n", .{info_str});
        try stdout.flush();
    } else {
        var result = try travers(init.gpa, init.io, args_slice[1], args_slice[2]);
        defer {
            for (result.items) |item| {
                init.gpa.free(item);
            }
            result.deinit(init.gpa);
        }

        for (result.items) |item| {
            try stdout.print("{s}\n", .{item});
        }
        try stdout.flush();
    }
}

/// 遍历指定的目录，返回路径匹配到搜索文本的自定义实体动态数组
pub fn travers(gpa: std.mem.Allocator, io: std.Io, text: []const u8, dir_paths: [][]const u8, data_map: *std.StringArrayHashMapUnmanaged([]Matched)) !void {
    for (dir_paths) |dir_path| {
        var matched_list = std.ArrayList(Matched).empty;
        const root_dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        defer root_dir.close(io);

        var walker = try root_dir.walk(gpa);
        defer walker.deinit();

        while (true) {
            if (try walker.next(io)) |item| {
                const match = std.mem.find(u8, item.basename, text);

                if (match) |_| {
                    const item_path = try gpa.dupe(u8, item.path);
                    // const item_path = item.path;
                    const item_kind = item.kind;
                    try matched_list.append(gpa, Matched{ .path = item_path, .kind = item_kind });
                }
            } else {
                break;
            }
        }

        if (matched_list.items.len > 0) {
            try data_map.put(gpa, dir_path, matched_list.items);
        }
    }
}
