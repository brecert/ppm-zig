const std = @import("std");

pub const Lock = enum(u16) { Unlocked, Locked };

pub const Header = extern struct {
    magic: [4]u8,
    animation_data_size: u32,
    sound_data_size: u32,
    frame_count: u16,
    format_version: u16,
};

pub const Metadata = extern struct {
    lock: Lock,
    thumbnail_index: u16,
    original_author: [11]u16,
    previous_author: [11]u16,
    current_author: [11]u16,
    previous_author_id: [8]u8,
    current_author_id: [8]u8,
    original_filename: [18]u8,
    current_filename: [18]u8,
    original_author_id: [8]u8,
    file_id: [8]u8,
    last_modified: u32 align(1),
    _padding: u16,
};

pub const Thumbnail = extern struct {
    pub const width = 64;
    pub const height = 48;
    pub const size = (width * height) / 2;

    data: [size]u8,
};

pub const AnimationHeader = packed struct {
    table_size: u16,
    _padding: u32,
    flags: AnimationFlags,

    pub const AnimationFlags = packed struct {
        _unknown_1: u1,
        loop: u1,
        _unknown_2: u3,
        layer_1_visible: u1,
        layer_2_visible: u2,
        _unknown_3: u8,
    };
};

pub const PaperColor = enum(u1) {
    Black,
    White,

    pub fn hexColor(self: @This()) u24 {
        return switch (self) {
            .Black => 0x0E0E0E,
            .White => 0xFFFFFF,
        };
    }

    pub fn inverse(self: @This()) @This() {
        return switch (self) {
            .Black => .White,
            .White => .Black,
        };
    }
};

pub const PenColor = enum(u2) {
    InverseOfPaperUnused, // todo: better name
    InverseOfPaper,
    Red,
    Blue,

    pub fn hexColor(self: @This(), background: PaperColor) u24 {
        return switch (self) {
            .InverseOfPaperUnused, .InverseOfPaper => background.inverse().hexColor(),
            .Red => 0xFF2A2A,
            .Blue => 0x0A39FF,
        };
    }
};

pub const FrameHeader = packed struct {
    paper_color: PaperColor,
    layer_1_pen: PenColor,
    layer_2_pen: PenColor,
    translated: u2,
    is_keyframe: bool,
};

pub const Translation = extern struct {
    x: i8,
    y: i8,
};

const FrameLineEncoding = enum(u2) {
    NoData,
    Compressed,
    CompressedDefaultOne,
    Uncompressed,
};

pub const Frame = struct {
    pub const width = 256;
    pub const height = 192;

    header: FrameHeader,
    layers: [2]Layer,
    translation: ?Translation,
};

pub const Layer = struct {
    const Self = @This();

    const width = Frame.width;
    const height = Frame.height;

    bitmap: [height][width]bool,

    fn xor(self: *Self, other: Self, translation: ?Translation) void {
        if (translation) |t| {
            _ = t;
            @panic("translation xor unimplemented");
            // const tx = @as(i16, t.x);
            // const ty = @as(i16, t.y);

            // const xMinA = @max(0, tx);
            // const xMaxA: u16 = @intCast(@min(width + ty, width));

            // const xMinB = @max(0, -tx);
            // const xMaxB: u16 = @intCast(@min(width - tx, width));

            // const yMinA = @max(0, ty);
            // const yMaxA: u16 = @intCast(@min(height + ty, height));

            // const yMinB = @max(0, -ty);
            // const yMaxB: u16 = @intCast(@min(height - ty, height));

            // for (yMinA..yMaxA, yMinB..yMaxB) |yA, yB| {
            //     for (xMinA..xMaxA, xMinB..xMaxB) |xA, xB| {
            //         self.bitmap[yA][xA] = self.bitmap[yA][xA] != other.bitmap[yB][xB];
            //     }
            // }
        } else {
            for (0..height) |y| {
                const vecA: @Vector(width, bool) = self.bitmap[y];
                const vecB: @Vector(width, bool) = other.bitmap[y];
                self.bitmap[y] = vecA != vecB;

                // for (0..width) |x| {
                //     self.bitmap[y][x] = self.bitmap[y][x] != other.bitmap[y][x];
                // }
            }
        }
    }
};

pub const FrameDecoder = struct {
    const Self = @This();

    const layer_count = 2;

    header: Header,
    metadata: Metadata,
    animation_header: AnimationHeader,
    frame_offsets: []align(1) u32,
    frame_data: []u8,
    previous_layers: ?[2]Layer = null,
    previous_frame: ?usize = null,

    pub fn decodeHeader(self: *Self, frame: usize) !FrameHeader {
        return @bitCast(self.frame_data[self.frame_offsets[frame]]);
    }

    // todo: decodeFromPreviousKeyframe(self: *Self, frame: usize) !Frame
    // if (frame != 0 and self.previous_frame != frame - 1 and !header.is_keyframe) {
    //     var keyframe: usize = frame - 1;
    //     while (true) : (keyframe -= 1) {
    //         const previous_header = try self.decodeHeader(keyframe);
    //         if (previous_header.is_keyframe or keyframe == 0) {
    //             break;
    //         }
    //     }

    //     for (keyframe..frame) |previous_frame_index| {
    //         const previous_frame = try self.decodeFrame(previous_frame_index);
    //         self.previous_layers = previous_frame.layers;
    //     }
    // }

    pub fn decodeFrame(self: *Self, frame: usize) !Frame {
        const offset = self.frame_offsets[frame];
        var stream = std.io.fixedBufferStream(self.frame_data[offset..]);
        var reader = stream.reader();

        const header = try reader.readStruct(FrameHeader);
        const translation = if (header.translated != 0) try reader.readStruct(Translation) else null;

        var line_encodings: [2][Frame.height]FrameLineEncoding = .{
            undefined,
            undefined,
        };

        for (0..layer_count) |layer| {
            inline for (0..48) |byte| {
                const data = try reader.readByte();
                inline for (0..4) |bit| {
                    line_encodings[layer][(byte * 4) + bit] = @enumFromInt((data >> bit * 2) & 0b00000011);
                }
            }
        }

        var layers: [2]Layer = .{
            .{ .bitmap = .{.{false} ** 256} ** 192 },
            .{ .bitmap = .{.{false} ** 256} ** 192 },
        };

        for (line_encodings, 0..) |encodings, l| {
            for (encodings, 0..) |encoding, y| {
                switch (encoding) {
                    .NoData => continue,
                    .Uncompressed => {
                        for (0..32) |x| {
                            const chunk = try reader.readByte();
                            inline for (0..8) |bit| {
                                layers[l].bitmap[y][(x * 8) + bit] = (chunk >> bit & 0b1) != 0;
                            }
                        }
                    },
                    .Compressed, .CompressedDefaultOne => {
                        if (encoding == .CompressedDefaultOne) {
                            @memset(&layers[l].bitmap[y], true);
                        }
                        var line_flags = try reader.readInt(u32, .big);
                        var x: usize = 0;
                        while (line_flags != 0) : (line_flags <<= 1) {
                            if (line_flags & 0x80000000 != 0) {
                                const chunk = try reader.readByte();
                                inline for (0..8) |bit| {
                                    layers[l].bitmap[y][x] = ((chunk >> bit) & 0x1) != 0;
                                    x += 1;
                                }
                            } else {
                                x += 8;
                            }
                        }
                    },
                }
            }
        }

        // handle diffing
        if (!header.is_keyframe) {
            for (0..2) |l| {
                layers[l].xor(self.previous_layers.?[l], translation);
            }
        }

        self.previous_layers = layers;
        self.previous_frame = frame;

        return Frame{
            .header = header,
            .layers = layers,
            .translation = translation,
        };
    }
};
