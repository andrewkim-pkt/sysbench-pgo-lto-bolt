#!/usr/bin/env bash
# Single-SNC-node build of the PG 18.3 lattice (akim 2026-09-23: "build all these binaries ... only
# using single node vCPUs"). Every compile, link and LTO job is confined to ONE SNC-3 node, CPUs AND
# memory, with numactl. Flags are the lost 48xl campaign's matrix unchanged, except -flto=N follows the
# node's vCPU count: N is the LTRANS job count only; partitioning comes from --param lto-partitions, so it
# does not change code generation.
#
#   pg-build-1n.sh <arm> [...]      arms: base prep pgogen pgo pgoq pgolto pgoltoq afdo afdoq afdolto afdoltoq
#   NODE=0 (default)  AFDO=/home/ec2-user/pg-lattice/work/pg18.afdo
#
# Arms 4-7 need the pgogen tree's .gcda (PGO training has run); arms 8-11 need $AFDO. Arms 12-15 are
# llvm-bolt outputs of 5/7/9/11 and are produced by pg-bolt.sh, not here.
set -u
NODE=${NODE:-0}
CPUS=$(cat /sys/devices/system/node/node$NODE/cpulist)
JOBS=$(numactl --physcpubind="$CPUS" nproc)
PIN="numactl --cpunodebind=$NODE --membind=$NODE"
SRC=/home/ec2-user/postgres           # REL_18_3, 62d6c7d3df6, tree eacca3d098ca
WORK=/home/ec2-user/pg-lattice/build
LOGS=/home/ec2-user/pg-lattice/logs
AFDO=${AFDO:-/home/ec2-user/pg-lattice/work/pg18.afdo}
CC=/usr/bin/gcc14-gcc
COMMON="-O3 -march=native -mtune=native"
LTO="-flto=$JOBS -ffat-lto-objects"
P="-fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile"
NR="-fno-reorder-blocks-and-partition"
mkdir -p "$WORK" "$LOGS"

die() { echo "FAIL [$ARM]: $*"; exit 1; }

flags() {   # sets CFLAGS LDFLAGS TREE MAKEVARS LTOTOOLS for $ARM
  TREE=$WORK/$ARM; MAKEVARS=""; LTOTOOLS=0
  case $ARM in
    base)     CFLAGS="$COMMON";                               LDFLAGS="" ;;
    prep)     CFLAGS="$COMMON -g";                            LDFLAGS="-Wl,-q" ;;
    pgogen)   CFLAGS="$COMMON -fprofile-generate -fprofile-update=prefer-atomic"
              LDFLAGS="-fprofile-generate"; MAKEVARS="enable_coverage=yes" ;;
    pgo)      CFLAGS="$COMMON $P";                            LDFLAGS="";              TREE=$WORK/pgogen ;;
    pgoq)     CFLAGS="$COMMON $P -g";                         LDFLAGS="-Wl,-q";        TREE=$WORK/pgogen ;;
    pgolto)   CFLAGS="$COMMON $P $LTO";                       LDFLAGS="$LTO";          TREE=$WORK/pgogen; LTOTOOLS=1 ;;
    pgoltoq)  CFLAGS="$COMMON $P $LTO -g";                    LDFLAGS="$LTO -Wl,-q";   TREE=$WORK/pgogen; LTOTOOLS=1 ;;
    afdo)     CFLAGS="$COMMON -fauto-profile=$AFDO";          LDFLAGS="" ;;
    afdoq)    CFLAGS="$COMMON -fauto-profile=$AFDO -g $NR";   LDFLAGS="-Wl,-q" ;;
    # profile on the LINK line only, to avoid a reported gcc 14.2.1 ICE (einline/pp_format) with
    # -flto + -fauto-profile on one compile line. This is a NO-OP: AutoFDO runs per TU at compile
    # time, so these arms are plain LTO (relink.sh: byte-identical .text). Retested 2026-09-30:
    # no ICE on PG 18.3 with gcc 14.2.1 or 15.2.0 with the profile on the compile line. Kept as-is
    # because it is how the published binaries were built.
    afdolto)  CFLAGS="$COMMON $LTO";                          LDFLAGS="$LTO -fauto-profile=$AFDO"; LTOTOOLS=1 ;;
    afdoltoq) CFLAGS="$COMMON $LTO -g $NR"
              LDFLAGS="$LTO -Wl,-q -fauto-profile=$AFDO $NR"; LTOTOOLS=1 ;;
    *) die "unknown arm" ;;
  esac
}

fresh_tree() { rm -rf "$TREE" && mkdir -p "$TREE" && (cd "$SRC" && git archive HEAD) | tar -x -C "$TREE" || die "git archive"; }

# PGO arms reuse the pgogen tree in place (-fprofile-use with no =path reads each .gcda beside its .o).
# Remove every build product but keep .gcda/.gcno. Never make clean -- that deletes the counters.
scrub_pgo_tree() {
  local n; n=$(find "$TREE" -name '*.gcda' | wc -l); [ "$n" -gt 0 ] || die "pgogen tree has 0 .gcda -- run PGO training first"
  find "$TREE" \( -name '*.o' -o -name '*.a' -o -name '*.so' -o -name 'objfiles.txt' \) -delete
  find "$TREE" -type f -perm -u+x -exec sh -c 'head -c4 "$1" | grep -q ELF && rm -f "$1"' _ {} \;
  echo "  kept $n .gcda"
}

build_one() {
  ARM=$1; flags; PREFIX=/opt/${PFX:-pg18}-$ARM; LOG=$LOGS/build-$ARM.log
  case $ARM in afdo*) [ -s "$AFDO" ] || die "no AutoFDO profile at $AFDO";; esac
  echo "=== [$(date -u +%H:%M:%S)] $ARM -> $PREFIX  (node $NODE, cpus $CPUS, -j$JOBS)"
  case $ARM in pgo|pgoq|pgolto|pgoltoq) scrub_pgo_tree ;; *) fresh_tree ;; esac
  local ENVX=""; [ $LTOTOOLS = 1 ] && ENVX="AR=/usr/bin/gcc14-gcc-ar RANLIB=/usr/bin/gcc14-gcc-ranlib NM=/usr/bin/gcc14-gcc-nm"
  cd "$TREE" || die "cd"
  { env $ENVX $PIN ./configure --prefix="$PREFIX" --with-openssl --with-readline \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    && env $ENVX $PIN make -j"$JOBS" $MAKEVARS \
    && sudo rm -rf "$PREFIX" && sudo env $ENVX make install $MAKEVARS; } > "$LOG" 2>&1 || { tail -25 "$LOG"; die "build (log $LOG)"; }
  gate
}

gate() {
  local B=$PREFIX/bin/postgres S; S=$(readelf -SW "$B")
  local text; text=$(echo "$S" | awk '$2==".text"{print strtonum("0x" $6)}')
  printf "  gate: version=[%s] .text=%s debug_line=%s rela.text=%s -O3_in_Makefile=%s\n" \
    "$($B --version)" "$text" "$(echo "$S" | grep -c '\.debug_line')" "$(echo "$S" | grep -c '\.rela\.text')" \
    "$(grep -c -- '-O3' "$TREE/src/Makefile.global")"
  case $ARM in pgo*) printf "  gate: -fprofile-use in build log = %s\n" "$(grep -c -- '-fprofile-use' "$LOG")";; esac
  case $ARM in afdo|afdoq) printf "  gate: -fauto-profile in build log = %s\n" "$(grep -c -- '-fauto-profile' "$LOG")";; esac
  [ "$ARM" = pgogen ] || { local g; g=$(nm "$B" 2>/dev/null | grep -c __gcov_); [ "$g" = 0 ] || die "$g gcov symbols in a non-instrumented binary"; }
  echo "  OK $ARM"
}

[ $# -gt 0 ] || { echo "usage: $0 <arm> [...]"; exit 1; }
for a in "$@"; do build_one "$a"; done
