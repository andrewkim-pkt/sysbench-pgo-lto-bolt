#!/usr/bin/env bash
# sb-record.sh afdo|bolt <arm> : golden restore, /opt/pg18-<arm> on node 0, 128-thread loopback load from
# nodes 1-2, perf record node-0 CPUs for REC_SECS after SETTLE. Flags are the lost DUT's pg-record.sh.
set -uo pipefail
cd ~/pg-lattice; mkdir -p work
MODE=${1:?afdo|bolt}; ARM=${2:?arm}; B=/opt/pg18-$ARM/bin
D=/mnt/pgramdisk/pg18sb250; G=/var/lib/pg18-lattice/pg18sb250-golden
T=${THREADS:-128}; SETTLE=${SETTLE:-60}; SECS=${REC_SECS:-180}; OUT=work/$MODE-$ARM.data
NODE0=$(cat /sys/devices/system/node/node0/cpulist)
die() { echo "!!! $*"; exit 1; }
cpus0() { numactl --physcpubind=$NODE0 --show | awk '/^physcpubind/{for(i=2;i<=NF;i++)print $i}'; }
snap() { awk -v L="$(cpus0 | tr '\n' ' ')" 'BEGIN{n=split(L,a," ");for(i=1;i<=n;i++)w["cpu"a[i]]=1}
  ($1 in w){t=0;for(i=2;i<=NF;i++)t+=$i; T+=t; I+=$5+$6} END{print T, I}' /proc/stat; }
[ -x $B/postgres ] || die "no $B/postgres"
ulimit -n $(ulimit -Hn)
for p in $(pgrep -f "bin/postgres -D $D" || true); do
  $(dirname $(readlink /proc/$p/exe))/pg_ctl -D $D -m fast -w -t 1800 stop; done
echo "== $MODE $ARM restore $(date -u +%T)"; rm -rf $D; cp -a $G $D
numactl --cpunodebind=0 --membind=0 $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-$ARM.log -w -t 600 start >/dev/null || die "start failed"
P=$(head -1 $D/postmaster.pid); EXE=$(readlink /proc/$P/exe)
[ "$EXE" = "$B/postgres" ] || die "postmaster exe is $EXE, not $B/postgres"
echo "postmaster exe=$EXE aff=$(taskset -cp $P | awk '{print $NF}')"
numactl --cpunodebind=1,2 --membind=1,2 sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 \
  --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 \
  --threads=$T --time=$((SETTLE+SECS+30)) --report-interval=30 --rand-type=uniform oltp_read_write run > logs/rec-$MODE-$ARM.log 2>&1 &
SB=$!
sleep $SETTLE; read T0 I0 < <(snap)
case $MODE in
afdo) sudo perf record -e cycles:u -j any,u -c 800011 --no-buildid --no-buildid-cache \
        -C "$NODE0" -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $SECS ;;
bolt) sudo perf record -b -z1 --aio=4 -c 100003 -e branches:u --no-buildid --no-buildid-cache \
        -C "$NODE0" -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $SECS ;;
*) die "mode" ;;
esac
read T1 I1 < <(snap)
kill -0 $SB 2>/dev/null || die "sysbench died before the record window closed"
wait $SB
BUSY=$(awk -v a=$T0 -v b=$T1 -v c=$I0 -v d=$I1 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}')
sudo chown ec2-user: $OUT
# --no-buildid leaves the build-id table blank, and create_gcov then matches no samples (1597-byte
# profile). perf2bolt falls back to the path, but autofdo does not: inject from the staged binary.
if [ $MODE = afdo ]; then numactl --cpunodebind=2 --membind=2 perf inject --build-ids -i $OUT -o $OUT.bid && mv $OUT.bid $OUT
  perf buildid-list -i $OUT --force 2>/dev/null | grep -Eq "^[0-9a-f]{40} $B/postgres$" || die "build-id still missing after inject"; fi
$B/pg_ctl -D $D -m fast -w -t 1800 stop >/dev/null
echo "node0_busy_record=$BUSY%  $(grep -E 'transactions:' logs/rec-$MODE-$ARM.log | xargs)"
echo "size=$(stat -c%s $OUT)"
echo -n "brstack present (of 200): "; perf script -i $OUT --force -F brstack 2>/dev/null | head -200 | grep -c '/'
echo "dso share:"; perf report -i $OUT --force --stdio --sort dso 2>/dev/null | grep -E '^ +[0-9]' | head -4
awk -v b=$BUSY 'BEGIN{exit !(b>60)}' && { touch work/.ok-$MODE-$ARM; echo "RECORD_OK $MODE $ARM"; } || echo "RECORD_BELOW_60 $MODE $ARM"
