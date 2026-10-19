#!/usr/bin/env python3
"""Embed the authoritative cleanup helper in the companion cask, including for old apps.

Usage: python3 Scripts/sync-homebrew-cleanup.py [--check] /path/to/Casks/exit-ip-monitor.rb
Only the marked shell block changes; release version and checksum are preserved.
"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
parser.add_argument("cask", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
begin = "                # BEGIN GENERATED CLEANUP\n"
end = "                # END GENERATED CLEANUP\n"
text = args.cask.read_text()
assert text.count(begin) == text.count(end) == 1, "Expected one cleanup marker pair"
support = (root / "Sources/ExitIPDiagnostics/command-support.sh").read_text()
cleanup = (root / "Sources/ExitIPDiagnostics/cleanup-installation.sh").read_text()
body = support + "\n" + cleanup + '\ncleanup_main --app "$1"\n'
embedded = "".join("                " + line + "\n" if line else "\n" for line in body.splitlines())
prefix, remainder = text.split(begin)
_, suffix = remainder.split(end)
updated = prefix + begin + embedded + end + suffix
if args.check:
    if text != updated:
        raise SystemExit("Cask cleanup differs from source; run this command without --check.")
    print("PASS: cask cleanup matches the authoritative helpers")
else:
    args.cask.write_text(updated)
