const build_options = @import("build_options");

pub const FeatureFlags = struct {
    ice_udp: bool = true,
    ice_tcp: bool = false,
    turn: bool = false,
    turn_tcp: bool = false,
    trickle: bool = true,
    consent_freshness: bool = false,
    reliable: bool = false,
    upnp: bool = false,

    pub fn from_build_options() FeatureFlags {
        return .{
            .ice_udp = build_options.ice_udp,
            .ice_tcp = build_options.ice_tcp,
            .turn = build_options.turn,
            .turn_tcp = build_options.turn_tcp,
            .trickle = build_options.trickle,
            .consent_freshness = build_options.consent,
            .reliable = build_options.reliable,
            .upnp = build_options.upnp,
        };
    }
};

test "feature flags defaults" {
    const defaults = FeatureFlags{};
    try @import("std").testing.expect(defaults.ice_udp);
    try @import("std").testing.expect(!defaults.ice_tcp);
    try @import("std").testing.expect(!defaults.turn);
    try @import("std").testing.expect(defaults.trickle);
}

test "feature flags load from build options" {
    const active = FeatureFlags.from_build_options();
    try @import("std").testing.expect(active.ice_udp);
}
