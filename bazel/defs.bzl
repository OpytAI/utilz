"""Public macros for embedding utilz with a consumer-supplied box filter."""

load("@rules_zig//zig:defs.bzl", "zig_library")

def utilz_library(name, build_options, visibility = None):
    """zig_library of utilz sources with a consumer-supplied build_options.

    Instantiated in the *caller* package. `build_options` must be a
    zig_library with import_name = \"build_options\" (tier/set/all_tiers/exclude).
    """
    zig_library(
        name = name,
        srcs = ["@utilz//src:srcs"],
        main = "@utilz//src:root.zig",
        import_name = "utilz",
        deps = [build_options],
        visibility = visibility,
    )
