//! THE ROOT A CONSUMER IMPORTS.
//!
//! Zig restricts a module's imports to the directory of its root source
//! file, so a host that takes this port as a named module
//! (`--dep plugin ... -Mplugin=<checkout>/zig/src/plugin.zig`) reaches
//! every file in `src/` through this one and through nothing else. The
//! test driver in `../test/` imports the files directly, because it
//! lives beside them; a consumer cannot, and this is what it gets
//! instead — the same role `index.ts` plays for the typescript port.
//!
//! What a host needs: the host and its catalog (`host`, `catalog`), the
//! dynamic value every option and export is made of (`value`), the
//! error mechanism a definition raises through (`types`), and the four
//! pure ref functions (`ref`).

pub const value = @import("value.zig");
pub const types = @import("types.zig");
pub const ref = @import("ref.zig");
pub const catalog = @import("catalog.zig");
pub const host = @import("host.zig");
pub const version = @import("version.zig");
pub const capability = @import("capability.zig");
pub const config = @import("config.zig");
