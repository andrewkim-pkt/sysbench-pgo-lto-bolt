#!/usr/bin/env bash
# Server side of the 24xl sysbench oltp_read_write ladder (cloned from sb48-srv.sh) (base vs sysbench-trained vs HammerDB-trained pgoltob).
# Runs ON the 24xl; the client (sb24.sh) calls these subcommands over ssh. postgres is never pinned.
#   mount | huge           tmpfs 450G mpol=interleave | reserve 201 x 1G hugepages (do this early after boot)
#   init | snapshot          new cluster + sbtest role/db | analyze, checkpoint, stop, golden copy to EBS
#   start <arm> | stop       golden restore + start | immediate stop
#   snap | ckpt              /proc/stat jiffies | checkpoint count, autovacuum workers, client backends
# Arms: base=/opt/g15-pg18-base  sbpgoltob=/opt/g15sb-pg18-pgoltob (sysbench-trained, whole box)
#       hdbpgoltob=/opt/g15-pg18-pgoltob (HammerDB-trained, node 1)
# Config: the 24xl HammerDB config (192 GB shared_buffers on 201 x 1G hugepages, tmpfs 450G mpol=interleave)
# with the perf-capture overrides: no autovacuum, no checkpoint inside a pass.
set -uo pipefail
D=/mnt/pgramdisk/sb24data; G=/home/ec2-user/sb24-golden/sb24data; L=/home/ec2-user/g15/logs; PB=/opt/g15-pg18-base/bin
mkdir -p $L
die() { echo "FATAL: $*"; exit 1; }
armdir() { case $1 in base) echo /opt/g15-pg18-base;; sbpgoltob) echo /opt/g15sb-pg18-pgoltob;; hdbpgoltob) echo /opt/g15-pg18-pgoltob;; *) die "arm $1";; esac; }
stopall() { $PB/pg_ctl -D $D status >/dev/null 2>&1 && $PB/pg_ctl -D $D -m immediate -w stop >/dev/null; true; }
conf() { cat > $D/postgresql.conf <<'CONF'
listen_addresses = '*'
port = 5432
unix_socket_directories = '/tmp'
max_connections = 2500
shared_buffers = 192GB
effective_cache_size = 550GB
huge_pages = on
huge_page_size = 1GB
work_mem = 8MB
maintenance_work_mem = 4GB
max_files_per_process = 4000
synchronous_commit = off
full_page_writes = off
wal_level = minimal
max_wal_senders = 0
wal_buffers = 1GB
min_wal_size = 24GB
random_page_cost = 1.0
seq_page_cost = 1.0
effective_io_concurrency = 200
jit = off
bgwriter_delay = 10ms
bgwriter_lru_maxpages = 1000
max_locks_per_transaction = 256
logging_collector = off
log_min_messages = warning
# no autovacuum and no checkpoint inside a pass
autovacuum = off
autovacuum_freeze_max_age = 1500000000
autovacuum_multixact_freeze_max_age = 1500000000
checkpoint_timeout = 1h
max_wal_size = 800GB
log_checkpoints = on
CONF
}
case ${1:-} in
mount)
  mountpoint -q /mnt/pgramdisk || { sudo mkdir -p /mnt/pgramdisk
    sudo mount -t tmpfs -o size=450G,mpol=interleave,mode=0700 tmpfs /mnt/pgramdisk; sudo chown ec2-user:ec2-user /mnt/pgramdisk; }
  df -h /mnt/pgramdisk | tail -1 ;;
huge)
  echo 201 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages >/dev/null
  echo "1G hugepages: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages) (want 201), per node $(cat /sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages | paste -sd' ')" ;;
init)
  [ -d $D ] && die "$D exists"
  $PB/initdb -D $D -U postgres --auth-local=trust --auth-host=scram-sha-256 > $L/sb24-initdb.log 2>&1 || die initdb
  conf; echo "host all all <PRIVATE_IP>/16 scram-sha-256" >> $D/pg_hba.conf
  # prepare is bulk load: let autovacuum-free load checkpoint normally
  $PB/pg_ctl -D $D -l $L/sb24-init.log -o "-c max_wal_size=64GB" -w -t 600 start >/dev/null || die start
  $PB/psql -h /tmp -U postgres -d postgres -c "create role sbtest login password 'sbtest'" -c "create database sbtest owner sbtest"
  echo "init done" ;;
snapshot)
  $PB/pg_ctl -D $D status >/dev/null 2>&1 || die "not running"
  $PB/psql -h /tmp -U sbtest -d sbtest -Atc "select 'sbtest size: '||pg_size_pretty(pg_database_size('sbtest'))"
  $PB/vacuumdb -h /tmp -U sbtest -d sbtest -z -j 64 -q && $PB/psql -h /tmp -U postgres -d postgres -qc checkpoint
  $PB/pg_ctl -D $D -m fast -w -t 7200 stop >/dev/null
  mkdir -p $(dirname $G); rm -rf $G.partial
  cp -a $D $G.partial && rm -rf $G && mv $G.partial $G && date -u +%FT%TZ > $G/.snapshot-complete
  echo "golden: $(du -sh $G | cut -f1)" ;;
start)
  B=$(armdir $2)/bin; [ -x $B/postgres ] || die "no $B/postgres"; [ -f $G/.snapshot-complete ] || die "no golden"
  stopall; rm -rf $D; cp -a $G $D; rm -f $D/.snapshot-complete; ulimit -n $(ulimit -Hn)
  $PB/pg_ctl -p $B/postgres -D $D -l $L/sb24-$2.log -w -t 600 start >/dev/null || { tail -5 $L/sb24-$2.log; die "start $2"; }
  P=$(head -1 $D/postmaster.pid); [ "$(readlink /proc/$P/exe)" = "$B/postgres" ] || { stopall; die "exe mismatch"; }
  echo "started $2 md5=$(md5sum < $B/postgres | cut -c1-12) aff=$(taskset -cp $P | awk '{print $NF}') $($PB/psql -h /tmp -U postgres -d postgres -Atc "select 'autovacuum='||current_setting('autovacuum')||' ckpt='||current_setting('checkpoint_timeout')||' age='||max(age(datfrozenxid)) from pg_database")" ;;
stop) stopall; echo stopped ;;
snap) awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat ;;
ckpt) $PB/psql -h /tmp -U postgres -d postgres -Atc "select (select num_timed+num_requested from pg_stat_checkpointer)||' '||(select count(*) from pg_stat_activity where backend_type='autovacuum worker')||' '||(select count(*) from pg_stat_activity where backend_type='client backend')" ;;
*) grep -E '^#   ' "$0"; exit 1 ;;
esac
