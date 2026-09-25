#!/usr/bin/env bash
# Relink afdoltoq's postgres with and without -fauto-profile; compare .text. Does the link-line profile do anything?
cd ~/pg-lattice/build/afdoltoq/src/backend || exit 1
trap "cp -p /opt/pg18-afdoltoq/bin/postgres postgres" EXIT
L=$(sed -n 1783p ~/pg-lattice/logs/build-afdoltoq.log)
txt() { readelf -SW $1 | awk '$2==".text"{print strtonum("0x"$6)}'; }
WITH=$(echo "$L" | sed 's| -o postgres$| -o /tmp/pg-with|')
NONE=$(echo "$L" | sed 's| -fauto-profile=[^ ]*||g; s| -o postgres$| -o /tmp/pg-none|')
echo "profile flags in link: $(echo "$L" | grep -o -- '-fauto-profile=[^ ]*' | wc -l) / after strip: $(echo "$NONE" | grep -o -- '-fauto-profile' | wc -l)"
numactl --cpunodebind=0 --membind=0 bash -c "$WITH" > /tmp/relink-with.log 2>&1; echo "with exit=$?"
numactl --cpunodebind=0 --membind=0 bash -c "$NONE" > /tmp/relink-none.log 2>&1; echo "none exit=$?"
echo "installed afdoltoq .text=$(txt /opt/pg18-afdoltoq/bin/postgres)"
echo "relink WITH profile .text=$(txt /tmp/pg-with)"
echo "relink NO profile   .text=$(txt /tmp/pg-none)"
cmp -s <(objcopy -O binary -j .text /tmp/pg-with /dev/stdout) <(objcopy -O binary -j .text /tmp/pg-none /dev/stdout) && echo "TEXT BYTES IDENTICAL -> link-line profile is a no-op" || echo "text bytes DIFFER -> profile applied at link"
