#!/usr/bin/python3
"""Assuan pinentry for disposable test keys only. Never installed as a plugin."""
import os
import sys

print("OK Test pinentry ready", flush=True)
for line in sys.stdin:
    line = line.strip()
    if line == "GETPIN":
        print("D disposable-test-passphrase", flush=True)
    elif line == "GETINFO pid":
        print("D " + str(os.getpid()), flush=True)
    elif line.startswith("GETINFO"):
        print("D test", flush=True)
    print("OK", flush=True)
    if line == "BYE":
        break
