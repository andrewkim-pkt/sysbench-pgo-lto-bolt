#!/usr/bin/env bash
# Wait for any running build on node 0, then record in sequence.
cd ~/pg-lattice
while pgrep -f "pg-build-1n[.]sh" >/dev/null; do sleep 30; done
echo "builds idle $(date -u +%T)"
for job in "$@"; do ./sb-record.sh ${job%%:*} ${job##*:}; done
echo CHAIN_DONE
