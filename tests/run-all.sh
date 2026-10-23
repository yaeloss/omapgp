#!/usr/bin/env bash
# Every test uses throwaway keyrings; none touch ~/.gnupg.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run-portable.sh
tests/run-qml.sh | tail -1
bash tests/run-ui.sh | tail -1
omarchy plugin validate . >/dev/null && echo "manifest valid"
