//! Entry point.
//!
//! IT LIVES HERE RATHER THAN IN `test/` FOR ONE ZIG REASON: imports are
//! restricted to the root source file's directory, so a root at
//! `test/run.zig` cannot reach `../src`. Putting the root at the port
//! root makes both `src/` and `test/` reachable, and the actual runner
//! stays in `test/run.zig` where every other port keeps it.

pub const main = @import("test/run.zig").main;
