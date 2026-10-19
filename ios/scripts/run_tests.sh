#!/bin/zsh
# Sequential package test runner — the ONLY supported way to run Icarus package tests.
#
# Why this exists: concurrent `swift test` runs on packages that depend on each other (BandKit
# depends on BandProtocol, Store, Metrics…) race on the shared dependency's .build dir and stall
# forever; killed builds leave corrupt module caches that hang the next run. So: strictly
# sequential, one package at a time, with a hard timeout and automatic .build recovery on timeout.
#
# Usage: scripts/run_tests.sh [package ...]   (default: all packages)

set -u
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES_DIR="$ROOT/Packages"
ALL=(BandProtocol BandKit Metrics Store SyncKit)
if [ $# -gt 0 ]; then PACKAGES=("$@"); else PACKAGES=("${ALL[@]}"); fi

TIMEOUT_SECS=${TEST_TIMEOUT:-600}
FAILED=0

# Sweep orphans from previously aborted/killed runs FIRST: swift test spawns children
# (swift-build, swift-frontend, swiftpm-testing-helper); killing only the parent orphans them
# and every later run then stalls against the wedged helper holding the old test bundle.
pkill -f "icarus/ios/Packages" 2>/dev/null
pkill -f "swiftpm-testing-helper" 2>/dev/null
sleep 1

for PKG in "${PACKAGES[@]}"; do
  DIR="$PACKAGES_DIR/$PKG"
  [ -d "$DIR" ] || { echo "skip $PKG (no package)"; continue; }
  printf '== %s: ' "$PKG"
  LOG=$(mktemp)
  ( cd "$DIR" && swift test ) > "$LOG" 2>&1 &
  PID=$!
  DONE=0
  for i in $(seq 1 $TIMEOUT_SECS); do
    sleep 1
    kill -0 $PID 2>/dev/null || { DONE=1; break; }
  done
  if [ $DONE -eq 0 ]; then
    kill -9 $PID 2>/dev/null
    # Kill the whole tree, not just the parent: SwiftPM's children (swift-build, swift-frontend,
    # swiftpm-testing-helper) survive a parent kill and wedge every later run. Any process whose
    # command line references this package's path is ours; the helper's bundle path matches too.
    pkill -9 -f "Packages/$PKG" 2>/dev/null
    pkill -f "swiftpm-testing-helper" 2>/dev/null
    # A killed run also leaves a corrupt module cache that stalls the next run — recover both.
    rm -rf "$DIR/.build"
    echo "TIMEOUT after ${TIMEOUT_SECS}s (stalled; process tree + .build cleared for a clean retry)"
    FAILED=1
  else
    RESULT=$(grep -E 'Test run with .* (passed|failed)' "$LOG" | tail -1 | sed 's/^✔ /PASS /; s/^✘ /FAIL /')
    if [ -n "$RESULT" ]; then
      echo "$RESULT"
      echo "$RESULT" | grep -q "^PASS " || FAILED=1
    else
      echo "BUILD ERROR:"; grep -E "error:" "$LOG" | head -3 | sed 's/^/    /'
      FAILED=1
    fi
  fi
  rm -f "$LOG"
done

[ $FAILED -eq 0 ] && echo "ALL PACKAGES PASS" || { echo "SOME PACKAGES FAILED"; exit 1; }
