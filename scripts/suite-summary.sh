#!/bin/bash
# Entry point kept compatible with existing callers, including /bin/bash.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/suite-summary.py "$@"
