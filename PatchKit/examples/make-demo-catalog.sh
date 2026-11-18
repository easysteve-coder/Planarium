#!/bin/sh
# Builds a demo sound catalog by IMPORTING two already captured audio-unit states.
# Usage: make-demo-catalog.sh <tool> <new-catalog-folder> <delay-state.plist> <surge-init-state.plist>
# Nothing is captured or loaded; the states are copied into <new-catalog-folder>/states/.
set -eu
tool="$1"; folder="$2"; delay="$3"; surge="$4"
mkdir -p "$folder"
"$tool" kit import-state --catalog "$folder/sounds.json" --state "$delay" --alias apple.delay.eagle --role effect \
  --description "Apple AUDelay: 25 % mix, 0.28 s, 20 % feedback (measured Eagle setting)"
"$tool" kit import-state --catalog "$folder/sounds.json" --state "$surge" --alias surge.init --role instrument \
  --description "Surge XT factory default (InitSaw) — demo only, NOT the organ sound"
