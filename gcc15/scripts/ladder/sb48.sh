#!/usr/bin/env bash
# CLIENT driver: sysbench oltp_read_write on the 48xl, 250 tables x 2.4M rows (~300 GB, the size of the 1536 WH
# TPROC-C set), threads 32..1024. Arms: base, sbpgoltob (sysbench-trained), hdbpgoltob (HammerDB-trained).
# Mirrored passes, one server start (fresh golden restore) per pass, 120 s warm + 240 s measured per rung.
# Runs detached ON the client; resumable (step 1 skipped once res/golden.ok exists, done rungs skipped).
set -uo pipefail
cd ~/sb48; mkdir -p logs res
H=<PRIVATE_IP>; PER=256
S() { timeout ${TO:-1800} ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv48 "cd ~/g15 && $*"; }
say() { echo "=== [$(date -u +%T)] $*"; }
die() { say "!!! $*"; exit 1; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
ulimit -n $(ulimit -Hn)
SB="sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=2400000 --rand-type=uniform"
# load <threads> <secs> <logprefix>: ceil(threads/PER) sysbench processes, threads split evenly
load() { LP=""; rm -f $3.p*.log; local np=$(( ($1 + PER - 1) / PER )); for k in $(seq 1 $np); do
  $SB --threads=$(( $1 / np )) --time=$2 --report-interval=10 oltp_read_write run > $3.p$k.log 2>&1 & LP="$LP $!"; done; }
ivtps() { for f in $1.p*.log; do awk -v w=$2 '/^\[ [0-9]+s \]/{t=$2; sub(/s/,"",t); if(t+0>w) for(i=1;i<=NF;i++) if($i=="tps:"){s+=$(i+1);n++}} END{print (n?s/n:0)}' $f; done | awk '{s+=$1}END{printf "%.1f", s}'; }
ivlat() { for f in $1.p*.log; do awk -v w=$2 '/^\[ [0-9]+s \]/{t=$2; sub(/s/,"",t); if(t+0>w) for(i=1;i<=NF;i++) if($i=="(ms;95%):"){s+=$(i+1);n++}} END{print (n?s/n:0)}' $f; done | awk '{s+=$1;n++}END{printf "%.2f", s/n}'; }
errs() { cat $1.p*.log | grep -ciE 'FATAL|error|PANIC' || true; }

say "sb48 start"
S "touch ~/keepalive.stop"
if [ ! -f res/golden.ok ]; then say "1 dataset 250 x 2.4M"
  S "for b in /opt/g15-pg18-*/bin; do \$b/pg_ctl -D /mnt/pgramdisk/g15data status >/dev/null 2>&1 && { \$b/pg_ctl -D /mnt/pgramdisk/g15data -m immediate -w stop; break; }; done; rm -rf /mnt/pgramdisk/g15data /mnt/pgramdisk/sb48data; ./sb48-srv.sh init" || die init
  $SB --threads=64 oltp_read_write prepare > logs/prepare.log 2>&1 || die "prepare: $(tail -3 logs/prepare.log)"
  TO=7200 S "./sb48-srv.sh snapshot" | tee res/golden.txt || die snapshot
  grep -q golden: res/golden.txt && touch res/golden.ok || die "snapshot failed"; fi
S 'for a in /opt/g15-pg18-base /opt/g15sb-pg18-pgoltob /opt/g15-pg18-pgoltob; do echo "$a $(md5sum < $a/bin/postgres | cut -c1-12) bolt=$(readelf -SW $a/bin/postgres | grep -c bolt_info)"; done' | tee res/md5.txt
say "2 ladder: mirrored, 32..1024 threads, 120 s warm + 240 s each"
P=1
for arm in base sbpgoltob hdbpgoltob hdbpgoltob sbpgoltob base; do
  pass=$(printf %02d $P)-$arm; P=$((P+1))
  grep -q "^$pass	1024	" res/bench.tsv 2>/dev/null && continue
  S "./sb48-srv.sh start $arm" | tee -a logs/bench.log || die "start $arm"
  for th in 32 64 128 256 512 1024; do
    grep -q "^$pass	$th	" res/bench.tsv 2>/dev/null && continue
    L=logs/b-$pass-$th; load $th 380 $L; sleep 120
    read K0 <<< "$(S './sb48-srv.sh ckpt' | cut -d' ' -f1)"; read T0 I0 < <(S "./sb48-srv.sh snap"); read C0 J0 < <(csnap)
    sleep 240
    read T1 I1 < <(S "./sb48-srv.sh snap"); read C1 J1 < <(csnap); CK=$(S './sb48-srv.sh ckpt')
    wait $LP
    echo -e "$pass\t$th\t$(ivtps $L 120)\t$(pct $T0 $I0 $T1 $I1)\t$(pct $C0 $J0 $C1 $J1)\t$(ivlat $L 120)\t$(errs $L)\t$(( ${CK%% *} - K0 ))\t$(echo $CK | cut -d' ' -f2)" | tee -a res/bench.tsv
  done
  S "./sb48-srv.sh stop" >/dev/null
done
# columns: pass threads tps server_busy% client_busy% p95_ms errors checkpoints_in_window autovac_workers
say "3 summary"
awk -F'\t' '{split($1,a,"-"); arm=substr($1,4); k=arm" "$2; t[k]+=$3; b[k]+=$4; n[k]++; th[$2]=1}
 END{printf "| threads | base tps | sbpgoltob | vs base | hdbpgoltob | vs base | busy base/sb/hdb | CPU/txn sb / hdb |\n|---|---|---|---|---|---|---|---|\n"
  split("32 64 128 256 512 1024",T," ")
  for(i=1;i<=6;i++){x=T[i]; B=t["base "x]/n["base "x]; s=t["sbpgoltob "x]/n["sbpgoltob "x]; h=t["hdbpgoltob "x]/n["hdbpgoltob "x]
   bb=b["base "x]/n["base "x]; bs=b["sbpgoltob "x]/n["sbpgoltob "x]; bh=b["hdbpgoltob "x]/n["hdbpgoltob "x]
   gs=100*s/B-100; gh=100*h/B-100; ms+=gs; mh+=gh
   printf "| %s | %.0f | %.0f | %+.2f%% | %.0f | %+.2f%% | %.1f/%.1f/%.1f | %+.1f%% / %+.1f%% |\n",x,B,s,gs,h,gh,bb,bs,bh,100*(bs/s)/(bb/B)-100,100*(bh/h)/(bb/B)-100}
  printf "| mean | | | %+.2f%% | | %+.2f%% | | |\n",ms/6,mh/6}' res/bench.tsv | tee res/summary.md
S "rm -f ~/keepalive.stop; nohup ~/keepalive.sh >/dev/null 2>&1 &"
say SB48_DONE
