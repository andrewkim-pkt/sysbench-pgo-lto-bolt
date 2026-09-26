#!/usr/bin/env bash
# Mirrored base-vs-afdoltob benchmark on the r8i.16xlarge (64 vCPU, 84-table dataset), driven from the client. Derived from fc-mirror.sh.
# Load = NPROC sysbench processes x PER threads over the VPC. ROUNDS x (pass A = ARMS forward, pass B = reversed).
# tps = sum over processes of each process's mean interval tps after WARM. Golden restore every run.
set -uo pipefail
cd ~/lat16; mkdir -p results
ARMS=${ARMS:-"pg18-base pg18fc-afdoltob"}; ROUNDS=${ROUNDS:-2}
NPROC=${NPROC:?}; PER=${PER:?}; WARM=${WARM:-600}; MEAS=${MEAS:-240}; H=<SERVER_PRIVATE_IP>
# RESUME=<existing OUT dir> ONLY="B:7:pgolto B:8:pgo" appends just those runs, then re-summarises.
TS=$(date -u +%Y%m%dT%H%M%SZ); OUT=${RESUME:-results/pg16-mirror-$((NPROC*PER))c-$TS}; mkdir -p $OUT; TSV=$OUT/runs.tsv
# keepalives + a hard cap so a dead VPC link fails the run instead of hanging (seen 2026-09-25 02:56)
S() { timeout 1800 ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv16 "cd ~/pg-lattice && bash fc16-srv.sh $*"; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
ulimit -n $(ulimit -Hn)
REV=$(echo $ARMS | tr ' ' '\n' | tac | xargs)
if [ -n "${RESUME:-}" ]; then echo "resume $TS: $ONLY" | tee -a $OUT/campaign.log; else
echo "campaign $TS conns=${NPROC}x$PER rounds=$ROUNDS warm=$WARM meas=$MEAS host=$H  A: $ARMS  B: $REV" | tee $OUT/campaign.log
printf "pass\tseq\tarm\ttps\tqps\tp95_ms\terr_s\tsrv_busy\tcli_busy\tmd5\tstart_utc\n" > $TSV; fi
run() { local pass=$1 seq=$2 name=$3 arm=${3#*-} L=$OUT/$1-$2-${3#*-}
  local R; R=$(S start $name) || { echo "!!! $name $R" | tee -a $OUT/campaign.log; return; }
  local MD5=$(S md5 $name) ST=$(date -u +%T) pids=""
  for k in $(seq 1 $NPROC); do
    sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
      --pgsql-db=sbtest --tables=84 --table-size=1000000 --threads=$PER --time=$((WARM+MEAS)) \
      --report-interval=10 --rand-type=uniform oltp_read_write run > $L.p$k.log 2>&1 & pids="$pids $!"
  done
  sleep $WARM; read T0 I0 < <(S snap); read C0 J0 < <(csnap)
  for w in 1 2 3 4 5 6 7 8; do echo "$(date -u +%T) $(S waits $name)" >> $L.waits; sleep 25; done
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
for r in $(seq 1 $ROUNDS); do
  i=0; for a in $ARMS; do i=$((i+1)); run A$r $i $a; done
  i=0; for a in $REV;  do i=$((i+1)); run B$r $i $a; done
done
fi
# per arm over all runs: mean tps, min/max, (max-min)/mean, mean server busy, CPU per txn (busy/tps) vs base
awk -F'\t' 'NR>1{s[$3]+=$4; n[$3]++; c[$3]+=$8/$4; u[$3]+=$8; if(!($3 in lo)||$4<lo[$3])lo[$3]=$4; if($4>hi[$3])hi[$3]=$4}
  END{b=s["base"]/n["base"]; cb=c["base"]/n["base"];
  printf "%-9s %4s %10s %10s %10s %8s %7s %6s %9s\n","arm","runs","mean","min","max","vs_base","range","busy%","cpu/txn";
  for(k in s){m=s[k]/n[k]; printf "%-9s %4d %10.1f %10.1f %10.1f %+7.2f%% %6.2f%% %6.1f %+8.1f%%\n",k,n[k],m,lo[k],hi[k],100*(m/b-1),100*(hi[k]-lo[k])/m,u[k]/n[k],100*(c[k]/n[k]/cb-1)}}' $TSV |
  (read h; echo "$h"; sort -k6 -gr) | tee $OUT/summary.txt
echo MIRROR_DONE | tee -a $OUT/campaign.log
