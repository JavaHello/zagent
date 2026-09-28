const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = std.Io.File;

const unsupported_term = [_][]const u8{ "dumb", "cons25", "emacs" };

const is_windows = builtin.os.tag == .windows;
const termios = if (!is_windows) std.posix.termios else struct { inMode: w.DWORD, outMode: w.DWORD };

pub fn isUnsupportedTerm(env: *const std.process.Environ.Map) bool {
    const env_var = env.get("TERM") orelse return false;
    return for (unsupported_term) |t| {
        if (std.ascii.eqlIgnoreCase(env_var, t))
            break true;
    } else false;
}

const w = struct {
    const windows = std.os.windows;
    pub const BOOL = windows.BOOL;
    pub const CONSOLE_SCREEN_BUFFER_INFO = windows.CONSOLE_SCREEN_BUFFER_INFO;
    pub const DWORD = windows.DWORD;
    pub const HANDLE = windows.HANDLE;
    pub const UINT = windows.UINT;
    pub const WCHAR = windows.WCHAR;
    pub const WORD = windows.WORD;
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT = @as(c_int, 0x200);
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    pub const CP_UTF8 = @as(c_int, 65001);
    pub const INPUT_RECORD = extern struct {
        EventType: w.WORD,
        _ignored: [16]u8,
    };
};

const k32 = struct {
    const kernel32 = std.os.windows.kernel32;
    pub const GetConsoleMode = kernel32.GetConsoleMode;
    pub const GetConsoleScreenBufferInfo = kernel32.GetConsoleScreenBufferInfo;
    pub const SetConsoleMode = kernel32.SetConsoleMode;
    pub const SetConsoleOutputCP = kernel32.SetConsoleOutputCP;
    pub extern "kernel32" fn SetConsoleCP(wCodePageID: w.UINT) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn PeekConsoleInputW(hConsoleInput: w.HANDLE, lpBuffer: [*]w.INPUT_RECORD, nLength: w.DWORD, lpNumberOfEventsRead: ?*w.DWORD) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn ReadConsoleW(hConsoleInput: w.HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: w.DWORD, lpNumberOfCharsRead: ?*w.DWORD, lpReserved: ?*anyopaque) callconv(.winapi) w.BOOL;
};

pub fn enableRawMode(in: File, out: File) !termios {
    if (is_windows) {
        var result: termios = .{
            .inMode = 0,
            .outMode = 0,
        };
        var irec: [1]w.INPUT_RECORD = undefined;
        var n: w.DWORD = 0;
        if (k32.PeekConsoleInputW(in.handle, &irec, 1, &n) == 0 or
            k32.GetConsoleMode(in.handle, &result.inMode) == 0 or
            k32.GetConsoleMode(out.handle, &result.outMode) == 0)
            return error.InitFailed;
        _ = k32.SetConsoleMode(in.handle, w.ENABLE_VIRTUAL_TERMINAL_INPUT);
        _ = k32.SetConsoleMode(out.handle, result.outMode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        _ = k32.SetConsoleCP(w.CP_UTF8);
        _ = k32.SetConsoleOutputCP(w.CP_UTF8);
        return result;
    } else {
        const orig = try std.posix.tcgetattr(in.handle);
        var raw = orig;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // FIXME
        // raw.cc[std.os.VMIN] = 1;
        // raw.cc[std.os.VTIME] = 0;

        try std.posix.tcsetattr(in.handle, std.posix.TCSA.FLUSH, raw);

        return orig;
    }
}

pub fn disableRawMode(in: File, out: File, orig: termios) void {
    if (is_windows) {
        _ = k32.SetConsoleMode(in.handle, orig.inMode);
        _ = k32.SetConsoleMode(out.handle, orig.outMode);
    } else {
        std.posix.tcsetattr(in.handle, std.posix.TCSA.FLUSH, orig) catch {};
    }
}

/// Reads one `\n`-terminated line into a freshly allocated slice, growing as
/// needed. Returns `null` once the stream is exhausted. `max_len` bounds the
/// result the way the old `readUntilDelimiterAlloc` limit did.
///
/// Bytes are consumed one at a time on purpose. A buffered `File.Reader` cannot
/// be used here: it outlives the call that creates it in nobody's hands, so
/// anything it read past the newline would be silently dropped. Reading the fd
/// directly also keeps consecutive calls consistent, since the seek position
/// lives on the descriptor rather than in a per-call buffer.
pub fn readLineAlloc(io: Io, allocator: std.mem.Allocator, file: File, max_len: usize) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = try read(io, file, &byte_buf);
        if (n == 0) return if (line.items.len == 0) null else try line.toOwnedSlice(allocator);
        if (byte_buf[0] == '\n') return try line.toOwnedSlice(allocator);
        if (line.items.len >= max_len) return error.StreamTooLong;
        try line.append(allocator, byte_buf[0]);
    }
}

fn getCursorPosition(io: Io, in: File, out: File) !usize {
    var file_buffer: [256]u8 = undefined;
    var file_reader = in.reader(io, &file_buffer);

    // Tell terminal to report cursor to in
    try out.writeStreamingAll(io, "\x1B[6n");

    // Read answer
    const answer = file_reader.interface.takeDelimiterExclusive('R') catch |err| switch (err) {
        error.EndOfStream, error.StreamTooLong => return error.CursorPos,
        else => return err,
    };

    // Parse answer
    if (!std.mem.startsWith(u8, "\x1B[", answer))
        return error.CursorPos;

    var iter = std.mem.splitScalar(u8, answer[2..], ';');
    _ = iter.next() orelse return error.CursorPos;
    const x = iter.next() orelse return error.CursorPos;

    return try std.fmt.parseInt(usize, x, 10);
}

fn getColumnsFallback(io: Io, in: File, out: File) !usize {
    var write_buf: [256]u8 = undefined;
    var file_writer = out.writer(io, &write_buf);
    const writer = &file_writer.interface;
    const orig_cursor_pos = try getCursorPosition(io, in, out);

    try writer.print("\x1B[999C", .{});
    const cols = try getCursorPosition(io, in, out);

    try writer.print("\x1B[{}D", .{orig_cursor_pos});
    try writer.flush();

    return cols;
}

pub fn getColumns(io: Io, in: File, out: File) !usize {
    switch (builtin.os.tag) {
        .windows => {
            var csbi: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            _ = k32.GetConsoleScreenBufferInfo(out.handle, &csbi);
            return @intCast(csbi.dwSize.X);
        },
        else => {
            var winsize: std.posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };

            const err = std.posix.system.ioctl(in.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (std.posix.errno(err) == .SUCCESS) {
                return winsize.col;
            } else {
                return try getColumnsFallback(io, in, out);
            }
        },
    }
}

pub fn clearScreen(io: Io) !void {
    try File.stderr().writeStreamingAll(io, "\x1b[H\x1b[2J");
}

pub fn beep(io: Io) !void {
    try File.stderr().writeStreamingAll(io, "\x07");
}

var utf8ConsoleBuffer = [_]u8{0} ** 10;
var utf8ConsoleReadBytes: usize = 0;

// this is needed due to a bug in win32 console: https://github.com/microsoft/terminal/issues/4551
fn readWin32Console(io: Io, file: File, buffer: []u8) !usize {
    _ = io;
    var toRead = buffer.len;
    while (toRead > 0) {
        if (utf8ConsoleReadBytes > 0) {
            const existing = @min(toRead, utf8ConsoleReadBytes);
            @memcpy(buffer[(buffer.len - toRead)..], utf8ConsoleBuffer[0..existing]);
            utf8ConsoleReadBytes -= existing;
            if (utf8ConsoleReadBytes > 0)
                std.mem.copyForwards(u8, &utf8ConsoleBuffer, utf8ConsoleBuffer[existing..]);
            toRead -= existing;
            continue;
        }
        var charsRead: w.DWORD = 0;
        var wideBuf: [2]w.WCHAR = undefined;
        if (k32.ReadConsoleW(file.handle, &wideBuf, 1, &charsRead, null) == 0)
            return 0;
        if (charsRead == 0)
            break;
        const wideBufLen: u8 = if (wideBuf[0] >= 0xD800 and wideBuf[0] <= 0xDBFF) _: {
            // read surrogate
            if (k32.ReadConsoleW(file.handle, wideBuf[1..], 1, &charsRead, null) == 0)
                return 0;
            if (charsRead == 0)
                break;
            break :_ 2;
        } else 1;
        //WideCharToMultiByte(GetConsoleCP(), 0, buf, bufLen, converted, sizeof(converted), NULL, NULL);
        utf8ConsoleReadBytes += try std.unicode.utf16LeToUtf8(&utf8ConsoleBuffer, wideBuf[0..wideBufLen]);
    }
    return buffer.len - toRead;
}

/// Like the old `File.read`, this reports end-of-stream as a 0 return so that
/// callers can keep testing `read(...) < 1`.
fn readPosix(io: Io, file: File, buffer: []u8) !usize {
    return File.readStreaming(file, io, &[_][]u8{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
}

pub const read = if (is_windows) readWin32Console else readPosix;
