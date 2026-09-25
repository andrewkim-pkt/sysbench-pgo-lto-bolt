#!/usr/bin/env bash
# Full-CPU profile + rebuild of the lattice, driven from the client (akim 2026-09-25: client and server
# separate; train at the >60% server-CPU point). Load = 7x400 = 2800 conns from this box, postgres unpinned
# on all 192 vCPUs with max_connections=4000 (calib: 2800 conns -> 64.1% busy on base). New arms install as
# /opt/pg18fc-<arm>; base, prep and pgogen are profile-independent and reused from /opt/pg18-*.
# Steps (START_AT=N resumes): 1 PGO train  2 build pgo*  3 record afdo  4 create_gcov  5 build afdo*
#   6-9 record bolt on the 4 q arms  10 perf2bolt+llvm-bolt+install x4
set -uo pipefail
cd ~/lat; mkdir -p logs-fc
NPROC=${NPROC:-7}; PER=${PER:-400}; H=<SERVER_PRIVATE_IP>; START_AT=${START_AT:-1}
export PFX=pg18fc SW=pg-lattice/work-fc LW=~/lat/work-fc
S() { timeout ${TO:-900} ssh -n -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 srv "cd ~/pg-lattice && $*"; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
say() { echo "=== [$(date -u +%T)] $*"; }
die() { say "!!! $*"; S "bash fc-srv.sh stop" >/dev/null 2>&1; exit 1; }
gt60() { awk -v b=$1 'BEGIN{exit !(b>60)}'; }
ulimit -n $(ulimit -Hn)
load() { LP=""; for k in $(seq 1 $NPROC); do
  sysbench --db-driver=pgsql --pgsql-host=$H --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
    --pgsql-db=sbtest --tables=250 --table-size=1000000 --threads=$PER --time=$1 --report-interval=30 \
    --rand-type=uniform oltp_read_write run > $2.p$k.log 2>&1 & LP="$LP $!"; done; }
alive() { local p; for p in $LP; do kill -0 $p 2>/dev/null || return 1; done; }
tps() { cat $1.p*.log | grep -E '^ +transactions:' | awk '{gsub(/[()]/,"",$3); s+=$3} END{printf "%.0f", s}'; }
# measured window: <settle> then server/client busy over <secs> (optionally running a server command meanwhile)
window() { sleep $1; read T0 I0 < <(S "bash fc-srv.sh snap"); read C0 J0 < <(csnap)
  if [ -n "${3:-}" ]; then S "$3"; else sleep $2; fi
  read T1 I1 < <(S "bash fc-srv.sh snap"); read C1 J1 < <(csnap)
  BUSY=$(pct $T0 $I0 $T1 $I1); CBUSY=$(pct $C0 $J0 $C1 $J1); }
build() { local tag=$1; shift
  S "setsid nohup bash -c 'env PFX=pg18fc AFDO=/home/ec2-user/pg-lattice/work-fc/pg18.afdo ./pg-build-1n.sh $*; echo BUILD_RC=\$?' > logs/fc-build-$tag.out 2>&1 < /dev/null &" || die "build launch"
  while ! S "grep -q BUILD_RC logs/fc-build-$tag.out" 2>/dev/null; do sleep 60; done
  S "cat logs/fc-build-$tag.out"; S "grep -q BUILD_RC=0 logs/fc-build-$tag.out" || die "build $tag failed"
  for a in "$@"; do S "grep -q '  OK $a\$' logs/fc-build-$tag.out" || die "no OK for $a"; done; }
# busy is averaged over 240 s (perf 60 s + 180 s): tps/busy swing on a ~120 s cycle, a 60 s window is phase-biased
record() { local mode=$1 name=$2 arm=${2#*-} L=logs-fc/rec-$1-${2#*-}
  say "record $mode $name"; S "MAXC=${MAXC:-4000} bash fc-srv.sh start $name" || die "start $name"
  load $((120+240+60)) $L; window 120 240 "bash fc-srv.sh record $mode $name 60; sleep 180"
  alive || die "a sysbench process died during the $mode/$arm record window"; wait $LP
  S "bash fc-srv.sh stop" >/dev/null; say "$mode $arm: server_busy=$BUSY% client_busy=$CBUSY% tps=$(tps $L)"
  TO=3600 S "bash fc-srv.sh post $mode $name $BUSY" | tee $L.post; grep -q RECORD_OK $L.post || die "record $mode $arm not blessed"; }

say "fc-prof start_at=$START_AT load=${NPROC}x$PER"
if [ $START_AT -le 1 ]; then say "1 PGO training (pgogen, 300 s warm + 600 s)"
  S "bash fc-srv.sh stop; bash fc-srv.sh gcda-clear" || die "gcda-clear"
  S "bash fc-srv.sh start pg18-pgogen" || die "start pgogen"
  load 900 logs-fc/train; window 300 590
  alive || die "a sysbench process died during training"; wait $LP
  say "training: server_busy=$BUSY% client_busy=$CBUSY% tps=$(tps logs-fc/train)"
  TO=7500 S "bash fc-srv.sh stop" || die "stop pgogen"
  S "bash fc-srv.sh gcda-check" | tee logs-fc/train.gcda; grep -q GCDA_OK logs-fc/train.gcda || die "gcda low"
  gt60 $BUSY || die "training busy $BUSY% <= 60%"; fi
[ $START_AT -le 2 ] && { say "2 build pgo pgoq pgolto pgoltoq"; build pgo pgo pgoq pgolto pgoltoq; }
[ $START_AT -le 3 ] && record afdo pg18-prep
[ $START_AT -le 4 ] && { say "4 create_gcov"; bash ~/lat-post.sh afdo | tee logs-fc/post-afdo.out; grep -q AFDO_OK logs-fc/post-afdo.out || die "afdo post"; }
[ $START_AT -le 5 ] && { say "5 build afdo afdoq afdolto afdoltoq"; build afdo afdo afdoq afdolto afdoltoq; }
n=6; for q in pgoq pgoltoq afdoq afdoltoq; do [ $START_AT -le $n ] && record bolt pg18fc-$q; n=$((n+1)); done
if [ $START_AT -le 10 ]; then for q in pgoq pgoltoq afdoq afdoltoq; do
  say "10 bolt $q"; bash ~/lat-post.sh bolt $q | tee logs-fc/post-bolt-$q.out; grep -q BOLT_OK logs-fc/post-bolt-$q.out || die "bolt post $q"
  case $q in pgoq) o=pgob;; pgoltoq) o=pgoltob;; afdoq) o=afdob;; afdoltoq) o=afdoltob;; esac
  S "PFX=pg18fc SW=work-fc bash install-bolt.sh $o" || die "install $o"; done; fi
S "for a in pgo pgoq pgolto pgoltoq afdo afdoq afdolto afdoltoq pgob pgoltob afdob afdoltob; do echo \"\$a \$(md5sum < /opt/pg18fc-\$a/bin/postgres | cut -c1-10) \$(md5sum < /opt/pg18-\$a/bin/postgres | cut -c1-10)\"; done" | awk 'BEGIN{print "arm fc_md5 single-node_md5"}{print $0, ($2==$3?"SAME!":"")}'
say FC_PROF_DONE
