#!/usr/bin/env bash
# srv16-setup.sh boot|init  -- r8i.16xlarge (64 vCPU, 1 NUMA node, 495 GB) base-vs-afdoltob server.
#   boot : 68 x 1G hugepages (shared_buffers 64GB) + 120G tmpfs; rerun after every stop/reboot
#   init : empty cluster on tmpfs with the 48xl config scaled to this box, role/db sbtest, started with base
# The 48xl's postgresql.conf is kept except shared_buffers 200GB->64GB and effective_cache_size
# 1000GB->320GB (both memory-scaled); WAL/checkpoint/bgwriter settings are unchanged.
set -euo pipefail
D=/mnt/pgramdisk/pg18sb84; B=/opt/pg18-base/bin
case ${1:?boot|init} in
boot)
  echo 68 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages >/dev/null
  echo "hugepages_1G=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)"
  mountpoint -q /mnt/pgramdisk || { sudo mkdir -p /mnt/pgramdisk; sudo mount -t tmpfs -o size=120G tmpfs /mnt/pgramdisk; }
  sudo chown ec2-user: /mnt/pgramdisk; df -h /mnt/pgramdisk | tail -1 ;;
init)
  rm -rf $D; $B/initdb -D $D -U postgres -A trust -E UTF8 --locale=C >/dev/null
  cat > $D/postgresql.conf <<'EOF'
listen_addresses = '*'
port = 5432
unix_socket_directories = '/tmp'
max_connections = 1500
shared_buffers = 64GB
huge_pages = on
huge_page_size = 1GB
work_mem = 8MB
maintenance_work_mem = 4GB
temp_buffers = 16MB
max_files_per_process = 4000
synchronous_commit = off
full_page_writes = off
wal_level = minimal
max_wal_senders = 0
wal_buffers = 1GB
max_wal_size = 64GB
min_wal_size = 8GB
checkpoint_timeout = 30min
checkpoint_completion_target = 0.9
effective_cache_size = 320GB
random_page_cost = 1.0
seq_page_cost = 1.0
effective_io_concurrency = 200
jit = off
autovacuum = on
autovacuum_max_workers = 8
autovacuum_naptime = 10s
autovacuum_vacuum_cost_delay = 0
bgwriter_delay = 10ms
bgwriter_lru_maxpages = 1000
max_locks_per_transaction = 256
logging_collector = off
log_min_messages = warning
EOF
  echo "host all all <VPC_CIDR> scram-sha-256" >> $D/pg_hba.conf
  ulimit -n $(ulimit -Hn)
  $B/pg_ctl -D $D -l /mnt/pgramdisk/pg-init.log -w start >/dev/null
  $B/psql -h /tmp -U postgres -qc "create role sbtest login superuser password 'sbtest'" -c "create database sbtest owner sbtest"
  $B/psql -h /tmp -U sbtest -d sbtest -Atc "select version(), current_setting('shared_buffers'), current_setting('huge_pages')" ;;
esac
