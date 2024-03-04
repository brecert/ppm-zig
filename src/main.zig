const std = @import("std");
const ppm = @import("ppm.zig");
const qoi = @import("qoi.zig");

const RGBA = qoi.RGBA;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    const ppm_path = args[1];

    const stdout = std.io.getStdOut().writer();

    var cwd = std.fs.cwd();
    const file = try cwd.readFileAlloc(allocator, ppm_path, 1_000_000);
    var stream = std.io.fixedBufferStream(file);
    var reader = stream.reader();

    const header = try reader.readStruct(ppm.Header);
    const metadata = try reader.readStruct(ppm.Metadata);
    _ = try reader.readStruct(ppm.Thumbnail);
    const animation_header = try reader.readStruct(ppm.AnimationHeader);

    var frame_offsets = try allocator.alloc(u32, (animation_header.table_size / @sizeOf(u32)));
    defer allocator.free(frame_offsets);

    for (0..frame_offsets.len) |i| {
        frame_offsets[i] = try reader.readInt(u32, .little);
    }

    const frame_data = try allocator.alloc(u8, header.animation_data_size - @sizeOf(ppm.AnimationHeader) - frame_offsets.len);
    _ = try reader.readAll(frame_data);

    const sound_data = try allocator.alloc(u8, header.sound_data_size);
    _ = try reader.readAll(sound_data);

    var decoder = ppm.FrameDecoder{
        .header = header,
        .metadata = metadata,
        .animation_header = animation_header,
        .frame_offsets = frame_offsets,
        .frame_data = frame_data,
    };

    const Mode = enum { qoi, hash };
    const mode = Mode.qoi;

    switch (mode) {
        .qoi => {
            for (0..header.frame_count + 1) |i| {
                const output_dir = args[2];

                const path = try std.fmt.allocPrint(allocator, "{s}/frame_{}.qoi", .{ output_dir, i });
                var image = try cwd.createFile(path, .{});
                defer image.close();
                const writer = image.writer();

                try stdout.print("{s}\n", .{path});

                const frame = try decoder.decodeFrame(i);
                var encoder = qoi.Encoder{};

                try qoi.Encoder.encodeStart(writer, .{
                    .width = ppm.Frame.width,
                    .height = ppm.Frame.height,
                    .channels = .rgb,
                });

                const colors = [3]u32{
                    frame.header.paper_color.hexColor(),
                    frame.header.layer_1_pen.hexColor(frame.header.paper_color),
                    frame.header.layer_2_pen.hexColor(frame.header.paper_color),
                };

                for (frame.layers[0].bitmap, frame.layers[1].bitmap) |row_1, row_2| {
                    for (row_1, row_2) |pixel_1, pixel_2| {
                        const color = if (pixel_1) colors[1] else if (pixel_2) colors[2] else colors[0];
                        try encoder.encodePixel(writer, hexToRGBA(color));
                    }
                }

                try qoi.Encoder.encodeEnd(writer);
            }
        },
        .hash => {
            var hasher = std.hash.XxHash64.init(0);
            for (0..header.frame_count + 1) |i| {
                const frame = try decoder.decodeFrame(i);

                const colors = [3]u32{
                    frame.header.paper_color.hexColor(),
                    frame.header.layer_1_pen.hexColor(frame.header.paper_color),
                    frame.header.layer_2_pen.hexColor(frame.header.paper_color),
                };

                for (frame.layers[0].bitmap, frame.layers[1].bitmap) |row_1, row_2| {
                    for (row_1, row_2) |pixel_1, pixel_2| {
                        const color = if (pixel_1) colors[1] else if (pixel_2) colors[2] else colors[0];
                        std.hash.autoHash(&hasher, color);
                    }
                }
            }
            try stdout.print("{}\n", .{hasher.final()});
        },
    }
}

fn hexToRGBA(hex: u32) RGBA {
    return .{
        .r = @intCast(((hex >> 16) & 0xFF)),
        .g = @intCast(((hex >> 8) & 0xFF)),
        .b = @intCast(((hex >> 0) & 0xFF)),
        .a = 0xFF,
    };
}

test "hex_to_rgba_works" {
    try std.testing.expectEqual(hexToRGBA(0xFF0000), RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(hexToRGBA(0xFF2A2A), RGBA{ .r = 255, .g = 42, .b = 42, .a = 255 });
}
