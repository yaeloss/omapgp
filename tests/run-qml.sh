#!/usr/bin/env bash
# Runs the headless QML harness against a disposable keyring. Quickshell only
# imports from inside its config folder, so the files under test are staged
# into a temp folder next to the harness.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/omapgp-qml.XXXXXX")"
export OMAPGP_TEST_HOME="$work/gnupg"
trap 'gpgconf --homedir "$OMAPGP_TEST_HOME" --kill all 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -m 700 "$OMAPGP_TEST_HOME"
mkdir "$work/shell"
cp "$repo/tests/qml/shell.qml" "$repo/GpgProcess.qml" "$repo/Model.js" "$repo/gpg-worker.py" "$work/shell/"
node "$repo/tests/setup-protected-key.js" "$OMAPGP_TEST_HOME"
status=0
out="$(QT_QPA_PLATFORM=offscreen timeout 60 quickshell -p "$work/shell" 2>&1)" || status=$?
if (( status != 0 )); then printf '%s\n' "$out" >&2; exit "$status"; fi
grep -E "ok   |FAIL|harness|ERROR" <<<"$out" | sed 's/^ *[A-Z]* *[a-z]*: *//'
grep -q "qml harness passed" <<<"$out"
