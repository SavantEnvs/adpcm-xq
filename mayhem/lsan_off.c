// Disable LeakSanitizer at build time (fleet policy, SPEC.md §6.2 item 15). ASan and
// UBSan stay fully active; only leak detection is affected.
//
// Plain C (not lsan_off.cc/C++) deliberately: this is a pure-C project and linking the
// fuzz target via $CXX (to pull in libstdc++ for an extern "C" hook) measurably changed
// the binary's runtime memory layout enough to stop reproducing one of the two original
// mayhemheroes run 16 divide-by-zero crashers (round-2 review finding, rv-5342460914) —
// a C hook keeps the whole target linked by $CC, matching the original gcc-built binary
// as closely as this backport can.
int __lsan_is_turned_off() { return 1; }
