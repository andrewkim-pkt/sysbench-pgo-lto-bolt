#!/usr/bin/env bash
# PGO training: restore golden, clear stale .gcda, run pgogen on node 0, load from nodes 1-2 over loopback.
set -euo pipefail
cd ~/pg-lattice
D=/mnt/pgramdisk/pg18sb250; G=/var/lib/pg18-lattice/pg18sb250-golden
B=/opt/pg18-pgogen/bin; TREE=/home/ec2-user/pg-lattice/build/pgogen
T=${THREADS:-128}; WARM=${WARM:-300}; RUN=${RUN:-600}
NODE0=$(cat /sys/devices/system/node/node0/cpulist)
cpus0() { numactl --physcpubind=$NODE0 --show | awk '/^physcpubind/{for(i=2;i<=NF;i++)print $i}'; }
snap() { awk -v L="$(cpus0 | tr '\n' ' ')" 'BEGIN{n=split(L,a," ");for(i=1;i<=n;i++)w["cpu"a[i]]=1}
  ($1 in w){t=0;for(i=2;i<=NF;i++)t+=$i; T+=t; I+=$5+$6} END{print T, I}' /proc/stat; }
ulimit -n $(ulimit -Hn)
for p in $(pgrep -f "bin/postgres -D $D" || true); do
  $(dirname $(readlink /proc/$p/exe))/pg_ctl -D $D -m fast -w -t 1800 stop; done
echo "restore $(date -u +%T)"; rm -rf $D; cp -a $G $D; echo "restored $(date -u +%T) $(du -sh $D | cut -f1)"
echo "stale gcda: $(find $TREE -name '*.gcda' | wc -l)"; find $TREE -name '*.gcda' -delete
numactl --cpunodebind=0 --membind=0 $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-train.log -w -t 600 start
P=$(head -1 $D/postmaster.pid); echo "postmaster exe=$(readlink /proc/$P/exe) aff=$(taskset -cp $P | awk '{print $NF}')"
numactl --cpunodebind=1,2 --membind=1,2 sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 \
  --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 \
  --threads=$T --time=$((WARM+RUN)) --report-interval=30 --rand-type=uniform oltp_read_write run > logs/train-pgogen.log 2>&1 &
SB=$!
sleep $WARM; read T0 I0 < <(snap); sleep $((RUN-10)); read T1 I1 < <(snap)
wait $SB
echo "threads=$T node0_busy_counted=$(awk -v a=$T0 -v b=$T1 -v c=$I0 -v d=$I1 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}')%"
grep -E 'transactions:|errors:' logs/train-pgogen.log | xargs
$B/pg_ctl -D $D -m fast -w -t 1800 stop
echo "gcda after: $(find $TREE -name '*.gcda' | wc -l)  size=$(find $TREE -name '*.gcda' -printf '%s\n' | awk '{s+=$1}END{print s}')"
echo TRAIN_DONE
