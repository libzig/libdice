pub const FeatureFlags = struct {
    ice_udp: bool = true,
    ice_tcp: bool = false,
    turn: bool = false,
    turn_tcp: bool = false,
    trickle: bool = true,
    consent_freshness: bool = false,
    reliable: bool = false,
    upnp: bool = false,
};

test "feature flags defaults" {
    const defaults = FeatureFlags{};
    try @import("std").testing.expect(defaults.ice_udp);
    try @import("std").testing.expect(!defaults.ice_tcp);
    try @import("std").testing.expect(!defaults.turn);
    try @import("std").testing.expect(defaults.trickle);
}
