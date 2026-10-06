#!/usr/bin/env bash
# Verifies from a runtime log that every network-environment change started a lookup promptly.
#
#   bash Scripts/check-refresh-log.sh                 # newest log in the log directory
#   bash Scripts/check-refresh-log.sh FILE.jsonl      # a specific log
#   bash Scripts/check-refresh-log.sh --since 2026-10-03T10:30:00Z [FILE]
#
# A network trigger (network_path, network_configuration, route_change, system_wake) passes when a
# lookup_started follows within the event window plus slack, either directly or via the merged trailing
# lookup / in-flight recheck. A refresh_queued with reason=burst_budget for a network change always fails.
# Exits 1 on any violation.
set -euo pipefail

since=""
file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) file="$1"; shift ;;
  esac
done

if [[ -z "$file" ]]; then
  log_dir="${EXIT_IP_LOG_DIRECTORY:-$HOME/Library/Application Support/ExitIPMonitor/Logs}"
  file="$(ls -t "$log_dir"/runtime-*.jsonl 2>/dev/null | head -n 1 || true)"
  [[ -n "$file" ]] || { echo "No runtime-*.jsonl in $log_dir" >&2; exit 2; }
fi

exec /usr/bin/python3 - "$file" "$since" <<'PY'
import itertools, json, sys
from datetime import datetime, timedelta

path, since = sys.argv[1], sys.argv[2]
NETWORK = {"network_path", "network_configuration", "route_change", "system_wake"}
# Timestamps have one-second resolution: the event window (5 s) plus a lookup that starts right after an
# in-flight one completes.
DIRECT = timedelta(seconds=2)
MERGED = timedelta(seconds=8)
# Documented reasons a network change legitimately does not start a lookup: every enabled provider is
# paused after refusing requests or used its daily budget. A single paused provider is skipped by rotation,
# so it excuses nothing.
EXCUSED = {"lookup_daily_budget_exhausted", "lookup_all_providers_paused"}

def excused(entry):
    return entry["event"] in EXCUSED

def ts(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")

events = []
with open(path) as handle:
    for line in handle:
        line = line.strip()
        if line:
            entry = json.loads(line)
            entry["at"] = ts(entry["timestamp"])
            events.append(entry)
if since:
    events = [e for e in events if e["at"] >= ts(since)]

lookups = [e["at"] for e in events if e["event"] == "lookup_started"]
def lookup_within(start, window):
    return next((t for t in lookups if start <= t <= start + window), None)

checked, violations, paused = 0, [], 0
for index, entry in enumerate(events):
    name, fields = entry["event"], entry.get("fields", {})
    trigger = fields.get("trigger")
    if name == "refresh_queued" and fields.get("reason") == "burst_budget":
        urgency = fields.get("urgency")
        if urgency == "network_change" or (urgency is None and trigger in NETWORK):
            violations.append(f"{entry['timestamp']} {trigger}: network change queued for burst budget until {fields.get('notBefore')}")
        continue
    if trigger not in NETWORK:
        continue
    if name == "refresh_requested":
        window = DIRECT
    elif name in ("refresh_event_merged", "refresh_coalesced_in_flight"):
        window = MERGED
    else:
        continue
    checked += 1
    if lookup_within(entry["at"], window):
        continue
    following = [e["event"] for e in events[index + 1:index + 4]]
    later = itertools.takewhile(lambda e: e["at"] <= entry["at"] + window, events[index + 1:index + 200])
    if any(excused(e) for e in later):
        paused += 1
        continue
    violations.append(f"{entry['timestamp']} {trigger} ({name}): no lookup within {int(window.total_seconds())} s; next: {', '.join(following)}")

print(f"{path}\nChecked {checked} network-change events.")
if paused:
    print(f"Excused {paused} event(s) while a provider was paused or every daily budget was used (documented, no failover).")
if violations:
    print(f"FAIL: {len(violations)} delayed network refresh(es):")
    for violation in violations:
        print(f"  {violation}")
    sys.exit(1)
print("PASS: every network change started a lookup promptly.")
PY
