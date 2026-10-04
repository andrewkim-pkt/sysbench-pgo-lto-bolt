#!/usr/bin/env bash
# CLIENT driver: sysbench-trained gcc 15.2.0 PostgreSQL 18.3 matrix on the new r8i.metal-48xl, then the
# mirrored 64/128-thread benchmark. Runs detached ON the client; resumable with START_AT=<step>.
# postgres is never pinned (all 192 vCPUs). Every profile is taken at >60% server CPU or the chain stops.
# Steps: 0 toolchain  1 build base/prep/pgogen  2 dataset+golden  3 calibrate  4 PGO train
#        5 build pgo/pgolto/pgoltoq  6 record afdo  7 create_gcov  8 build afdo/afdolto/afdoltoq
#        9 record bolt x2  10 llvm-bolt x2  11 md5 list  12 benchmark  13 summary
set -uo pipefail
cd ~/sbp; mkdir -p logs res
H=<PRIVATE_IP>; START_AT=${START_AT:-0}; PER=400
AFDO=/home/ec2-user/g15/work/pg18-g15-sysbench.afdo
S() { timeout ${TO:-900} ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv "cd ~/g15 && $*"; }
say() { echo "=== [$(date -u +%T)] $*"; }
die() { say "!!! $*"; S "./sb-srv.sh stop" >/dev/null 2>&1; exit 1; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
gt60() { awk -v b=$1 'BEGIN{exit !(b>60)}'; }
ulimit -n $(ulimit -Hn)
SB="sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 --rand-type=uniform"
# load <nproc> <threads> <secs> <logprefix>: one sysbench process per <threads> (<=400 each, LuaJIT limit)
load() { LP=""; rm -f $4.p*.log; for k in $(seq 1 $1); do
  $SB --threads=$2 --time=$3 --report-interval=10 oltp_read_write run > $4.p$k.log 2>&1 & LP="$LP $!"; done; }
alive() { local p; for p in $LP; do kill -0 $p 2>/dev/null || return 1; done; }
# tps over the measured window: per process, mean of its 10 s interval tps after <warm> s; summed over processes
ivtps() { for f in $1.p*.log; do awk -v w=$2 '/^\[ [0-9]+s \]/{t=$2; sub(/s/,"",t); if(t+0>w) for(i=1;i<=NF;i++) if($i=="tps:"){s+=$(i+1);n++}} END{print (n?s/n:0)}' $f; done | awk '{s+=$1}END{printf "%.1f", s}'; }
errs() { cat $1.p*.log | grep -ciE 'FATAL|error|PANIC' || true; }
# window <settle> <secs> [server cmd]: server/client busy % over <secs>
window() { sleep $1; read T0 I0 < <(S "./sb-srv.sh snap"); read C0 J0 < <(csnap)
  if [ -n "${3:-}" ]; then S "$3"; else sleep $2; fi
  read T1 I1 < <(S "./sb-srv.sh snap"); read C1 J1 < <(csnap)
  BUSY=$(pct $T0 $I0 $T1 $I1); CBUSY=$(pct $C0 $J0 $C1 $J1); }
# build <arm>...: launched together (separate trees), each gated: rc=0, smoke OK, no FAIL line
build() { local a; S "mkdir -p logs"; for a in "$@"; do
    S "setsid nohup bash -c 'AFDO=$AFDO ./pg-build.sh $a; echo BUILD_RC=\$?' > logs/build-$a.out 2>&1 < /dev/null &" || die "launch $a"; done
  for a in "$@"; do until S "grep -q BUILD_RC logs/build-$a.out" 2>/dev/null; do sleep 30; done
    S "grep -E 'md5  |text bytes|compile lines|smoke|FAIL|BUILD_RC' logs/build-$a.out" | sed "s/^/    [$a] /"
    S "grep -q BUILD_RC=0 logs/build-$a.out && grep -q 'smoke  *: OK' logs/build-$a.out && ! grep -q FAIL logs/build-$a.out" || die "build $a failed"; done; }
# rec <afdo|bolt> <arm>: 120 s settle, perf -a for 60 s inside a 240 s busy window; adds a process until >60%
rec() { local np=$NP try; for try in 1 2 3 4; do
    say "record $1 $2 at ${np}x$PER"; S "./sb-srv.sh start $2" || die "start $2"
    load $np $PER 600 logs/rec-$1-$2; window 120 240 "./sb-srv.sh record $1 $2 60; sleep 180"
    alive || die "sysbench died during $1/$2"; wait $LP; S "./sb-srv.sh stop" >/dev/null
    say "$1 $2: server_busy=$BUSY% client_busy=$CBUSY% tps=$(ivtps logs/rec-$1-$2 120) errs=$(errs logs/rec-$1-$2)"
    gt60 $BUSY && return 0; np=$((np+1)); [ $((np*PER)) -le 3800 ] || break; done; die "$1 $2 never above 60% (max_connections 4000 caps at 9x$PER)"; }

say "sbp start_at=$START_AT"
if [ $START_AT -le 0 ]; then say "0 wait for toolchain"
  until S "grep -q ALL-DONE ~/srv-setup.log" 2>/dev/null; do sleep 60; done
  S "cat gcc.status af.status bolt.status pgsrc.status | grep -E 'OK|FAIL'"
  S "grep -q GCC15-OK gcc.status && grep -q AFDO-OK af.status && grep -q BOLT-OK bolt.status && /opt/gcc15/bin/gcc --version | head -1" || die toolchain
  S "./sb-srv.sh boot"; fi
[ $START_AT -le 1 ] && { say "1 build base prep pgogen"; build base prep pgogen; }
if [ $START_AT -le 2 ]; then say "2 dataset 250 x 1M"
  S "./sb-srv.sh boot; ./sb-srv.sh init" || die init
  $SB --threads=50 oltp_read_write prepare > logs/prepare.log 2>&1 || die "prepare: $(tail -3 logs/prepare.log)"
  TO=3600 S "./sb-srv.sh snapshot" || die snapshot; fi
if [ $START_AT -le 3 ]; then say "3 calibrate on base (x$PER per process, 120 s settle + 240 s)"
  S "./sb-srv.sh start base" || die "start base"; NP=""
  for np in 3 4 5 6 7 8; do load $np $PER 420 logs/cal-$np; window 120 240; alive || die "sysbench died at ${np}x$PER"; wait $LP
    echo -e "$((np*PER))\t$BUSY\t$CBUSY\t$(ivtps logs/cal-$np 120)\t$(errs logs/cal-$np)" | tee -a res/calib.tsv
    awk -v b=$BUSY 'BEGIN{exit !(b>62)}' && { NP=$np; break; }; done
  S "./sb-srv.sh stop" >/dev/null; [ -n "$NP" ] || die "no load point above 62%"; echo $NP > res/NP; fi
NP=$(cat res/NP); say "training load ${NP}x$PER = $((NP*PER)) connections"
if [ $START_AT -le 4 ]; then say "4 PGO training (pgogen, 300 s settle + 590 s)"
  S "./sb-srv.sh gcda-clear" || die gcda-clear; S "./sb-srv.sh start pgogen" || die "start pgogen"
  load $NP $PER 960 logs/train; window 300 590; alive || die "sysbench died in training"; wait $LP
  say "training: server_busy=$BUSY% client_busy=$CBUSY% tps=$(ivtps logs/train 300) errs=$(errs logs/train)"
  TO=7500 S "./sb-srv.sh stop" || die "stop pgogen"
  S "./sb-srv.sh gcda-check" | tee logs/train.gcda; grep -q GCDA_OK logs/train.gcda || die "gcda low"
  gt60 $BUSY || die "training busy $BUSY% <= 60%"; fi
[ $START_AT -le 5 ] && { say "5 build pgo pgolto pgoltoq (same tree, in turn)"; build pgouse; build pgolto; build pgoltoq; }
[ $START_AT -le 6 ] && rec afdo prep
if [ $START_AT -le 7 ]; then say "7 create_gcov"; TO=7200 S "./sb-srv.sh afdo-post" | tee logs/afdo-post.out
  grep -q AFDO_OK logs/afdo-post.out || die "afdo post"; fi
[ $START_AT -le 8 ] && { say "8 build afdo afdolto afdoltoq"; build afdo afdolto afdoltoq; }
[ $START_AT -le 9 ] && { rec bolt pgoltoq; rec bolt afdoltoq; }
if [ $START_AT -le 10 ]; then for q in pgoltoq afdoltoq; do say "10 bolt $q"
  TO=3600 S "./g15-bolt.sh $q work/bolt-$q.data" | tee logs/bolt-$q.out; grep -q 'b md5' logs/bolt-$q.out || die "bolt $q"; done; fi
[ $START_AT -le 11 ] && S 'for a in base prep pgogen pgo pgolto pgoltoq pgoltob afdo afdolto afdoltoq afdoltob; do echo "$a $(md5sum < /opt/g15-pg18-$a/bin/postgres | cut -c1-12) $(readelf -SW /opt/g15-pg18-$a/bin/postgres | grep -c bolt_info)"; done' | tee res/md5.txt
if [ $START_AT -le 12 ]; then say "12 benchmark: mirrored, 64 + 128 threads, 120 s warm + 240 s each"
  A="base afdo afdolto afdoltob pgo pgolto pgoltob"; B=$(echo $A | tr ' ' '\n' | tac | tr '\n' ' ')
  for pass in A B; do for arm in $(eval echo \$$pass); do
    grep -q "^$pass	$arm	128	" res/bench.tsv 2>/dev/null && continue
    S "./sb-srv.sh start $arm" | tee -a logs/bench.log || die "start $arm"
    for th in 64 128; do L=logs/b-$pass-$arm-$th; load 1 $th 400 $L; window 120 240; wait $LP
      echo -e "$pass\t$arm\t$th\t$(ivtps $L 120)\t$BUSY\t$CBUSY\t$(errs $L)" | tee -a res/bench.tsv; done
    S "./sb-srv.sh stop" >/dev/null; done; done; fi
say "13 summary"
awk -F'\t' '{k=$2" "$3; t[k]+=$4; b[k]+=$5; n[k]++}
 END{bt64=t["base 64"]/n["base 64"]; bt128=t["base 128"]/n["base 128"]; bc64=b["base 64"]/t["base 64"]; bc128=b["base 128"]/t["base 128"]
  printf "| arm | 64 threads tps | vs base | 128 threads tps | vs base | mean gain | CPU/txn (64 / 128) | busy 64/128 |\n|---|---|---|---|---|---|---|---|\n"
  split("base afdo afdolto afdoltob pgo pgolto pgoltob",A," ")
  for(i=1;i<=7;i++){x=A[i]; m64=t[x" 64"]/n[x" 64"]; m128=t[x" 128"]/n[x" 128"]; g64=100*m64/bt64-100; g128=100*m128/bt128-100
   c64=100*(b[x" 64"]/t[x" 64"])/bc64-100; c128=100*(b[x" 128"]/t[x" 128"])/bc128-100
   printf "| %s | %.0f | %+.2f%% | %.0f | %+.2f%% | %+.2f%% | %+.1f%% / %+.1f%% | %.1f%% / %.1f%% |\n",x,m64,g64,m128,g128,(g64+g128)/2,c64,c128,b[x" 64"]/n[x" 64"],b[x" 128"]/n[x" 128"]}}' res/bench.tsv | tee res/summary.md
say SBP_DONE
