#!/usr/bin/env bash
# Client-driven load sweep: find the conns where the (unpinned, 192-vCPU) server passes 60% busy.
# fc-calib.sh "3 5 7 9"   = number of sysbench processes x PER threads each (<=400; >512 per process dies)
set -uo pipefail
cd ~/lat; mkdir -p calib-fc
PER=${PER:-400}; SETTLE=${SETTLE:-60}; MEAS=${MEAS:-60}; H=<SERVER_PRIVATE_IP>; B=${BIN:-/opt/pg18-base/bin}
MAXC=${MAXC:-4000}; D=/mnt/pgramdisk/pg18sb250
S() { timeout 900 ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv "$*"; }
ssnap='awk '"'"'$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}'"'"' /proc/stat'
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
ulimit -n $(ulimit -Hn)
S "for p in \$(pgrep -f '[b]in/postgres -D $D'); do \$(dirname \$(readlink /proc/\$p/exe))/pg_ctl -D $D -m fast -w -t 1800 stop; done
   ulimit -n \$(ulimit -Hn); $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-calib.log -o '-c max_connections=$MAXC' -w -t 600 start >/dev/null && echo started max_connections=$MAXC" || exit 1
for n in ${1:-3 5 7 9}; do
  pids=""; for k in $(seq 1 $n); do
    sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
      --pgsql-db=sbtest --tables=250 --table-size=1000000 --threads=$PER --time=$((SETTLE+MEAS+10)) \
      --report-interval=10 --rand-type=uniform oltp_read_write run > calib-fc/n$n.p$k.log 2>&1 & pids="$pids $!"; done
  sleep $SETTLE; read T0 I0 < <(S "$ssnap"); read C0 J0 < <(csnap); sleep $MEAS; read T1 I1 < <(S "$ssnap"); read C1 J1 < <(csnap)
  wait $pids
  TPS=$(for k in $(seq 1 $n); do grep -E '^\[ [0-9]+s \]' calib-fc/n$n.p$k.log | awk -v w=$SETTLE '{s=$2; sub(/s/,"",s); if(s+0>w) for(i=1;i<=NF;i++) if($i=="tps:"){t+=$(i+1);m++}} END{if(m) print t/m; else print 0}'; done | awk '{s+=$1} END{printf "%.0f", s}')
  P95=$(grep -h -E '^\[ (1[0-3][0-9])s \]' calib-fc/n$n.p1.log | awk '{for(i=1;i<=NF;i++) if($i=="(ms,95%):"){s+=$(i+1);m++}} END{if(m) printf "%.1f", s/m}')
  DEAD=$(grep -lE "FATAL|too many clients" calib-fc/n$n.p*.log 2>/dev/null | wc -l)
  echo "conns=$((n*PER)) (${n}x$PER) srv_busy=$(pct $T0 $I0 $T1 $I1)% cli_busy=$(pct $C0 $J0 $C1 $J1)% tps=$TPS p95=${P95}ms failed_procs=$DEAD"
done
S "$B/pg_ctl -D $D -m fast -w -t 1800 stop >/dev/null; echo stopped"
echo CALIB_DONE
