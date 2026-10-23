#!/usr/bin/env bash
# No Omarchy, Qt, display, network, real keys, or user clipboard required.
set -euo pipefail
cd "$(dirname "$0")/.."
node tests/publication.test.js
node tests/model.test.js
node tests/panel.test.js
node tests/gpg.integration.test.js
node tests/protected-key.test.js
node tests/runner.test.js
python3 -B tests/worker.test.py
