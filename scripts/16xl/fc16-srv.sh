#!/usr/bin/env bash
# Server side for the r8i.16xlarge base-vs-afdoltob runs (derived from fc-srv.sh; only start/stop/snap/waits/md5 are used).
# this box only runs postgres (unpinned, all 192 vCPUs, max_connections=$MAXC) and perf (-a).
#   start <install-name>          golden restore, start /opt/<name> unpinned, verify exe
#   stop | snap                   fast stop | all-CPU "total idle" jiffies
#   gcda-clear | gcda-check       pgogen tree .gcda: delete stale | count + size + backup tarball
#   record afdo|bolt <name> <s>   perf record -a for <s> seconds, output work-fc/<mode>-<arm>.data
#   post afdo|bolt <name> <busy>  build-id inject (afdo), sanity prints, bless if busy>60
set -uo pipefail
cd ~/pg-lattice; mkdir -p work-fc logs
D=/mnt/pgramdisk/pg18sb84; G=/var/lib/pg18-lattice/pg18sb84-golden; MAXC=${MAXC:-2000}
TREE=/home/ec2-user/pg-lattice/build/pgogen
stopall() { for p in $(pgrep -f "bin/postgres -D $D" || true); do $(dirname $(readlink /proc/$p/exe))/pg_ctl -D $D -m fast -w -t 7200 stop >/dev/null; done; }
case $1 in
start) B=/opt/$2/bin; [ -x $B/postgres ] || { echo "NO_BINARY $B"; exit 1; }
  stopall; rm -rf $D; cp -a $G $D; ulimit -n $(ulimit -Hn)
  $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-$2.log -o "-c max_connections=$MAXC" -w -t 600 start >/dev/null || { echo START_FAIL; exit 1; }
  P=$(head -1 $D/postmaster.pid); [ "$(readlink /proc/$P/exe)" = "$B/postgres" ] || { echo EXE_MISMATCH; stopall; exit 1; }
  echo "exe=$B/postgres aff=$(taskset -cp $P | awk '{print $NF}') max_connections=$($B/psql -h /tmp -U sbtest -d sbtest -Atc 'show max_connections')";;
stop) stopall; echo stopped;;
snap) awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat;;
gcda-clear) echo "stale gcda: $(find $TREE -name '*.gcda' | wc -l)"; find $TREE -name '*.gcda' -delete; echo cleared;;
gcda-check) N=$(find $TREE -name '*.gcda' | wc -l)
  echo "gcda: $N  size=$(find $TREE -name '*.gcda' -printf '%s\n' | awk '{s+=$1}END{print s}')"
  (cd $TREE && find . -name '*.gcda' | tar -czf /var/lib/pg18-lattice/pgogen-gcda-fc-$(date -u +%Y%m%d).tgz -T -) && echo "backup /var/lib/pg18-lattice/pgogen-gcda-fc-$(date -u +%Y%m%d).tgz"
  [ $N -gt 800 ] && echo GCDA_OK || echo GCDA_LOW;;
record) ARM=${3#*-}; OUT=work-fc/$2-$ARM.data
  case $2 in
  afdo) sudo perf record -e cycles:u -j any,u -c 800011 --no-buildid --no-buildid-cache \
          -a -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $4 ;;
  bolt) sudo perf record -b -z1 --aio=4 -c 100003 -e branches:u --no-buildid --no-buildid-cache \
          -a -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $4 ;;
  esac > logs/perf-fc-$2-$ARM.log 2>&1; echo "perf rc=$?";;
post) B=/opt/$3/bin; ARM=${3#*-}; OUT=work-fc/$2-$ARM.data; sudo chown ec2-user: $OUT
  # --no-buildid leaves the build-id table blank and create_gcov then matches nothing; perf2bolt uses the path.
  if [ $2 = afdo ]; then perf inject --build-ids -i $OUT -o $OUT.bid && mv $OUT.bid $OUT
    perf buildid-list -i $OUT --force 2>/dev/null | grep -Eq "^[0-9a-f]{40} $B/postgres$" || { echo "BUILDID_MISSING"; exit 1; }; fi
  echo "size=$(stat -c%s $OUT)"
  echo -n "brstack present (of 200): "; perf script -i $OUT --force -F brstack 2>/dev/null | head -200 | grep -c '/'
  echo "dso share:"; perf report -i $OUT --force --stdio --sort dso 2>/dev/null | grep -E '^ +[0-9]' | head -4
  awk -v b=$4 'BEGIN{exit !(b>60)}' && { touch work-fc/.ok-$2-$ARM; echo "RECORD_OK $2 $ARM"; } || echo "RECORD_BELOW_60 $2 $ARM";;
esac
# waits <install-name> : one pg_stat_activity wait-event sample (type:event count), all client backends
[ "$1" = waits ] && /opt/$2/bin/psql -h /tmp -U sbtest -d sbtest -Atc "select coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'-'),count(*) from pg_stat_activity where backend_type='client backend' group by 1 order by 2 desc limit 8" | tr '\n' ' '
[ "$1" = md5 ] && md5sum < /opt/$2/bin/postgres | cut -c1-10
exit 0
