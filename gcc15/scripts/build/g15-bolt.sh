#!/bin/bash
# ON THE SERVER: g15-bolt.sh <input twin arm, e.g. pgoltoq> <perf.data> -> /opt/<PFX>-pg18-<arm minus q>b
# PFX (default g15) picks the round: PFX=g15n1 reads /opt/g15n1-pg18-<arm> and works in ~/g15/bolt-g15n1-<arm>.
set -euo pipefail
IN=$1; PD=$2; OUTARM=${IN%q}b; PFX=${PFX:-g15}
B=/opt/llvm-bolt-18.1.3/bin; W=/home/ec2-user/g15/bolt-$IN; [ "$PFX" = g15 ] || W=/home/ec2-user/g15/bolt-$PFX-$IN; mkdir -p $W
SRCD=/opt/$PFX-pg18-$IN; DST=/opt/$PFX-pg18-$OUTARM
cp $SRCD/bin/postgres $W/postgres          # perf2bolt matches by file name: keep "postgres"
# grep -c, not grep -q: -q exits on the first match, readelf dies of SIGPIPE, and pipefail fails the check
readelf -SW $W/postgres | grep -c '\.rela\.text' >/dev/null || { echo "no .rela.text"; exit 1; }
readelf -SW $W/postgres | grep -c '\.note\.bolt_info' >/dev/null && { echo "already BOLTed"; exit 1; }
$B/perf2bolt -p $PD -o $W/profile.fdata $W/postgres > $W/perf2bolt.log 2>&1
FSZ=$(stat -c %s $W/profile.fdata); echo "fdata $FSZ bytes"; [ $FSZ -gt 500000 ] || { echo "fdata too small"; exit 1; }
$B/llvm-bolt $W/postgres -o $W/postgres.bolt -data=$W/profile.fdata -reorder-blocks=ext-tsp \
  -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections > $W/bolt.log 2>&1
N=$(grep -oE 'BOLT-INFO: [0-9]+ out of [0-9]+ functions in the binary .* non-empty execution profile' $W/bolt.log | awk '{print $2}')
grep -E 'non-empty execution profile|functions out of' $W/bolt.log | head -3
grep -E 'taken branches' $W/bolt.log | tail -1
[ "${N:-0}" -gt 200 ] || { echo "only ${N:-0} profiled functions"; exit 1; }
sudo rm -rf $DST; sudo cp -a $SRCD $DST
sudo install -m 755 $W/postgres.bolt $DST/bin/postgres
echo "$OUTARM md5 $(md5sum $DST/bin/postgres | cut -c1-12)  .text $(size -A $DST/bin/postgres | awk '$1==".text"{print $2}')"
