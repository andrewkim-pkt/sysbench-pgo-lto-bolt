#!/usr/bin/env bash
# Server side of the sysbench-trained gcc 15.2.0 matrix on r8i.metal-48xl. Runs ON the server.
# postgres is NEVER pinned: all 192 vCPUs, default memory policy. perf records with -a.
# The client (sbp.sh) drives all load over the VPC and calls these subcommands over ssh.
#   boot                          206 x 1G hugepages + 180G tmpfs (after every server boot)
#   init | snapshot               new cluster from base (published postgresql.conf) | golden copy
#   start <arm> | stop | snap     golden restore + start /opt/g15-pg18-<arm> | fast stop | /proc/stat jiffies
#   gcda-clear | gcda-check       pgogen tree .gcda: delete stale | count + backup tarball
#   record afdo|bolt <arm> <s>    perf record -a for <s> s -> work/<mode>-<arm>.data
#   afdo-post                     build-id inject + create_gcov -> work/pg18-g15-sysbench.afdo
#   snap1                         jiffies: whole total idle + node-1 CPUs total idle
#   mem-n1 | mem-all              (stops pg) hugepages + tmpfs all on node 1 | round-1 layout (spread, default policy)
#   numa                          numastat -m rows + postmaster placement
#   env: ROUND=n1 (work-n1, n1 pgogen tree, n1 profile names)  NODE1=1 (start pinned to node 1)  arm n1-<x> = /opt/g15n1-pg18-<x>
set -uo pipefail
D=/mnt/pgramdisk/pg18sb250; G=/home/ec2-user/sbgolden/pg18sb250
# ROUND=n1: node-1-trained round -> its own work dir, pgogen tree, profile names. Empty = round 1, unchanged.
RT=${ROUND:-}; W=/home/ec2-user/g15/work${RT:+-$RT}; L=/home/ec2-user/g15/logs; TREE=/home/ec2-user/g15${RT:+/$RT}/pgsrc-pgo
AFNAME=pg18-g15${RT}-sysbench.afdo; GTGZ=pgogen-gcda-sysbench${RT:+-$RT}.tgz
# NODE1=1: postgres on NUMA node 1 only (CPUs + preferred memory; never --membind, it OOMs)
N1CPUS=32-63,128-159; NUMA=""; [ "${NODE1:-0}" = 1 ] && NUMA="numactl -C $N1CPUS --preferred=1"
# arm "n1-<x>" -> /opt/g15n1-pg18-<x>; plain "<x>" -> /opt/g15-pg18-<x>
armdir() { case $1 in n1-*) echo /opt/g15n1-pg18-${1#n1-} ;; *) echo /opt/g15-pg18-$1 ;; esac; }
MAXC=${MAXC:-4000}; HP=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
mkdir -p $W $L
die() { echo "FATAL: $*"; exit 1; }
PB=/opt/g15-pg18-base/bin   # pg_ctl/psql always from base: pgogen's instrumented tools would write .gcda into the training tree
stopall() { $PB/pg_ctl -D $D status >/dev/null 2>&1 && $PB/pg_ctl -D $D -m fast -w -t 7200 stop >/dev/null; true; }
case ${1:-} in
boot)
  echo 206 | sudo tee $HP >/dev/null
  mountpoint -q /mnt/pgramdisk || { sudo mkdir -p /mnt/pgramdisk
    sudo mount -t tmpfs -o size=180G,mode=0700 tmpfs /mnt/pgramdisk; sudo chown ec2-user: /mnt/pgramdisk; }
  echo "hugepages $(cat $HP) per node: $(cat /sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages | tr '\n' ' ')"
  df -h /mnt/pgramdisk | tail -1 ;;
init)
  B=/opt/g15-pg18-base/bin; [ -d $D ] && die "$D exists"
  $B/initdb -D $D -U postgres --auth-local=trust --auth-host=scram-sha-256 > $L/initdb.log 2>&1 || die initdb
  cp ~/g15/postgresql.conf $D/postgresql.conf; echo "host all all <PRIVATE_IP>/16 scram-sha-256" >> $D/pg_hba.conf
  $B/pg_ctl -D $D -l $L/init.log -o "-c max_connections=$MAXC" -w -t 600 start >/dev/null || die start
  $B/psql -h /tmp -U postgres -d postgres -c "create role sbtest login password 'sbtest'" -c "create database sbtest owner sbtest"
  echo "init done" ;;
snapshot)
  B=$PB; $PB/pg_ctl -D $D status >/dev/null 2>&1 || die "not running"
  $B/psql -h /tmp -U sbtest -d sbtest -Atc "select 'sbtest size: '||pg_size_pretty(pg_database_size('sbtest'))"
  $B/vacuumdb -h /tmp -U sbtest -d sbtest -z -j 64 -q && $B/psql -h /tmp -U postgres -d postgres -qc checkpoint
  stopall; mkdir -p $(dirname $G); rm -rf $G.partial
  cp -a $D $G.partial && rm -rf $G && mv $G.partial $G && date -u +%FT%TZ > $G/.snapshot-complete
  echo "golden: $(du -sh $G | cut -f1)" ;;
start)
  B=$(armdir $2)/bin; [ -x $B/postgres ] || die "no $B/postgres"; [ -f $G/.snapshot-complete ] || die "no golden"
  stopall; rm -rf $D; cp -a $G $D; rm -f $D/.snapshot-complete; ulimit -n $(ulimit -Hn)
  $NUMA $PB/pg_ctl -p $B/postgres -D $D -l $L/pg-$2.log -o "-c max_connections=$MAXC" -w -t 600 start >/dev/null || { tail -5 $L/pg-$2.log; die "start $2"; }
  P=$(head -1 $D/postmaster.pid); [ "$(readlink /proc/$P/exe)" = "$B/postgres" ] || { stopall; die "exe mismatch"; }
  echo "started $2 md5=$(md5sum < $B/postgres | cut -c1-12) aff=$(taskset -cp $P | awk '{print $NF}') max_connections=$($PB/psql -h /tmp -U sbtest -d sbtest -Atc 'show max_connections')" ;;
stop) stopall; echo stopped ;;
snap) awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat ;;
snap1) # whole-box total idle, then node-1 CPUs (32-63,128-159) total idle
  awk '$1=="cpu"{for(i=2;i<=NF;i++)T+=$i; I=$5+$6}
    $1~/^cpu[0-9]+$/{c=substr($1,4)+0; if((c>=32&&c<=63)||(c>=128&&c<=159)){for(i=2;i<=NF;i++)t+=$i; id+=$5+$6}}
    END{print T, I, t, id}' /proc/stat ;;
mem-n1|mem-all)
  # postgres must be down; the tmpfs data dir is recreated from golden by the next start anyway
  stopall; if mountpoint -q /mnt/pgramdisk; then sudo umount /mnt/pgramdisk || die umount; fi
  for n in /sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages; do echo 0 | sudo tee $n >/dev/null; done
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
  if [ $1 = mem-n1 ]; then
    echo "node1 free before: $(numactl -H | awk '/node 1 free/{print $4" MB"}')"
    echo 206 | sudo tee /sys/devices/system/node/node1/hugepages/hugepages-1048576kB/nr_hugepages >/dev/null
    sudo mount -t tmpfs -o size=180G,mode=0700,mpol=bind:1 tmpfs /mnt/pgramdisk
  else
    echo 206 | sudo tee $HP >/dev/null
    sudo mount -t tmpfs -o size=180G,mode=0700 tmpfs /mnt/pgramdisk
  fi; sudo chown ec2-user: /mnt/pgramdisk
  echo "hugepages $(cat $HP) per node: $(cat /sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages | tr '\n' ' ')"
  mount | grep pgramdisk; [ $(cat $HP) -ge 206 ] && echo MEM_OK || echo MEM_SHORT ;;
numa)
  numastat -m | grep -E 'Node 0|MemFree|HugePages_Total|HugePages_Free|Shmem |FilePages'
  P=$(head -1 $D/postmaster.pid 2>/dev/null) && [ -n "$P" ] && {
    echo "postmaster $P cpus=$(taskset -cp $P | awk '{print $NF}') $(grep -E '^Mems_allowed_list' /proc/$P/status | tr -s '\t' ' ')"
    echo "policy: $(awk '{print $2}' /proc/$P/numa_maps | sort | uniq -c | sort -nr | head -3 | tr '\n' ' ')"
    numastat -p $P | tail -n 2; } ;;
gcda-clear) echo "stale gcda: $(find $TREE -name '*.gcda' | wc -l)"; find $TREE -name '*.gcda' -delete; echo cleared ;;
gcda-check)
  N=$(find $TREE -name '*.gcda' | wc -l); NB=$(find $TREE/src/backend -name '*.gcda' | wc -l)
  (cd $TREE && find . -name '*.gcda' | tar -czf $W/$GTGZ -T -)
  echo "gcda: $N (backend $NB) size=$(find $TREE -name '*.gcda' -printf '%s\n' | awk '{s+=$1}END{print s}') backup $W/$GTGZ"
  [ $N -gt 700 ] && echo GCDA_OK || echo GCDA_LOW ;;
record)
  OUT=$W/$2-$3.data
  case $2 in
  afdo) sudo perf record -e cycles:u -j any,u -c 800011 --no-buildid --no-buildid-cache \
          -a -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $4 ;;
  bolt) sudo perf record -b -z1 --aio=4 -c 100003 -e branches:u --no-buildid --no-buildid-cache \
          -a -m 128M --proc-map-timeout 5000 -o $OUT -- sleep $4 ;;
  esac > $L/perf-$2-$3.log 2>&1; echo "perf rc=$? size=$(sudo stat -c%s $OUT)"; sudo chown ec2-user: $OUT ;;
afdo-post)
  # --no-buildid leaves the build-id table blank and create_gcov then matches nothing (published finding)
  P=$W/afdo-prep.data; B=/opt/g15-pg18-prep/bin/postgres; O=$W/$AFNAME
  perf inject --build-ids -i $P -o $P.bid > $L/inject.log 2>&1 && mv $P.bid $P || die "inject"
  perf buildid-list -i $P --force 2>/dev/null | grep -Ec "^[0-9a-f]{40} $B$" >/dev/null || die BUILDID_MISSING   # -c not -q: SIGPIPE + pipefail
  /usr/bin/time -v ~/g15/autofdo/build-gcov/create_gcov --binary=$B --profile=$P --gcov=$O --gcov_version=2 > $L/create_gcov.log 2>&1
  SZ=$(stat -c%s $O 2>/dev/null || echo 0); NF=$(~/g15/autofdo/build-gcov/dump_gcov $O 2>/dev/null | grep -c '^[^ ]' || true)
  echo "afdo profile $SZ bytes, $NF functions; top:"; ~/g15/autofdo/build-gcov/dump_gcov $O 2>/dev/null | grep '^[^ ]' | sed -E 's/.*total:([0-9]+).*/\1 &/' | sort -nr | head -3 | cut -d' ' -f2-
  [ "$SZ" -gt 200000 ] && [ "${NF:-0}" -gt 500 ] && echo AFDO_OK || echo AFDO_BAD ;;
waits) $PB/psql -h /tmp -U sbtest -d sbtest -Atc "select coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'-'),count(*) from pg_stat_activity where backend_type='client backend' group by 1 order by 2 desc limit 6" | tr '\n' ' ' ;;
*) grep -E '^#   ' "$0"; exit 1 ;;
esac
