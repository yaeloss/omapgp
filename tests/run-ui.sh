#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/omapgp-ui.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -m 700 "$work/gnupg"
mkdir "$work/shell"
export OMAPGP_TEST_HOME="$work/gnupg"
cp "$repo/tests/qml/ui.qml" "$work/shell/shell.qml"
cp "$repo/Panel.qml" "$repo/PgpTextArea.qml" "$repo/PgpTextView.qml" "$repo/GpgProcess.qml" "$repo/Model.js" "$repo/gpg-worker.py" "$work/shell/"
for module in Commons services; do ln -s "/usr/share/omarchy/shell/$module" "$work/shell/$module"; done
mkdir "$work/shell/Ui"
for file in /usr/share/omarchy/shell/Ui/*; do
  name="${file##*/}"
  if [[ "$name" != KeyboardPanel.qml ]]; then ln -s "$file" "$work/shell/Ui/$name"; fi
done
cp "$repo/tests/qml/KeyboardPanel.qml" "$work/shell/Ui/"
status=0
out="$(QT_QPA_PLATFORM=offscreen timeout 25 quickshell -p "$work/shell" 2>&1)" || status=$?
if (( status != 0 )); then printf '%s\n' "$out" >&2; exit "$status"; fi
printf '%s\n' "$out" | sed -n '/ok   /p; /FAIL/p; /harness/p; /ERROR/p; /caused by/p'
if ! grep -q 'ui harness passed' <<<"$out"; then printf '%s\n' "$out"; exit 1; fi
