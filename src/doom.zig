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
        .core_extensions = &.{ .core_v1, .audio_v1, .video_v1, .kbm_v1 },
        .frontend_extensions = &.{ .core_v1, .mem_v1, .audio_v1, .raster_v1 },
    });
}

// TODO: add midi support
//       might be interesting to have sorvi api for midi as well :thinking:

var MEMORY: [4096 * 4096]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&MEMORY);
var doom_time: u64 = 0;

ns_since_last_update: u64 = 0,
mouse_motion: sorvi.kbm_v1.relative_t = .{ .x = 0, .y = 0 },
mouse_locked: bool = false,
fullscreen: bool = false,

fn doomPrint(msg_raw: [*:0]const u8) callconv(.c) void {
    const msg = std.mem.span(msg_raw);
    sorvi.core_v1.tty_writev(&.{.{ .ptr = msg.ptr, .len = msg.len }});
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

fn doomExit(_: i32) callconv(.c) void {
    sorvi.core_v1.exit();
}

const DOOM_WIDTH = 320;
const DOOM_HEIGHT = 200;

pub fn core_v1_init(_: *@This()) !void {
    try sorvi.raster_v1.init(.{
        .format = .xbgr8888,
        .scaling = &.{
            .raster_w = DOOM_WIDTH,
            .raster_h = DOOM_HEIGHT,
            .scale = .integer,
            .filter = .nearest,
        },
        .direct = false,
    });

    try sorvi.video_v1.configure(.{
        .w = DOOM_WIDTH * 2,
        .h = DOOM_HEIGHT * 2,
        .flags = .{ .border = true },
        .presentation = .dont_care,
        .mode = .default,
    });

    _ = try sorvi.audio_v1.init(.{
        .format = .s16le,
        .layout = .stereo,
        .sample_rate = c.DOOM_SAMPLERATE,
        .buffer_size = 512,
        .direct = false,
    });

    c.doom_set_default_int("key_up", c.DOOM_KEY_W);
    c.doom_set_default_int("key_down", c.DOOM_KEY_S);
    c.doom_set_default_int("key_strafeleft", c.DOOM_KEY_A);
    c.doom_set_default_int("key_straferight", c.DOOM_KEY_D);
    c.doom_set_default_int("key_use", c.DOOM_KEY_E);
    c.doom_set_default_int("mouse_move", 0);
    c.doom_set_default_int("screenblocks", 10);

    const argv: []const [*:0]const u8 = &.{"sorvi-doom"};
    c.doom_set_print(@ptrCast(&doomPrint));
    c.doom_set_malloc(&doomMalloc, &doomFree);
    c.doom_set_getenv(@ptrCast(&doomGetEnv));
    c.doom_set_file_io(@ptrCast(&doomOpen), &doomClose, &doomRead, &doomWrite, &doomSeek, &doomTell, &doomEof);
    c.doom_set_gettime(&doomGettime);
    c.doom_set_exit(&doomExit);
    c.doom_init(argv.len, @ptrCast(@constCast(argv.ptr)), 0);

    try sorvi.audio_v1.cmd(.@"resume");
}

pub fn core_v1_deinit(_: *@This()) void {}

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

pub fn kbm_v1_key_press(self: *@This(), _: u64, _: sorvi.kbm_v1.absolute_t, _: sorvi.kbm_v1.modifiers_t, code: sorvi.kbm_v1.scancode_t) !void {
    if (toDoomKey(code)) |key| {
        c.doom_key_down(key);
    }
    switch (code) {
        .escape => {
            sorvi.kbm_v1.unlock_pointer();
            self.mouse_locked = false;
        },
        .f12 => {
            self.fullscreen = !self.fullscreen;
            if (self.fullscreen) {
                try sorvi.video_v1.configure(.{
                    .w = DOOM_WIDTH * 2,
                    .h = DOOM_HEIGHT * 2,
                    .flags = .{ .border = false },
                    .presentation = .fullscreen,
                    .mode = .default,
                });
            } else {
                try sorvi.video_v1.configure(.{
                    .w = DOOM_WIDTH * 2,
                    .h = DOOM_HEIGHT * 2,
                    .flags = .{ .border = true },
                    .presentation = .dont_care,
                    .mode = .default,
                });
            }
        },
        else => {},
    }
}

pub fn kbm_v1_key_release(_: *@This(), _: u64, _: sorvi.kbm_v1.absolute_t, _: sorvi.kbm_v1.modifiers_t, code: sorvi.kbm_v1.scancode_t) !void {
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

pub fn kbm_v1_button_press(self: *@This(), _: u64, _: sorvi.kbm_v1.absolute_t, _: sorvi.kbm_v1.modifiers_t, button: sorvi.kbm_v1.button_t) !void {
    if (!self.mouse_locked) {
        sorvi.kbm_v1.lock_pointer();
        self.mouse_locked = true;
        // do not send the button to doom unless we are locked
        // this prevents accidental firing
    } else {
        if (toDoomButton(button)) |btn| {
            c.doom_button_down(btn);
        }
    }
}

pub fn kbm_v1_button_release(_: *@This(), _: u64, _: sorvi.kbm_v1.absolute_t, _: sorvi.kbm_v1.modifiers_t, button: sorvi.kbm_v1.button_t) !void {
    if (toDoomButton(button)) |btn| {
        c.doom_button_up(btn);
    }
}

pub fn kbm_v1_mouse_motion(
    self: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    rel: sorvi.kbm_v1.relative_t,
) !void {
    if (!self.mouse_locked) return;
    self.mouse_motion.x += rel.x;
    self.mouse_motion.y += rel.y;
}

pub fn kbm_v1_mouse_scroll(
    _: *@This(),
    _: u64,
    _: sorvi.kbm_v1.absolute_t,
    _: sorvi.kbm_v1.modifiers_t,
    _: sorvi.kbm_v1.relative_t,
) !void {}

// the puredoom author does not know that foo() translates to foo(i32)
// while using `c.doom_force_update` works on native, wasm is more strict
extern fn doom_force_update() callconv(.c) void;
extern fn doom_get_sound_buffer() callconv(.c) [*]i16;

pub fn video_v1_tick(self: *@This(), frame: sorvi.video_v1.frame_t) !u64 {
    std.debug.assert(frame.w == DOOM_WIDTH and frame.h == DOOM_HEIGHT);
    const target_rate: u64 = std.time.ns_per_s / 35;
    doom_time += frame.time_ns;

    self.ns_since_last_update += frame.time_ns;
    if (target_rate > self.ns_since_last_update) {
        // Frontend scheduled us too fast
        return target_rate - self.ns_since_last_update;
    }

    const SCALE = 3.0;
    c.doom_mouse_move(@intFromFloat(@round(self.mouse_motion.x * SCALE)), @intFromFloat(@round(self.mouse_motion.y * SCALE)));
    self.mouse_motion = .{ .x = 0, .y = 0 };

    while (self.ns_since_last_update >= target_rate) {
        doom_force_update();
        self.ns_since_last_update -= target_rate;
    }

    const buffer = try sorvi.raster_v1.acquire_buffer();
    const doom_len = DOOM_WIDTH * DOOM_HEIGHT * 4;
    const doom_pixels = c.doom_get_framebuffer(4)[0..doom_len];
    @memcpy(buffer, doom_pixels);
    sorvi.raster_v1.damage(&.{.{ .x = 0, .y = 0, .w = frame.w, .h = frame.h }});
    return target_rate - self.ns_since_last_update;
}

pub fn video_v1_configuration(_: *@This(), _: sorvi.video_v1.configuration_t, _: u16, _: u16) void {}

pub fn audio_v1_tick(_: *@This(), u8_buffer: []u8) !void {
    const s16_buffer = std.mem.bytesAsSlice(i16, u8_buffer);
    const doom_buffer: []i16 = doom_get_sound_buffer()[0..1024];
    const min_len = @min(s16_buffer.len, doom_buffer.len);
    @memcpy(s16_buffer[0..min_len], doom_buffer[0..min_len]);
}
