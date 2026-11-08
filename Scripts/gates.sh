#!/bin/bash
# ZLMod — artifact verification gates. Fails the build on any violation.
set -euo pipefail

DYLIB="${1:-build/libZLMod.dylib}"
FAIL=0

fail() { echo "GATE FAIL: $1"; FAIL=1; }
pass() { echo "GATE OK:   $1"; }

[ -f "$DYLIB" ] || { fail "missing $DYLIB"; exit 1; }

# 1. Architecture — arm64 thin, dynamic library.
file "$DYLIB" | grep -q "Mach-O 64-bit dynamically linked shared library arm64" \
  && pass "arm64 dylib" || fail "not an arm64 dynamically linked shared library"

# 2. Dependencies — system frameworks + executable-relative path only. No substrate, no ellekit.
DEPS=$(otool -L "$DYLIB" | tail -n +2 | awk '{print $1}')
echo "$DEPS" | grep -Ev '^(/System/Library/|/usr/lib/|@executable_path/|@rpath/|@loader_path/)' \
  | grep -q . && fail "unexpected dependency: $(echo "$DEPS" | grep -Ev '^(/System/Library/|/usr/lib/|@executable_path/|@rpath/|@loader_path/)' | head -1)" \
  || pass "dependencies clean"
echo "$DEPS" | grep -qiE 'substrate|ellekit|cydia' && fail "hook-injection library linked" || pass "no substrate/ellekit"

# 3. Install name.
otool -D "$DYLIB" 2>/dev/null | tail -n +2 | grep -q "@rpath/libZLMod.dylib" \
  && pass "install_name @rpath/libZLMod.dylib" \
  || fail "install_name missing or wrong"

# 4. Platform + deployment target.
LC_BUILD=$(otool -l "$DYLIB" | grep -A5 LC_BUILD_VERSION)
echo "$LC_BUILD" | grep -q "minos 15.1" && pass "minos 15.1" || fail "minos is not 15.1"
echo "$LC_BUILD" | grep -qiE "platform (2|IOS)" && pass "platform iOS" || fail "platform is not iOS"

# 5. No strong reference to iOS 26-only classes (must be runtime-guarded via NSClassFromString).
nm -m "$DYLIB" | grep "undefined" | grep -q "_OBJC_CLASS_\$_UIGlassEffect" \
  && fail "strong undefined reference to UIGlassEffect (use NSClassFromString)" \
  || pass "UIGlassEffect runtime-guarded"

# 6. Signature present.
codesign -dv "$DYLIB" 2>&1 | grep -q "Identifier=" && pass "codesigned" || fail "not codesigned"

# 7. Non-empty, real content.
SIZE=$(stat -f%z "$DYLIB" 2>/dev/null || stat -c%s "$DYLIB")
[ "$SIZE" -gt 20000 ] && pass "artifact size ${SIZE}B" || fail "artifact suspiciously small (${SIZE}B)"

exit $FAIL
