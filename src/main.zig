const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

// const target_finder = @import("target_finder");

const search = @import("search.zig");

const Io = std.Io;

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "Target Finder",
            .icon = null,
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var gpa = std.heap.smp_allocator;

var orig_content_scale: f32 = 1.0;
// var warn_on_quit: bool = false;
// var warn_on_quit_closing: bool = false;
// var extra_os_win: bool = false;

// 关键词相关
var keyword_buffer = std.mem.zeroes([256]u8);
var keyword_box_id: dvui.Id = undefined;

// 目录路径相关
var directories = std.ArrayList([]const u8).empty;
var directory_list_id: dvui.Id = undefined;
var directory_inner_box_padding: dvui.Rect = dvui.Rect.all(0);
var btn_inner_box_padding: dvui.Rect = dvui.Rect.all(0);
var directory_scroll_info = dvui.ScrollInfo{ .horizontal = .auto };
var btn_scroll_info = dvui.ScrollInfo{ .horizontal = .none };

// 搜索结果相关
var result_map: std.StringArrayHashMapUnmanaged([]search.Matched) = undefined;
var result_inner_box_h: f32 = undefined;
var expander_collapsed_map: std.AutoArrayHashMapUnmanaged(usize, bool) = undefined;
var result_inner_box_padding: dvui.Rect = dvui.Rect.all(0);
var result_btn_inner_box_padding: dvui.Rect = dvui.Rect.all(0);
var result_scroll_info = dvui.ScrollInfo{ .horizontal = .auto };
var result_btn_scroll_info = dvui.ScrollInfo{ .horizontal = .none };

var searching = false;
var worker: ?std.Thread = null;

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn appInit(win: *dvui.Window) !void {
    orig_content_scale = win.content_scale;

    // Add your own bundled font files...:
    // try dvui.addFont("NOTO", @embedFile("../src/fonts/NotoSansKR-Regular.ttf"), null);

    try dvui.addFont("NOTO", @embedFile("../src/assets/fonts/NotoSerifSC-VariableFont_wght.ttf"), null);

    // Initialize search result maps
    result_map = .{};
    try result_map.ensureUnusedCapacity(gpa, 256);
    expander_collapsed_map = .{};
    try expander_collapsed_map.ensureUnusedCapacity(gpa, 256);

    // If you want a custom theme use something like this:
    // const theme = switch (win.backend.preferredColorScheme() orelse .light) {
    //     .light => dvui.Theme.builtin.adwaita_light,
    //     .dark => dvui.Theme.builtin.adwaita_dark,
    // };
    // win.themeSet(theme);

}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    // good place to free anything you've allocated with win.gpa
    defer {
        // for (directories.items) |item| {
        //     gpa.free(item);
        // }
        defer directories.deinit(gpa);
    }
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
        scaler.deinit();

        if (menu()) |res| return res;

        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .max_size_content = .{ .w = 200, .h = dvui.currentWindow().rect_pixels.h },
            .min_size_content = .{ .h = 300 },
            .style = .content,
            .background = true,
        });
        defer box.deinit();

        if (try content()) |res| return res;
    }

    return .ok;
}

pub fn menu() ?dvui.App.Result {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
    defer hbox.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "first-focusable" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Close Menu", .{}, .{ .expand = .horizontal }) != null) {
            m.close();
        }

        if (dvui.backend.kind != .web) {
            if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                return .close;
            }
        }
    }

    return null;
}

pub fn content() !?dvui.App.Result {
    var left_alignment = dvui.Alignment.init(@src(), 0);
    defer left_alignment.deinit();

    // 输入区块
    {
        var top_box = dvui.groupBox(@src(), "Input", .{ .border = .all(1.0), .expand = .horizontal });
        defer top_box.deinit();

        // 关键词区块
        {
            var keyword_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer keyword_box.deinit();

            dvui.label(@src(), "Keyword: ", .{}, .{ .gravity_y = 0.5 });

            left_alignment.spacer(@src(), 0);

            var keyword_input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &keyword_buffer } }, .{ .label = .{ .label_widget = .prev } });
            defer keyword_input.deinit();

            keyword_box_id = keyword_input.data().id;

            // std.debug.print("{s}\n", .{keyword_input.textGet()});
        }

        // 目录区块
        {
            var directory_box_wrapper = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer directory_box_wrapper.deinit();

            dvui.label(@src(), "Directory: ", .{}, .{ .gravity_y = 0, .margin = .rect(0, 4, 0, 0) });

            left_alignment.spacer(@src(), 0);

            var directory_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer directory_box.deinit();

            {
                var directory_list_box = dvui.box(@src(), .{
                    .dir = .horizontal,
                }, .{ .expand = .both, .border = if (directories.items.len > 0) .all(1) else .all(0), .margin = .rect(4, if (directories.items.len > 0) 4 else 0, 0, 0), .padding = if (directories.items.len > 0) .rect(2, 2, 2, 2) else .rect(0, 4, 0, 0), .corners = .round(3) });
                defer directory_list_box.deinit();

                if (directory_scroll_info.viewport.size().w < directory_scroll_info.virtual_size.cast().w) {
                    directory_inner_box_padding = .rect(0, 0, 0, 8);
                    btn_inner_box_padding = .rect(12, 0, 12, 8);
                } else {
                    directory_inner_box_padding = .rect(0, 0, 0, 0);
                    btn_inner_box_padding = .rect(12, 0, 12, 0);
                }

                // 目录路径列表
                {
                    // directory_scroll_info.scrollToOffset(.vertical, btn_scroll_info.offset(.vertical));

                    // directory_scroll_info.viewport.h = btn_scroll_info.offset(.vertical);

                    var directory_list = dvui.scrollArea(@src(), .{ .scroll_info = &directory_scroll_info, .vertical_bar = .hide, .horizontal_bar = .auto_overlay }, .{
                        .expand = .both,
                        .style = .content,
                        .max_size_content = .size(.{ .h = 200 }),
                    });
                    defer directory_list.deinit();

                    directory_list_id = directory_list.data().id;
                    dvui.dataSetSlice(dvui.currentWindow(), directory_list_id, "directories", directories.items);

                    var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .expand = .both,
                        .padding = directory_inner_box_padding,
                    });
                    defer inner_box.deinit();

                    const directory_paths = dvui.dataGetSlice(dvui.currentWindow(), directory_list_id, "directories", [][]const u8) orelse @as([][]const u8, &.{});

                    for (directory_paths, 0..) |item, index| {
                        var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                            .expand = .vertical,
                            .id_extra = index,
                            .max_size_content = .size(.{ .w = 1000, .h = 20 }),
                            .min_size_content = .{ .w = inner_box.data().rect.w, .h = 20 },
                            .margin = .all(0),
                            .padding = .rect(0, 4, 0, 4),
                        });
                        defer tl.deinit();
                        tl.format("{d} - {s}\n", .{ index, item }, .{ .gravity_y = 0.5, .font = .{ .size = 10 } });
                    }
                }

                // 按钮列表
                {
                    // btn_scroll_info.scrollToOffset(.vertical, directory_scroll_info.offset(.vertical));

                    var btn_list = dvui.scrollArea(@src(), .{ .scroll_info = &btn_scroll_info, .vertical_bar = .auto_overlay }, .{ .expand = .vertical, .style = .content, .max_size_content = .size(.{ .w = 44 }), .min_size_content = .{ .w = 44 } });
                    defer btn_list.deinit();

                    var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .padding = btn_inner_box_padding });
                    defer inner_box.deinit();

                    const directory_paths = dvui.dataGetSlice(dvui.currentWindow(), directory_list_id, "directories", [][]const u8) orelse @as([][]const u8, &.{});

                    for (directory_paths, 0..) |_, index| {
                        if (dvui.buttonIcon(@src(), "minus", dvui.entypo.minus, .{ .draw_focus = false }, .{}, .{ .id_extra = index, .max_size_content = .size(.{ .w = 12, .h = 12 }), .min_size_content = .{ .w = 12, .h = 12 }, .margin = .rect(0, 4, 0, 4), .corners = .all(12) })) {
                            std.debug.print("{s}\n", .{"点击了移除按钮"});
                            _ = directories.orderedRemove(index);

                            dvui.dataSetSlice(dvui.currentWindow(), directory_list_id, "directories", directories.items);
                        }
                    }
                }
            }

            // 新增目录按钮
            {
                if (dvui.buttonIcon(@src(), "plus", dvui.entypo.plus, .{ .draw_focus = false }, .{}, .{})) {
                    std.debug.print("{s}\n", .{"点击了新增按钮"});

                    const directory_path = try dvui.dialogNativeFolderSelect(gpa, .{}) orelse @as([]const u8, &.{});

                    const contains = for (directories.items) |item| {
                        if (std.mem.eql(u8, item, directory_path)) {
                            break true;
                        }
                    } else false;

                    if (contains == false) {
                        try directories.append(gpa, directory_path);
                    }

                    dvui.dataSetSlice(dvui.currentWindow(), directory_list_id, "directories", directories.items);
                }
            }
        }

        // 操作区块
        {
            var opt_box_wrapper = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .margin = .rect(0, 4, 0, 0) });
            defer opt_box_wrapper.deinit();

            left_alignment.spacer(@src(), 0);

            var opt_box = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer opt_box.deinit();

            if (dvui.button(@src(), "Search", .{ .draw_focus = false }, .{})) {
                const keyword: []const u8 = std.mem.sliceTo(&keyword_buffer, 0);

                if (keyword.len == 0) return null;

                const directory_paths = dvui.dataGetSlice(dvui.currentWindow(), directory_list_id, "directories", [][]const u8) orelse @as([][]const u8, &.{});

                if (searching == false) {
                    searching = true;
                    worker = try std.Thread.spawn(.{}, search.travers, .{ gpa, dvui.io, keyword, directory_paths, &result_map });
                } else {
                    // Already searching, ignore
                }
            }

            // Wait for background search to complete
            if (searching) {
                if (worker) |w| {
                    w.join();
                    worker = null;
                    searching = false;
                }
            }
        }
    }

    // 输出区块
    {
        var bottom_box = dvui.groupBox(@src(), "Output", .{ .border = .all(1.0), .expand = .both });
        defer bottom_box.deinit();

        var result_box_wrapper = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer result_box_wrapper.deinit();

        if (result_scroll_info.viewport.size().w < result_scroll_info.virtual_size.cast().w) {
            result_inner_box_padding = .rect(0, 0, 0, 8);
            result_btn_inner_box_padding = .rect(12, 0, 12, 8);
        } else {
            result_inner_box_padding = .rect(0, 0, 0, 0);
            result_btn_inner_box_padding = .rect(12, 0, 12, 0);
        }

        // 结果路径列表
        {
            // result_scroll_info.scrollToOffset(.vertical, result_btn_scroll_info.offset(.vertical));

            var result_list = dvui.scrollArea(@src(), .{ .scroll_info = &result_scroll_info, .vertical_bar = .auto_overlay, .horizontal_bar = .auto_overlay }, .{
                .expand = .both,
                .style = .content,
                .max_size_content = .size(.{ .h = 200 }),
            });
            defer result_list.deinit();

            var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .both,
                .padding = result_inner_box_padding,
            });
            defer inner_box.deinit();

            result_inner_box_h = inner_box.data().rect.h;

            const len = result_map.entries.len;

            for (0..len) |index| {
                const item = result_map.entries.slice().get(index);

                if (dvui.expander(@src(), item.key, .{ .default_expanded = true }, .{ .id_extra = index, .min_size_content = .{ .h = 20 }, .max_size_content = .size(.{ .w = inner_box.data().rect.w, .h = 20 }), .margin = .all(0), .padding = .rect(0, 0, 0, 4), .font = .{ .size = 12 } })) {
                    for (0..item.value.len) |inner_index| {
                        const item_id = index * 10000 + inner_index;

                        var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                            .id_extra = item_id,
                            .max_size_content = .size(.{ .w = 1000, .h = 20 }),
                            .min_size_content = .{ .w = inner_box.data().rect.w, .h = 20 },
                            .margin = .all(0),
                            .padding = .rect(0, 4, 0, 4),
                        });
                        defer tl.deinit();
                        tl.format("{d} - {s}\n", .{ inner_index, item.value[inner_index].path }, .{ .gravity_y = 0.5, .font = .{ .size = 10 } });
                    }
                    try expander_collapsed_map.put(gpa, index, false);
                } else {
                    try expander_collapsed_map.put(gpa, index, true);
                }
            }
        }

        // 按钮列表
        //         {
        //             // result_btn_scroll_info.scrollToOffset(.vertical, result_scroll_info.offset(.vertical));
        //
        //             var btn_list = dvui.scrollArea(@src(), .{ .scroll_info = &result_btn_scroll_info, .vertical_bar = .auto_overlay }, .{ .expand = .vertical, .style = .content, .max_size_content = .size(.{ .w = 100 }), .min_size_content = .{ .w = 100 } });
        //             defer btn_list.deinit();
        //
        //             // std.debug.print("-- {d}\n", .{result_inner_box_h});
        //
        //             var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .padding = result_btn_inner_box_padding, .max_size_content = .size(.{ .w = 100, .h = result_inner_box_h }), .min_size_content = .{ .h = result_inner_box_h } });
        //             defer inner_box.deinit();
        //
        //             const len = result_map.entries.len;
        //
        //             for (0..len) |index| {
        //                 const item = result_map.entries.slice().get(index);
        //
        //                 _ = dvui.spacer(@src(), .{
        //                     .min_size_content = .{ .h = 20 },
        //                     .max_size_content = .size(.{ .h = 20 }),
        //                     .id_extra = index,
        //                 });
        //
        //                 const collapsed = expander_collapsed_map.get(index) orelse false;
        //
        //                 if (collapsed == false) {
        //                     for (0..item.value.len) |inner_index| {
        //                         // const i_number = (len + item.value.len) * (index + 1) + inner_index;
        //
        //                         const i_number = len + item.value.len + item.value.len * (index + 1) + inner_index;
        //
        //                         const icon_type = switch (item.value[inner_index].kind) {
        //                             .directory => .{ "folder", dvui.entypo.folder },
        //                             .file => .{ "documents", dvui.entypo.documents },
        //                             else => .{ "emoji_neutral", dvui.entypo.emoji_neutral },
        //                         };
        //
        //                         var h_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i_number, .min_size_content = .{ .w = 100, .h = 28 }, .max_size_content = .size(.{ .w = 100, .h = 28 }), .padding = .rect(0, 1, 0, 1) });
        //                         defer h_box.deinit();
        //
        //                         {
        //                             dvui.icon(@src(), icon_type.@"0", icon_type.@"1", .{}, .{ .id_extra = i_number, .max_size_content = .size(.{ .w = 12, .h = 12 }), .min_size_content = .{ .w = 12, .h = 12 }, .margin = .rect(0, 4, 12, 4), .gravity_y = 0.5 });
        //                         }
        //
        //                         {
        //                             if (dvui.buttonIcon(@src(), "copy", dvui.entypo.copy, .{}, .{}, .{ .id_extra = i_number, .max_size_content = .size(.{ .w = 12, .h = 12 }), .min_size_content = .{ .w = 12, .h = 12 }, .margin = .rect(0, 4, 12, 4), .corners = .all(12) })) {
        //                                 std.debug.print("{s}\n", .{"点击了拷贝按钮"});
        //                                 dvui.clipboardTextSet(item.value[inner_index].path);
        //                             }
        //                         }
        //
        //                         {
        //                             if (dvui.buttonIcon(@src(), "arrow_right", dvui.entypo.arrow_right, .{}, .{}, .{ .id_extra = i_number, .max_size_content = .size(.{ .w = 12, .h = 12 }), .min_size_content = .{ .w = 12, .h = 12 }, .margin = .rect(0, 4, 0, 4), .corners = .all(12) })) {
        //                                 std.debug.print("{s}\n", .{"点击了打开按钮"});
        //
        //                                 // 如果是文件则使用文件所在的目录路径
        //                                 const directory_path = if (std.mem.cutScalarLast(u8, item.value[inner_index].path, '/')) |v| v.@"0" else "";
        //
        //                                 const absolute_path = try gpa.alloc(u8, item.key.len + directory_path.len);
        //
        //                                 @memcpy(absolute_path[0..item.key.len], item.key);
        //                                 @memcpy(absolute_path[item.key.len..], directory_path);
        //
        //                                 const current_target = try std.zig.system.resolveTargetQuery(dvui.io, try std.Target.Query.parse(.{}));
        //
        //                                 var cmd: []const u8 = undefined;
        //                                 if (current_target.os.tag.isDarwin()) {
        //                                     cmd = "/usr/bin/open";
        //                                 } else if (current_target.os.tag.isBSD()) {
        //                                     cmd = "xdg-open";
        //                                 } else if (std.mem.eql(u8, current_target.os.tag.exeFileExt(std.Target.Cpu.Arch.x86_64), ".exe")) {
        //                                     cmd = "C:\\Windows\\explorer.exe";
        //                                 } else {
        //                                     cmd = "";
        //                                 }
        //
        //                                 var child = try std.process.spawn(dvui.io, .{ .argv = &.{ cmd, absolute_path } });
        //                                 _ = try child.wait(dvui.io);
        //                             }
        //                         }
        //                     }
        //                 }
        //             }
        //         }
    }

    return null;
}

test "simple test" {
    const test_gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(test_gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(test_gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
