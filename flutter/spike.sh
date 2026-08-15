#!/usr/bin/env bash
# ClipHist Flutter-migration spike runner — one-shot compile validation.
#
# Validates the three go/no-go criteria at the *compilation* level:
#   A  FRB round-trip + StreamSink event stream  (flutter/rust + Dart)
#   B  window_manager + tray_manager on Linux     (flutter/lib/main.dart)
#   C  evdev-helper independent binary compiles   (rust/evdev-helper)
#
# Runtime GUI checks (window dance, tray menu clicks, real-machine double-tap,
# stream cadence) are manual — run `flutter run -d linux` after this passes and
# follow docs/migration/spike-results.md.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

PASS=0; FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== A/B: FRB codegen generate =="
if (cd "$REPO/flutter" && flutter_rust_bridge_codegen generate >/tmp/spike-frb.log 2>&1); then
  ok "frb codegen generate"
else
  no "frb codegen generate (see /tmp/spike-frb.log)"
fi

echo "== A/B: flutter build linux (compiles Dart + Rust crate) =="
if (cd "$REPO/flutter" && flutter build linux --debug >/tmp/spike-flutter.log 2>&1); then
  ok "flutter build linux"
else
  no "flutter build linux (see /tmp/spike-flutter.log)"
fi

echo "== C: evdev-helper independent binary =="
if (cd "$REPO/rust/evdev-helper" && cargo build >/tmp/spike-evdev.log 2>&1); then
  ok "cargo build evdev-helper"
else
  no "cargo build evdev-helper (see /tmp/spike-evdev.log)"
fi

echo
echo "spike compile summary: $PASS passed, $FAIL failed"
exit $FAIL