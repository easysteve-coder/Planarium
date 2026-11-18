#!/bin/bash
#
# Strikter Concurrency-Build als Diagnosendiff gegen die feste Referenz
# (`.agent_handoff/strict-concurrency-baseline.txt`, CLAUDE.md-Checks).
#
# Gezählt wird jede eindeutige Diagnose nach
# `Datei:Zeile:Spalte + normalisiertem Meldungstext`; doppelte
# Compiler-Emissionen werden verworfen. Exit 0 heißt nur „Build lief" --
# die Aussage ist der Diff, nicht der Exit-Code.
#
# BENUTZUNG
#   scripts/strict-concurrency-diff.sh              # Diff gegen Baseline
#   scripts/strict-concurrency-diff.sh --write-baseline
#
# Der Build läuft in einem eigenen Scratch-Path, damit der reguläre
# `.build` unberührt bleibt.

set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE=".agent_handoff/strict-concurrency-baseline.txt"
SCRATCH="${STRICT_SCRATCH:-/tmp/sick-strict-scratch}"
CURRENT="$(mktemp)"
BUILD_LOG="$(mktemp)"

cleanup() {
    rm -f "$CURRENT" "$CURRENT.baseline" "$BUILD_LOG"
}
trap cleanup EXIT

# Frischer Scratch-Path: Warnungen erscheinen nur beim tatsächlichen
# Übersetzen, ein inkrementeller Build zeigte sie nicht erneut.
rm -rf "$SCRATCH"
set +e
swift build --scratch-path "$SCRATCH" -Xswiftc -strict-concurrency=complete >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

sed -E 's/\x1b\[[0-9;]*m//g' "$BUILD_LOG" \
    | grep -E '^(/[^:]*/)?Sources/[^:]+:[0-9]+:[0-9]+: warning: ' \
    | sed -E 's#^/.*/(Sources/)#\1#' \
    | sed -E "s/: warning: /: /" \
    | sed -E "s/; this is an error in the Swift 6 language mode//" \
    | sed -E 's/ \[#[^]]*\]$//' \
    | sed -E 's/ \[#.*$//' \
    | sort -u > "$CURRENT" || true

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "Strict-concurrency build fehlgeschlagen (Exit $BUILD_STATUS)." >&2
    grep -E '(^|: )(error|fatal error):' "$BUILD_LOG" >&2 || tail -n 80 "$BUILD_LOG" >&2
    exit "$BUILD_STATUS"
fi

if [ "${1:-}" = "--write-baseline" ]; then
    {
        echo "# Strict-concurrency warning baseline — $(date +%d.%m.%Y)"
        echo "# Command: swift build --scratch-path <fresh> -Xswiftc -strict-concurrency=complete"
        echo "# Unique diagnostics: $(wc -l < "$CURRENT" | tr -d ' '). Duplicate compiler emissions are ignored."
        echo "# Format: relative-path:line:column: message"
        cat "$CURRENT"
    } > "$BASELINE"
    echo "Baseline geschrieben: $(wc -l < "$CURRENT" | tr -d ' ') Diagnosen"
    exit 0
fi

# `|| true`: eine leere Baseline (null Diagnosen, SICK-039) lässt `grep`
# mit Status 1 enden und würde das Skript unter `pipefail` still beenden.
(grep -v '^#' "$BASELINE" || true) | sed -E 's/ \[#.*$//' | sort -u > "$CURRENT.baseline"
echo "Diagnosen jetzt: $(wc -l < "$CURRENT" | tr -d ' '), Baseline: $(wc -l < "$CURRENT.baseline" | tr -d ' ')"
echo "--- neu gegenüber Baseline:"
comm -13 "$CURRENT.baseline" "$CURRENT" || true
echo "--- verschwunden gegenüber Baseline:"
comm -23 "$CURRENT.baseline" "$CURRENT" || true
