//! Default box filter: every landed roster row is visible.

pub const SetKind = enum { full, min };
pub const tier: []const u8 = "full";
pub const set: SetKind = .full;
pub const all_tiers: bool = true;
pub const exclude: []const u8 = "";
