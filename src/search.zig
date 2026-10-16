//! 这是一个搜索包含提供字符串的文件和文件夹的工具，区分大小写
//! 编译命令: zig build --prefix ./build/search_tool  -Doptimize=ReleaseSafe
//! Example 1: zig run src/main.zig -- .zig /Users/virgil/Workspace/Personal/Zig/zig_test
//! Example 2: build/search_tool/bin/zig_test .zig /Users/virgil/Workspace/Personal/Zig/zig_test

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
pub fn travers(gpa: std.mem.Allocator, io: std.Io, text: []const u8, dir_path: []const u8) !std.ArrayList(Matched) {
    var matched_list = std.ArrayList(Matched).empty;
    defer {
        // for (matched_list.items) |item| {
        //     gpa.free(item.path);
        //     // gpa.free(item.kind);
        // }
        // matched_list.deinit(gpa);
    }

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

    return matched_list;
}

// /// 遍历指定的目录，返回路径匹配到搜索文本的自定义实体动态数组
// pub fn travers(gpa: std.mem.Allocator, io: std.Io, text: []const u8, dir_path: []const u8) !std.ArrayList([]const u8) {
//     var list = std.ArrayList([]const u8).empty;
//     var matched_list = std.ArrayList(Matched).empty;
//     defer {
//         for (matched_list.items) |item| {
//             gpa.free(item.path);
//             gpa.free(item.kind);
//         }
//         matched_list.deinit(gpa);
//     }
//
//     const root_dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
//     defer root_dir.close(io);
//
//     var walker = try root_dir.walk(gpa);
//     defer walker.deinit();
//
//     var len: usize = 0;
//
//     while (true) {
//         if (try walker.next(io)) |item| {
//             const match = std.mem.find(u8, item.basename, text);
//
//             if (match) |index| {
//                 _ = index;
//                 const exact_len = item.path.len + @tagName(item.kind).len + 6;
//                 if (len < exact_len) {
//                     len = exact_len;
//                 }
//
//                 const item_path = try gpa.dupe(u8, item.path);
//                 const item_kind = try gpa.dupe(u8, @tagName(item.kind));
//                 try matched_list.append(gpa, Matched{ .path = item_path, .kind = item_kind });
//             }
//         } else {
//             break;
//         }
//     }
//
//     for (matched_list.items) |item| {
//         const total_str = try gpa.alloc(u8, len);
//         @memcpy(total_str[0..item.path.len], item.path);
//         @memset(total_str[item.path.len .. len - item.kind.len], ' ');
//         @memcpy(total_str[len - item.kind.len ..], item.kind);
//         try list.append(gpa, total_str);
//     }
//     return list;
// }
