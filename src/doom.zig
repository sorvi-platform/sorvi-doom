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
        .core_extensions = &.{.core_v1, .audio_v1, .video_v1, .kbm_v1},
        .frontend_extensions = &.{.core_v1, .mem_v1, .audio_v1, .raster_v1},
    });
}

// TODO: add midi support
//       might be interesting to have sorvi api for midi as well :thinking:

var MEMORY: [4096 * 4096]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&MEMORY);
var doom_time: u64 = 0;

ns_since_last_update: u64 = 0,

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

fn doomGettime(out_sec: ?*i32, out_usec: ?*i32) callconv(.c) void {
    out_sec.?.* = @intCast(doom_time / std.time.ns_per_s);
    out_usec.?.* = @intCast((doom_time % std.time.ns_per_s) / std.time.ns_per_us);
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

    _ = try sorvi.audio_v1.init(.{
        .format = .s16le,
        .layout = .stereo,
        .sample_rate = c.DOOM_SAMPLERATE,
        .buffer_size = 512,
    });

    const argv: []const [*:0]const u8 = &.{"sorvi-doom"};
    c.doom_set_print(@ptrCast(&doomPrint));
    c.doom_set_malloc(&doomMalloc, &doomFree);
    c.doom_set_getenv(@ptrCast(&doomGetEnv));
    c.doom_set_file_io(@ptrCast(&doomOpen), &doomClose, &doomRead, &doomWrite, &doomSeek, &doomTell, &doomEof);
    c.doom_set_gettime(&doomGettime);
    c.doom_set_exit(&doomExit);
    c.doom_init(argv.len, @constCast(@ptrCast(argv.ptr)), 0);

    try sorvi.audio_v1.cmd(.@"resume");
}

pub fn deinit(_: *@This()) void {
}

fn toDoomKey(code: sorvi.kbm_v1.scancode_t) ?c.doom_key_t {
    return switch (code) {
        .tab => c.DOOM_KEY_TAB,
        .enter => c.DOOM_KEY_ENTER,
        .escape => c.DOOM_KEY_ESCAPE,
        .space => c.DOOM_KEY_SPACE,
        .apostrophe => c.DOOM_KEY_APOSTROPHE,
        .kp_multiply => c.DOOM_KEY_MULTIPLY,
        .comma => c.DOOM_KEY_COMMA,
        .minus => c.DOOM_KEY_MINUS,
        .period => c.DOOM_KEY_PERIOD,
        .slash => c.DOOM_KEY_SLASH,
        .@"0" => c.DOOM_KEY_0,
        .@"1" => c.DOOM_KEY_1,
        .@"2" => c.DOOM_KEY_2,
        .@"3" => c.DOOM_KEY_3,
        .@"4" => c.DOOM_KEY_4,
        .@"5" => c.DOOM_KEY_5,
        .@"6" => c.DOOM_KEY_6,
        .@"7" => c.DOOM_KEY_7,
        .@"8" => c.DOOM_KEY_8,
        .@"9" => c.DOOM_KEY_9,
        .semicolon => c.DOOM_KEY_SEMICOLON,
        .equals => c.DOOM_KEY_EQUALS,
        .square_bracket_open => c.DOOM_KEY_LEFT_BRACKET,
        .square_bracket_close => c.DOOM_KEY_RIGHT_BRACKET,
        .a => c.DOOM_KEY_A,
        .b => c.DOOM_KEY_B,
        .c => c.DOOM_KEY_C,
        .d => c.DOOM_KEY_D,
        .e => c.DOOM_KEY_E,
        .f => c.DOOM_KEY_F,
        .g => c.DOOM_KEY_G,
        .h => c.DOOM_KEY_H,
        .i => c.DOOM_KEY_I,
        .j => c.DOOM_KEY_J,
        .k => c.DOOM_KEY_K,
        .l => c.DOOM_KEY_L,
        .m => c.DOOM_KEY_M,
        .n => c.DOOM_KEY_N,
        .o => c.DOOM_KEY_O,
        .p => c.DOOM_KEY_P,
        .q => c.DOOM_KEY_Q,
        .r => c.DOOM_KEY_R,
        .s => c.DOOM_KEY_S,
        .t => c.DOOM_KEY_T,
        .u => c.DOOM_KEY_U,
        .v => c.DOOM_KEY_V,
        .w => c.DOOM_KEY_W,
        .x => c.DOOM_KEY_X,
        .y => c.DOOM_KEY_Y,
        .z => c.DOOM_KEY_Z,
        .backspace => c.DOOM_KEY_BACKSPACE,
        .left_control => c.DOOM_KEY_CTRL,
        .right_control => c.DOOM_KEY_CTRL,
        .left_arrow => c.DOOM_KEY_LEFT_ARROW,
        .up_arrow => c.DOOM_KEY_UP_ARROW,
        .right_arrow => c.DOOM_KEY_RIGHT_ARROW,
        .down_arrow => c.DOOM_KEY_DOWN_ARROW,
        .left_shift => c.DOOM_KEY_SHIFT,
        .right_shift => c.DOOM_KEY_SHIFT,
        .f1 => c.DOOM_KEY_F1,
        .f2 => c.DOOM_KEY_F2,
        .f3 => c.DOOM_KEY_F3,
        .f4 => c.DOOM_KEY_F4,
        .f5 => c.DOOM_KEY_F5,
        .f6 => c.DOOM_KEY_F6,
        .f7 => c.DOOM_KEY_F7,
        .f8 => c.DOOM_KEY_F8,
        .f9 => c.DOOM_KEY_F9,
        .f10 => c.DOOM_KEY_F10,
        .f11 => c.DOOM_KEY_F11,
        .f12 => c.DOOM_KEY_F12,
        .pause => c.DOOM_KEY_PAUSE,
        else => null,
    };
}

pub fn kbmKeyPress(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    code: sorvi.kbm_v1.scancode_t
) !void {
    if (toDoomKey(code)) |key| {
        c.doom_key_down(key);
    }
}

pub fn kbmKeyRelease(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    code: sorvi.kbm_v1.scancode_t
) !void {
    if (toDoomKey(code)) |key| {
        c.doom_key_up(key);
    }
}

fn toDoomButton(button: sorvi.kbm_v1.button_t) ?c.doom_button_t {
    return switch (button) {
        .left => c.DOOM_LEFT_BUTTON,
        .right => c.DOOM_RIGHT_BUTTON,
        .middle => c.DOOM_MIDDLE_BUTTON,
        else => null,
    };
}

pub fn kbmButtonPress(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    button: sorvi.kbm_v1.button_t
) !void {
    if (toDoomButton(button)) |btn| {
        c.doom_button_down(btn);
    }
}

pub fn kbmButtonRelease(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    button: sorvi.kbm_v1.button_t
) !void {
    if (toDoomButton(button)) |btn| {
        c.doom_button_up(btn);
    }
}

pub fn kbmMouseMotion(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    rel: sorvi.kbm_v1.relative_t,
) !void {
    // disable mouse as it would need pointer locking to be good
    if (true) return;
    const SCALE = 100.0;
    c.doom_mouse_move(@intFromFloat(@round(rel.x * SCALE)), @intFromFloat(@round(rel.y * SCALE)));
}

pub fn kbmMouseScroll(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    _: sorvi.kbm_v1.relative_t,
) !void {
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
            dst[dst_index..][0..4].* = @bitCast(@shuffle(u8, rgba, undefined, [_]i32{ 2, 1, 0, 3 }));
        }
    }
}

// the puredoom author does not know that foo() translates to foo(i32)
// while using `c.doom_force_update` works on native, wasm is more strict
extern fn doom_force_update() callconv(.c) void;
extern fn doom_get_sound_buffer() callconv(.c) [*]i16;

pub fn videoTick(self: *@This(), frame: sorvi.video_v1.frame_t) !u64 {
    const target_rate: u64 = std.time.ns_per_s / 35;
    doom_time += frame.time_ns;
    self.ns_since_last_update += frame.time_ns;
    if (target_rate > self.ns_since_last_update) {
        // Frontend scheduled us too fast
        return target_rate - self.ns_since_last_update;
    }
    while (self.ns_since_last_update >= target_rate) {
        doom_force_update();
        self.ns_since_last_update -= target_rate;
    }
    const buffer = try sorvi.raster_v1.acquire_buffer();
    const doom_len = DOOM_WIDTH * DOOM_HEIGHT * 4;
    const doom_pixels = c.doom_get_framebuffer(4)[0..doom_len];
    resizeNearestRgbaToBgra(doom_pixels, buffer.ptr[0..buffer.len], DOOM_WIDTH, DOOM_HEIGHT, frame.w, frame.h);
    sorvi.raster_v1.damage(&.{.{.x = 0, .y = 0, .w = frame.w, .h = frame.h}});
    return target_rate - self.ns_since_last_update;
}

pub fn audioTick(_: *@This(), u8_buffer: []u8) !void {
    const s16_buffer = std.mem.bytesAsSlice(i16, u8_buffer);
    const doom_buffer: []i16 = doom_get_sound_buffer()[0..1024];
    const min_len = @min(s16_buffer.len, doom_buffer.len);
    @memcpy(s16_buffer[0..min_len], doom_buffer[0..min_len]);
}
