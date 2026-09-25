#!/usr/bin/env bash
# Server-side helper for the full-box mirror (all 192 vCPUs, no numactl).
#   start <arm> : stop any postmaster, restore golden, start /opt/pg18-<arm> unpinned, print "md5 cpus"
#   stop        : fast stop
#   snap        : all-CPU "total idle" jiffies from /proc/stat
#   waits <arm> : one pg_stat_activity wait-event sample (type:event count)
set -uo pipefail
D=/mnt/pgramdisk/pg18sb250; G=/var/lib/pg18-lattice/pg18sb250-golden
stopall() { for p in $(pgrep -f "bin/postgres -D $D" || true); do $(dirname $(readlink /proc/$p/exe))/pg_ctl -D $D -m fast -w -t 1800 stop >/dev/null; done; }
case $1 in
start) B=/opt/pg18-$2/bin; stopall; rm -rf $D; cp -a $G $D; ulimit -n $(ulimit -Hn)
  $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-mirror.log -w -t 600 start >/dev/null || { echo "START_FAIL"; exit 1; }
  P=$(head -1 $D/postmaster.pid); [ "$(readlink /proc/$P/exe)" = "$B/postgres" ] || { echo "EXE_MISMATCH"; stopall; exit 1; }
  echo "$(md5sum < $B/postgres | cut -c1-10) $(awk '/Cpus_allowed_list/{print $2}' /proc/$P/status)";;
stop) stopall;;
snap) awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat;;
waits) /opt/pg18-$2/bin/psql -h /tmp -U sbtest -d sbtest -Atc "select coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'-'),count(*) from pg_stat_activity where backend_type='client backend' group by 1 order by 2 desc limit 8" | tr '\n' ' ';;
esac
