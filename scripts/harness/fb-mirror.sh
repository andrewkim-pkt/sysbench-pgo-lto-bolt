#!/usr/bin/env bash
# Full-box mirrored measurement, driven from the client. Server postgres unpinned on all 192 vCPUs.
# Load = NPROC sysbench processes x PER threads over the VPC. Pass A = ARMS forward, B = reversed.
# tps = sum over processes of each process's mean interval tps after WARM. Golden restore every run.
set -uo pipefail
cd ~/lat; mkdir -p results
ARMS=${ARMS:-"base pgo pgolto afdo afdolto pgob pgoltob afdob afdoltob"}
NPROC=${NPROC:-3}; PER=${PER:-400}; WARM=${WARM:-600}; MEAS=${MEAS:-180}; H=<SERVER_PRIVATE_IP>
# RESUME=<existing OUT dir> ONLY="B:7:pgolto B:8:pgo" appends just those runs, then re-summarises.
TS=$(date -u +%Y%m%dT%H%M%SZ); OUT=${RESUME:-results/fb-mirror-$((NPROC*PER))c-$TS}; mkdir -p $OUT; TSV=$OUT/runs.tsv
# keepalives + a hard cap so a dead VPC link fails the run instead of hanging (seen 2026-09-25 02:56)
S() { timeout 1800 ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv "bash ~/pg-lattice/fb-arm.sh $*"; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
ulimit -n $(ulimit -Hn)
REV=$(echo $ARMS | tr ' ' '\n' | tac | xargs)
if [ -n "${RESUME:-}" ]; then echo "resume $TS: $ONLY" | tee -a $OUT/campaign.log; else
echo "campaign $TS conns=${NPROC}x$PER warm=$WARM meas=$MEAS host=$H  A: $ARMS  B: $REV" | tee $OUT/campaign.log
printf "pass\tseq\tarm\ttps\tqps\tp95_ms\terr_s\tsrv_busy\tcli_busy\tmd5\tstart_utc\n" > $TSV; fi
run() { local pass=$1 seq=$2 arm=$3 L=$OUT/$1-$2-$3
  local R; R=$(S start $arm) || { echo "!!! $arm $R" | tee -a $OUT/campaign.log; return; }
  local MD5=${R%% *} ST=$(date -u +%T) pids=""
  for k in $(seq 1 $NPROC); do
    sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
      --pgsql-db=sbtest --tables=250 --table-size=1000000 --threads=$PER --time=$((WARM+MEAS)) \
      --report-interval=10 --rand-type=uniform oltp_read_write run > $L.p$k.log 2>&1 & pids="$pids $!"
  done
  sleep $WARM; read T0 I0 < <(S snap); read C0 J0 < <(csnap)
  for w in 1 2 3 4 5 6; do echo "$(date -u +%T) $(S waits $arm)" >> $L.waits; sleep 25; done
  read T1 I1 < <(S snap); read C1 J1 < <(csnap); wait $pids
  local SB=$(pct $T0 $I0 $T1 $I1) CB=$(pct $C0 $J0 $C1 $J1)
  read TPS QPS P95 ERR < <(for k in $(seq 1 $NPROC); do grep -E '^\[ [0-9]+s \]' $L.p$k.log | awk -v w=$WARM '{s=$2; sub(/s/,"",s); if(s+0>w){
      for(i=1;i<=NF;i++){ if($i=="tps:")t+=$(i+1); if($i=="qps:")q+=$(i+1); if($i=="(ms,95%):")p+=$(i+1); if($i=="err/s:")e+=$(i+1)} n++}}
      END{if(n) printf "%.2f %.2f %.2f %.3f %d\n", t/n, q/n, p/n, e/n, n; else print "0 0 0 0 0"}'; done |
      awk -v N=$NPROC '{t+=$1;q+=$2;p+=$3;e+=$4; if($5>0)ok++} END{if(ok<N) t=q=0; printf "%.2f %.2f %.2f %.3f\n", t,q,p/N,e}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $pass $seq $arm $TPS $QPS $P95 $ERR $SB $CB $MD5 $ST >> $TSV
  echo "[$(date -u +%T)] $pass/$seq $arm tps=$TPS srv_busy=$SB% cli_busy=$CB% p95=$P95 err/s=$ERR" | tee -a $OUT/campaign.log
  S stop; }
if [ -n "${RESUME:-}" ]; then for r in $ONLY; do IFS=: read p q a <<< "$r"; run $p $q $a; done
else
i=0; for a in $ARMS; do i=$((i+1)); run A $i $a; done
i=0; for a in $REV;  do i=$((i+1)); run B $i $a; done
fi
awk -F'\t' 'NR>1{s[$3]+=$4; n[$3]++; v[$3,$1]=$4} END{b=s["base"]/n["base"];
  printf "%-9s %10s %10s %10s %8s %7s\n","arm","A","B","mean","vs_base","spread";
  for(k in s){m=s[k]/n[k]; printf "%-9s %10.1f %10.1f %10.1f %+7.2f%% %6.2f%%\n",k,v[k,"A"],v[k,"B"],m,100*(m/b-1),100*(v[k,"A"]-v[k,"B"])/m}}' $TSV |
  (read h; echo "$h"; sort -k5 -gr) | tee $OUT/summary.txt
echo MIRROR_DONE | tee -a $OUT/campaign.log
