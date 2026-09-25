#!/usr/bin/env bash
# Loopback calibration: postgres on node 0, sysbench on nodes 1-2. Busy% = node-0 CPUs only.
cd ~/pg-lattice
D=/mnt/pgramdisk/pg18sb250; B=${BIN:-/opt/pg18-base/bin}
NODE0=$(cat /sys/devices/system/node/node0/cpulist)
cpus0() { numactl --physcpubind=$NODE0 --show | awk '/^physcpubind/{for(i=2;i<=NF;i++)print $i}'; }
snap() { awk -v L="$(cpus0 | tr '\n' ' ')" 'BEGIN{n=split(L,a," ");for(i=1;i<=n;i++)w["cpu"a[i]]=1}
  ($1 in w){t=0;for(i=2;i<=NF;i++)t+=$i; T+=t; I+=$5+$6} END{print T, I}' /proc/stat; }
ulimit -n $(ulimit -Hn)
pgrep -f "postgres -D $D" >/dev/null || numactl --cpunodebind=0 --membind=0 $B/pg_ctl -D $D -l /mnt/pgramdisk/pg.log -w -t 300 start >/dev/null
for T in ${THREADS:-64 128 256}; do
  numactl --cpunodebind=1,2 --membind=1,2 sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 \
    --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 \
    --threads=$T --time=90 --report-interval=10 --rand-type=uniform oltp_read_write run > logs/calib-$T.log 2>&1 &
  SB=$!
  sleep 30; read T0 I0 < <(snap); sleep 55; read T1 I1 < <(snap)
  wait $SB
  busy=$(awk -v a=$T0 -v b=$T1 -v c=$I0 -v d=$I1 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}')
  tps=$(awk '/^\[ [0-9]+s \]/{s=$2+0; if(s>30){gsub(/tps: /,"");for(i=1;i<=NF;i++)if($i=="tps:"){}}}' logs/calib-$T.log)
  tps=$(grep -E "^\[ [0-9]+s \]" logs/calib-$T.log | awk '{s=$2; sub(/s/,"",s); if(s+0>30){for(i=1;i<=NF;i++) if($i=="tps:"){x+=$(i+1);n++}}} END{printf "%.1f", x/n}')
  echo "threads=$T  node0_busy=${busy}%  tps=$tps  $(grep -E 'transactions:' logs/calib-$T.log | xargs)"
done
