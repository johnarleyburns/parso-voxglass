#!/bin/bash
# Run the Swift Testing suite; pass additional swift test arguments through.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
exec swift test "$@"
