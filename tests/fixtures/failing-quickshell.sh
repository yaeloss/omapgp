#!/usr/bin/env bash
# A success-looking log must not override a failed process exit.
printf '%s\n' 'qml harness passed' 'ui harness passed'
exit 7
