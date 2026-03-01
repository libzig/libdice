pub const NominationMode = enum {
    regular,
    aggressive,
};

pub fn should_nominate_on_success(mode: NominationMode, requested_nomination: bool) bool {
    return switch (mode) {
        .aggressive => true,
        .regular => requested_nomination,
    };
}

test "nomination mode decision" {
    try @import("std").testing.expect(!should_nominate_on_success(.regular, false));
    try @import("std").testing.expect(should_nominate_on_success(.regular, true));
    try @import("std").testing.expect(should_nominate_on_success(.aggressive, false));
}
