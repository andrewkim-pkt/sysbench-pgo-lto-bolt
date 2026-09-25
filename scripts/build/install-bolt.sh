#!/usr/bin/env bash
# install-bolt.sh <bolted-arm>: /opt/pg18-<q twin> tree with bin/postgres replaced by work/bolt-<arm>/postgres.bolt
set -euo pipefail
O=${1:?pgob|pgoltob|afdob|afdoltob}
case $O in pgob) Q=pgoq;; pgoltob) Q=pgoltoq;; afdob) Q=afdoq;; afdoltob) Q=afdoltoq;; *) echo "bad arm"; exit 1;; esac
BIN=~/pg-lattice/${SW:-work}/bolt-$O/postgres.bolt; [ -s $BIN ] || { echo "no $BIN"; exit 1; }
P=${PFX:-pg18}; sudo rm -rf /opt/$P-$O; sudo cp -a /opt/$P-$Q /opt/$P-$O; sudo install -m 755 $BIN /opt/$P-$O/bin/postgres
V=$(/opt/$P-$O/bin/postgres --version)
echo "$O <- $Q : $V  md5=$(md5sum < /opt/$P-$O/bin/postgres | cut -c1-12)  bolt_note=$(readelf -S /opt/$P-$O/bin/postgres | grep -c '\.bolt\|\.note\.bolt_info')"
