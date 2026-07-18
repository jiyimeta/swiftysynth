#!/bin/bash
# verify-rt-gates.sh — the isolated real-time-safety witnesses, run solo.
#
# The default `swift test` run asserts the bounded-retry no-net-increase
# zero-alloc criterion (reliable under Swift Testing's cross-suite
# parallelism, where other suites' malloc traffic pollutes the process-wide
# snapshot). The AUTHORITATIVE evidence is the exact-0/0 witness, which is
# only meaningful when the test runs alone — this script is that solo run,
# with SWIFTYSYNTH_RT_STRICT=1 turning the witness into a hard assertion
# (exactZeroWitness must be true or the test FAILS).
#
# This script IS the CI job for these gates — wire it in verbatim once the
# repo has CI.
#
# Usage: Scripts/verify-rt-gates.sh [--cpu]
#   --cpu   additionally run the release-build CPU-budget gates (needs a
#           quiescent host; the tests skip themselves under load — a skip
#           here is NOT a pass for record-keeping purposes, see README).
set -euo pipefail
cd "$(dirname "$0")/.."

# Default: GeneralUser-GS.sf2 at the repo root (the script cd'd there above) —
# the font is not committed; place it there or point SWIFTYSYNTH_SF2 elsewhere.
SF2="${SWIFTYSYNTH_SF2:-$PWD/GeneralUser-GS.sf2}"
if [[ ! -f "$SF2" ]]; then
    echo "verify-rt-gates: reference SF2 not found at $SF2 (set SWIFTYSYNTH_SF2) — refusing a vacuous pass" >&2
    exit 2
fi

echo "== strict zero-alloc witness (solo): synthesizer, dry + effects-on =="
SWIFTYSYNTH_RT_STRICT=1 swift test --filter RealTimeSafetyTests.zeroAllocationAfterWarmup

echo "== strict zero-alloc witness (solo): sequencer, nil + onSend hooks =="
SWIFTYSYNTH_RT_STRICT=1 swift test --filter RealTimeSafetyTests.sequencerZeroAllocationAfterWarmup

if [[ "${1:-}" == "--cpu" ]]; then
    echo "== CPU budget (release, host-load-guarded) =="
    swift test -c release --filter RealTimeSafetyTests.cpuBudget
    swift test -c release --filter RealTimeSafetyTests.sequencerCpuBudget
fi

echo "verify-rt-gates: ALL GREEN"
