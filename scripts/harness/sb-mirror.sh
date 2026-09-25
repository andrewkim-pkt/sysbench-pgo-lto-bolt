#!/usr/bin/env bash
# Mirrored measurement: pass A = ARMS forward, pass B = reversed. Golden restore before every run.
# postgres on node 0, sysbench on nodes 1-2 over loopback. tps = mean of the report intervals after WARM.
set -uo pipefail
cd ~/pg-lattice; mkdir -p results
ARMS=${ARMS:-"base pgo pgolto afdo afdolto pgob pgoltob afdob afdoltob"}
T=${THREADS:-128}; WARM=${WARM:-600}; MEAS=${MEAS:-180}
D=/mnt/pgramdisk/pg18sb250; G=/var/lib/pg18-lattice/pg18sb250-golden
TS=$(date -u +%Y%m%dT%H%M%SZ); OUT=results/sb-mirror-${T}T-$TS; mkdir -p $OUT; TSV=$OUT/runs.tsv
NODE0=$(cat /sys/devices/system/node/node0/cpulist)
cpus0() { numactl --physcpubind=$NODE0 --show | awk '/^physcpubind/{for(i=2;i<=NF;i++)print $i}'; }
snap() { awk -v L="$(cpus0 | tr '\n' ' ')" 'BEGIN{n=split(L,a," ");for(i=1;i<=n;i++)w["cpu"a[i]]=1}
  ($1 in w){t=0;for(i=2;i<=NF;i++)t+=$i; T+=t; I+=$5+$6} END{print T, I}' /proc/stat; }
stopall() { for p in $(pgrep -f "bin/postgres -D $D" || true); do $(dirname $(readlink /proc/$p/exe))/pg_ctl -D $D -m fast -w -t 1800 stop >/dev/null; done; }
ulimit -n $(ulimit -Hn)
REV=$(echo $ARMS | tr ' ' '\n' | tac | xargs)
echo "campaign $TS threads=$T warm=$WARM meas=$MEAS  A: $ARMS  B: $REV" | tee $OUT/campaign.log
printf "pass\tseq\tarm\ttps\tqps\tp95_ms\terr_s\tnode0_busy\tmd5\tstart_utc\n" > $TSV
run() { local pass=$1 seq=$2 arm=$3 B=/opt/pg18-$3/bin L=$OUT/$1-$2-$3.log
  stopall; rm -rf $D; cp -a $G $D
  numactl --cpunodebind=0 --membind=0 $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-mirror.log -w -t 600 start >/dev/null || { echo "!!! start $arm"; return; }
  local P=$(head -1 $D/postmaster.pid); local EXE=$(readlink /proc/$P/exe)
  [ "$EXE" = "$B/postgres" ] || { echo "!!! $arm exe=$EXE"; stopall; return; }
  local ST=$(date -u +%T)
  numactl --cpunodebind=1,2 --membind=1,2 sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 \
    --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 \
    --threads=$T --time=$((WARM+MEAS)) --report-interval=10 --rand-type=uniform oltp_read_write run > $L 2>&1 &
  local SB=$!
  sleep $WARM; read T0 I0 < <(snap); sleep $((MEAS-5)); read T1 I1 < <(snap); wait $SB
  local BUSY=$(awk -v a=$T0 -v b=$T1 -v c=$I0 -v d=$I1 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}')
  read TPS QPS P95 ERR < <(grep -E '^\[ [0-9]+s \]' $L | awk -v w=$WARM '{s=$2; sub(/s/,"",s); if(s+0>w){
      for(i=1;i<=NF;i++){ if($i=="tps:")t+=$(i+1); if($i=="qps:")q+=$(i+1); if($i=="(ms,95%):")p+=$(i+1); if($i=="err/s:")e+=$(i+1)} n++}}
      END{printf "%.2f %.2f %.2f %.3f\n", t/n, q/n, p/n, e/n}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $pass $seq $arm $TPS $QPS $P95 $ERR $BUSY $(md5sum < $B/postgres | cut -c1-10) $ST >> $TSV
  echo "[$(date -u +%T)] $pass/$seq $arm tps=$TPS busy=$BUSY% p95=$P95 err/s=$ERR tmpfs=$(df -h --output=used /mnt/pgramdisk | tail -1)" | tee -a $OUT/campaign.log
  stopall; }
i=0; for a in $ARMS; do i=$((i+1)); run A $i $a; done
i=0; for a in $REV;  do i=$((i+1)); run B $i $a; done
awk -F'\t' 'NR>1{s[$3]+=$4; n[$3]++; v[$3,$1]=$4} END{b=s["base"]/n["base"];
  printf "%-9s %10s %10s %10s %8s %7s\n","arm","A","B","mean","vs_base","spread";
  for(k in s){m=s[k]/n[k]; printf "%-9s %10.1f %10.1f %10.1f %+7.2f%% %6.2f%%\n",k,v[k,"A"],v[k,"B"],m,100*(m/b-1),100*(v[k,"A"]-v[k,"B"])/m}}' $TSV | sort -k5 -t' ' | tee $OUT/summary.txt
echo MIRROR_DONE | tee -a $OUT/campaign.log
