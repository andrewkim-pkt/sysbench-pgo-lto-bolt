#!/usr/bin/env bash
# Client-side post-processing. lat-post.sh afdo  -> pg18.afdo from prep
#                              lat-post.sh bolt <q-arm> -> postgres.bolt for the measured BOLT arm
set -uo pipefail
rs() { rsync --rsync-path="numactl --cpunodebind=2 rsync" "$@"; }
W=${LW:-~/lat/work}; SW=${SW:-pg-lattice/work}; P=${PFX:-pg18}; mkdir -p $W; cd $W
CG=~/autofdo/build-gcov/create_gcov; DUMP=~/autofdo/build-gcov/dump_gcov; LB=/opt/llvm-bolt-18.1.3/bin
die() { echo "!!! $*"; exit 1; }
say() { echo "=== [$(date -u +%T)] $*"; }
case ${1:?afdo|bolt} in
afdo)
  ssh srv "test -f ~/$SW/.ok-afdo-prep" || die "server has no blessed afdo-prep recording"
  mkdir -p prep; rs -a srv:/opt/pg18-prep/bin/postgres prep/postgres; rs -a --inplace srv:$SW/afdo-prep.data prep/
  say "create_gcov"; time $CG --binary=prep/postgres --profile=prep/afdo-prep.data --gcov=pg18.afdo --gcov_version=2 > prep/create_gcov.log 2>&1
  SZ=$(stat -c%s pg18.afdo 2>/dev/null || echo 0); NF=$($DUMP pg18.afdo 2>/dev/null | grep -c '^[^ ]' || true)
  echo "    profile size: $SZ bytes (old: 1,576,485)   top-level functions: $NF (old good run: 2,439)"
  [ "$SZ" -gt 200000 ] || die "profile only $SZ bytes"; [ "${NF:-0}" -gt 500 ] || die "only $NF functions"
  md5sum pg18.afdo; rs -a pg18.afdo srv:$SW/pg18.afdo && say "AFDO_OK copied to server" ;;
bolt)
  Q=${2:?q-arm}; case $Q in pgoq) O=pgob;; pgoltoq) O=pgoltob;; afdoq) O=afdob;; afdoltoq) O=afdoltob;; *) die "arm $Q";; esac
  ssh srv "test -f ~/$SW/.ok-bolt-$Q" || die "server has no blessed bolt-$Q recording"
  mkdir -p bolt-$O; cd bolt-$O
  rs -a srv:/opt/$P-$Q/bin/postgres ./postgres; rs -a --inplace srv:$SW/bolt-$Q.data ./perf.data
  say "perf2bolt $Q"; PATH=$LB:$PATH perf2bolt -p perf.data -o profile.fdata ./postgres > perf2bolt.log 2>&1 || die "perf2bolt failed, see perf2bolt.log"
  grep -E "BOLT-INFO: (pre-processing|processing|read|[0-9]+ out of)|samples|mismatch" perf2bolt.log | head -8
  echo "    fdata size: $(stat -c%s profile.fdata)"; [ $(stat -c%s profile.fdata) -gt 100000 ] || die "fdata too small"
  say "llvm-bolt -> $O"
  $LB/llvm-bolt ./postgres -o postgres.bolt -data=profile.fdata -reorder-blocks=ext-tsp -reorder-functions=cdsort \
     -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections > llvm-bolt.log 2>&1 || die "llvm-bolt failed"
  grep -E "BOLT-INFO: (basic block reordering|splitting|[0-9.]+% of|output linked|profile)|BOLT-WARNING" llvm-bolt.log | head -8
  md5sum postgres.bolt; ssh srv "mkdir -p $SW/bolt-$O"; rs -a postgres.bolt profile.fdata srv:$SW/bolt-$O/ && say "BOLT_OK $O copied to server" ;;
esac
