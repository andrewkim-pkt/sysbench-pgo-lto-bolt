#!/usr/bin/env bash
# Wait for fc-prof.sh to finish cleanly, check all fc arms are installed, then run the mirrored benchmark.
cd ~/lat
while ! grep -q FC_PROF_DONE fc-prof.out; do
  grep -q '!!!' fc-prof.out && { echo "[$(date -u +%T)] fc-prof failed, benchmark NOT started"; exit 1; }
  pgrep -f "bash fc-prof[.]sh" >/dev/null || { sleep 5; grep -q FC_PROF_DONE fc-prof.out || { echo "[$(date -u +%T)] fc-prof not running and not done, benchmark NOT started"; exit 1; }; }
  sleep 60; done
MISSING=$(ssh -n -o ConnectTimeout=20 srv 'for a in pgo pgolto afdo afdolto pgob pgoltob afdob afdoltob; do [ -x /opt/pg18fc-$a/bin/postgres ] || echo $a; done')
[ -z "$MISSING" ] || { echo "[$(date -u +%T)] missing fc arms: $MISSING, benchmark NOT started"; exit 1; }
echo "[$(date -u +%T)] all fc arms present, starting fc-mirror"
bash fc-mirror.sh
