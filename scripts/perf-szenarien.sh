#!/bin/bash
# Serial offline measurements. Never run alongside another build/test.
set -euo pipefail
cd "$(dirname "$0")/.."
repetitions="${1:-5}"
configuration="${2:-debug}"
if ! [[ "$repetitions" =~ ^[0-9]+$ ]] || [ "$repetitions" -lt 5 ]; then
    echo "Mindestens fünf Wiederholungen angeben." >&2; exit 2
fi
case "$configuration" in debug|release) ;; *) echo "debug oder release angeben" >&2; exit 2 ;; esac
: "${SICK_TEST_ARTIFACT_DIR:?Eigenes SICK_TEST_ARTIFACT_DIR setzen (absoluter Pfad)}"
case "$SICK_TEST_ARTIFACT_DIR" in /*) ;; *) echo "Artefaktpfad muss absolut sein" >&2; exit 2 ;; esac
# Atomic cooperative lock: a second invocation must not start another suite.
lock=.build/perf-szenarien.lock
mkdir -p .build "$SICK_TEST_ARTIFACT_DIR"
if ! mkdir "$lock" 2>/dev/null; then
    echo "Messung läuft bereits (oder verwaister Lock: $lock)." >&2; exit 2
fi
trap 'rmdir "$lock"' EXIT
# Fail closed if process inspection is unavailable. Other entry points do not
# take our lock, so inspect once before starting; collaborators must stay idle.
if ! processes=$(ps -axo comm=); then
    echo "Exklusivität nicht prüfbar; kein Test gestartet." >&2; exit 2
fi
if grep -E '(^|/)(swift-test|xctest|swift-build)$' <<< "$processes" > /dev/null; then
    echo "Anderer Build/Test aktiv; kein Test gestartet." >&2; exit 2
fi
export SICK_PERF_COMMIT="$(git rev-parse HEAD)"
export SICK_PERF_RUN
# Keep the documented default fixture and uninstrumented measurements even
# when a shell previously enabled one of the separate diagnostic probes.
unset SICK_ACCEPTANCE_PRESET SICK_VIEW_COST SICK_DETECTION_COST PLANARIUM_DETECTION_LATENCY
filter='SelectionTempoTests/testNativeLayerAndCellSelectionVisibleWithinFiftyMillisecondsWithoutDocumentPublication|AcceptanceAViewBudgetTests/testProfile25HzMeter30HzInvalidateOnlyCanvasAndMeter90And361|ProductionLatencyTests'
for ((run=1; run<=repetitions; run++)); do
    SICK_PERF_RUN="$run"
    log="$SICK_TEST_ARTIFACT_DIR/run-$run.log"
    if [ -e "$log" ]; then echo "Artefakte existieren bereits: $log" >&2; exit 2; fi
    echo "Messlauf $run/$repetitions ($configuration)"
    status=0
    swift test -c "$configuration" --disable-swift-testing --filter "$filter" > "$log" 2>&1 || status=$?
    echo "$status" > "$SICK_TEST_ARTIFACT_DIR/run-$run.status"
    # Existing parser also detects build errors/crashes/no executed cases.
    scripts/suite-summary.sh --log "$log" || status=1
    echo "$status" > "$SICK_TEST_ARTIFACT_DIR/run-$run.status"
done
python3 scripts/perf-report.py summarize "$SICK_TEST_ARTIFACT_DIR" "$repetitions"
