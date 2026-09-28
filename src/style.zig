//! SGR escape sequences, defined once.
//!
//! These are plain `const` slices rather than functions or `[N:0]u8` values on
//! purpose: `PROMPT` in `main.zig` and `CHOICE_PROMPT` in `agent.zig` build
//! their strings with comptime `++`, and the folding behaves differently for
//! other types.

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const UNDERLINE = "\x1b[4m";
pub const STRIKE = "\x1b[9m";

pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const MAGENTA = "\x1b[35m";
pub const CYAN = "\x1b[36m";
pub const WHITE = "\x1b[37m";
