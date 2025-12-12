const std = @import("std");
const sorvi = @import("sorvi");
const c = @import("puredoom");
const doom1 = @embedFile("doom1.wad");
const log = std.log.scoped(.sorvi_doom);

pub const std_options: std.Options = .{
    .logFn = sorvi.defaultLog,
    .queryPageSize = sorvi.queryPageSize,
    .page_size_max = sorvi.page_size_max,
    .log_level = .debug,
};

pub const os = sorvi.os;
pub const panic = std.debug.FullPanic(sorvi.defaultPanic);

comptime {
    sorvi.init(@This(), .{
        .id = "org.sorvi.port.doom",
        .name = "doom",
        .version = "0.0.0",
        .core_extensions = &.{.core_v1, .audio_v1, .video_v1},
        .frontend_extensions = &.{.core_v1, .mem_v1, .audio_v1, .raster_v1},
    });
}

// TODO: add input
// TODO: add midi support
//       might be interesting to have sorvi api for midi as well :thinking:

var MEMORY: [4096 * 4096]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&MEMORY);

accumulator: f64 = 0,

fn doomPrint(msg_raw: [*:0]const u8) callconv(.c) void {
    const msg = std.mem.span(msg_raw);
    _ = sorvi.fs_v1.writev(.tty, &.{.{.ptr = msg.ptr, .len = msg.len}}) catch {};
}

fn doomMalloc(size: i32) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    return fba.allocator().rawAlloc(@intCast(size), .of(std.c.max_align_t), @returnAddress());
}

fn doomFree(_: ?*anyopaque) callconv(.c) void {
    // just pray we never run out
}

fn doomGetEnv(key_str: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const Key = enum {
        DOOMWADDIR,
        HOME,
    };
    const key = std.meta.stringToEnum(Key, std.mem.span(key_str)) orelse return null;
    return switch (key) {
        .DOOMWADDIR, .HOME => "",
    };
}

const File = struct {
    const What = enum {
        @"doom1.wad",
    };
    offset: usize,
    what: What,
};

fn doomOpen(path: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (std.mem.eql(u8, std.mem.span(path), "/doom1.wad")) {
        const f = fba.allocator().create(File) catch return null;
        f.* = .{
            .offset = 0,
            .what = .@"doom1.wad",
        };
        return f;
    }
    return null;
}

fn doomClose(ptr: ?*anyopaque) callconv(.c) void {
    const file: *File = @ptrCast(@alignCast(ptr orelse return));
    fba.allocator().destroy(file);
}

fn doomRead(ptr: ?*anyopaque, buf_raw: ?*anyopaque, ilen: i32) callconv(.c) i32 {
    const file: *File = @ptrCast(@alignCast(ptr.?));
    const len: usize = @intCast(ilen);
    const buf: [*]u8 = @ptrCast(buf_raw);
    @memcpy(buf[0..len], doom1[file.offset..][0..len]);
    file.offset += len;
    return ilen;
}

fn doomWrite(_: ?*anyopaque, _: ?*const anyopaque, _: i32) callconv(.c) i32 {
    @panic("fixme");
}

fn doomSeek(ptr: ?*anyopaque, off: i32, mode: c.doom_seek_t) callconv(.c) i32 {
    const file: *File = @ptrCast(@alignCast(ptr.?));
    var offset: i32 = @intCast(file.offset);
    switch (mode) {
        c.DOOM_SEEK_CUR => offset += off,
        c.DOOM_SEEK_END => offset = @as(i32, @intCast(doom1.len)) + off,
        c.DOOM_SEEK_SET => offset = off,
        else => return -1,
    }
    file.offset = @intCast(offset);
    return 0;
}

fn doomTell(ptr: ?*anyopaque) callconv(.c) i32 {
    const file: *File = @ptrCast(@alignCast(ptr.?));
    return @intCast(file.offset);
}

fn doomEof(ptr: ?*anyopaque) callconv(.c) i32 {
    const file: *File = @ptrCast(@alignCast(ptr.?));
    return @intFromBool(file.offset >= doom1.len);
}

fn doomExit(code: i32) callconv(.c) void {
    std.debug.panic("exit with code: {}", .{code});
}

const DOOM_WIDTH = 320;
const DOOM_HEIGHT = 200;

pub fn init(_: *@This()) !void {
    for (sorvi.raster_v1.query_configuration()) |cfg| {
        if (cfg.format == .argb8888 or cfg.format == .xrgb8888) {
            try sorvi.raster_v1.init(cfg);
            break;
        }
    }

    try sorvi.audio_v1.init(.{
        .format = .s16le,
        .layout = .stereo,
        .sample_rate = c.DOOM_SAMPLERATE,
    });

    const argv: []const [*:0]const u8 = &.{"sorvi-doom"};
    c.doom_set_print(@ptrCast(&doomPrint));
    c.doom_set_malloc(&doomMalloc, &doomFree);
    c.doom_set_getenv(@ptrCast(&doomGetEnv));
    c.doom_set_file_io(@ptrCast(&doomOpen), &doomClose, &doomRead, &doomWrite, &doomSeek, &doomTell, &doomEof);
    c.doom_set_exit(&doomExit);
    c.doom_init(argv.len, @constCast(@ptrCast(argv.ptr)), 0);

    try sorvi.audio_v1.cmd(.@"resume");
}

pub fn deinit(_: *@This()) void {
}

pub fn resizeNearestRgbaToBgra(
    src: []const u8,
    dst: []u8,
    sw: usize,
    sh: usize,
    dw: usize,
    dh: usize,
) void {
    // TODO: vectorize this more
    const x_ratio = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
    const y_ratio = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
    for (0..dh) |dy| {
        const syf: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(dy)) * y_ratio));
        const sy = @min(syf, sh - 1);
        for (0..dw) |dx| {
            const sxf: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(dx)) * x_ratio));
            const sx = @min(sxf, sw - 1);
            const src_index = (sy * sw + sx) * 4;
            const dst_index = (dy * dw + dx) * 4;
            const rgba: @Vector(4, u8) = @bitCast(src[src_index..][0..4].*);
            const argb: [4]u8 = @bitCast(@shuffle(u8, rgba, undefined, [_]i32{ 2, 1, 0, 3 }));
            @memcpy(dst[dst_index..][0..4], &argb);
        }
    }
}

// the puredoom author does not know that foo() translates to foo(i32)
// while using `c.doom_force_update` works on native, wasm is more strict
extern fn doom_force_update() callconv(.c) void;
extern fn doom_get_sound_buffer() callconv(.c) [*]i16;

pub fn videoTick(self: *@This(), frame: sorvi.video_v1.frame_t) !void {
    const dt: f64 = 1.0 / 35.0;
    const delta: f64 = @as(f64, @floatFromInt(frame.time_ns)) / std.time.ns_per_s;
    self.accumulator += delta;
    if (self.accumulator < dt) return;
    while (self.accumulator >= dt) {
        doom_force_update();
        self.accumulator -= dt;
    }
    const buffer = try sorvi.raster_v1.acquire_buffer();
    const doom_len = DOOM_WIDTH * DOOM_HEIGHT * 4;
    const doom_pixels = c.doom_get_framebuffer(4)[0..doom_len];
    resizeNearestRgbaToBgra(doom_pixels, buffer.ptr[0..buffer.len], DOOM_WIDTH, DOOM_HEIGHT, frame.w, frame.h);
    sorvi.raster_v1.damage(&.{.{.x = 0, .y = 0, .w = frame.w, .h = frame.h}});
}

pub fn audioTick(_: *@This(), u8_buffer: []u8) !void {
    const s16_buffer = std.mem.bytesAsSlice(i16, u8_buffer);
    const doom_buffer: []i16 = doom_get_sound_buffer()[0..1024];
    const min_len = @min(s16_buffer.len, doom_buffer.len);
    @memcpy(s16_buffer[0..min_len], doom_buffer[0..min_len]);
}
