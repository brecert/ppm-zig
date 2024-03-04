const std = @import("std");

const magic = [4]u8{ 'q', 'o', 'i', 'f' };
const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const ColorChannel = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    srgb_linear_alpha,
    linear,
};

pub const Header = extern struct {
    magic: [4]u8 = magic,
    width: u32,
    height: u32,
    channels: ColorChannel,
    colorspace: Colorspace = .srgb_linear_alpha,
};

pub const RGBA = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub fn init(r: u8, g: u8, b: u8, a: u8) RGBA {
        return RGBA{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn hash(rgba: RGBA) u6 {
        return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
    }

    pub fn eql(a: RGBA, b: RGBA) bool {
        return std.meta.eql(a, b);
    }
};

const IndexChunk = packed struct {
    index: u6,
    tag: u2 = 0b00,
};

const RunChunk = packed struct {
    run: u6,
    tag: u2 = 0b11,
};

const RGBChunk = extern struct {
    tag: u8 = 0b11111110,
    r: u8,
    g: u8,
    b: u8,

    pub fn init(rgba: RGBA) RGBChunk {
        return RGBChunk{
            .r = rgba.r,
            .g = rgba.g,
            .b = rgba.b,
        };
    }
};

pub const Encoder = struct {
    const Self = @This();

    seen: [64]RGBA = std.mem.zeroes([64]RGBA),
    last_pixel: RGBA = RGBA.init(0, 0, 0, 255),
    run: u6 = 0,

    pub fn encodeStart(writer: anytype, header: Header) !void {
        try writer.writeAll(&magic);
        try writer.writeInt(u32, header.width, .big);
        try writer.writeInt(u32, header.height, .big);
        try writer.writeByte(@intFromEnum(header.channels));
        try writer.writeByte(@intFromEnum(header.colorspace));
    }

    pub fn encodePixel(self: *Encoder, writer: anytype, pixel: RGBA) !void {
        if (self.last_pixel.eql(pixel)) {
            self.run += 1;
            if (self.run >= 62) {
                try writer.writeStruct(RunChunk{ .run = self.run - 1 });
                self.run = 0;
            }
        } else {
            const index = pixel.hash();

            if (self.run > 0) {
                try writer.writeStruct(RunChunk{ .run = self.run - 1 });
                self.run = 0;
            }

            if (self.seen[index].eql(pixel)) {
                try writer.writeStruct(IndexChunk{ .index = index });
            } else {
                self.seen[index] = pixel;
                try writer.writeStruct(RGBChunk.init(pixel));
            }

            self.last_pixel = pixel;
        }
    }

    pub fn encodeEnd(writer: anytype) !void {
        try writer.writeAll(&end_marker);
    }
};
