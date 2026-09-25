#!/usr/bin/env bash
# 250 x 1M oltp dataset, generated over loopback by sysbench pinned to node 2 (postgres is on node 0).
numactl --cpunodebind=2 --membind=2 sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 \
  --pgsql-user=sbtest --pgsql-password=sbtest --pgsql-db=sbtest --tables=250 --table-size=1000000 \
  --threads=50 oltp_read_write prepare
echo "PREPARE EXIT=$?"
/opt/pg18-base/bin/psql -h /tmp -U postgres -d sbtest -Atc "select count(*) from pg_tables where tablename like 'sbtest%'"
/opt/pg18-base/bin/psql -h /tmp -U postgres -d sbtest -Atc "select pg_size_pretty(pg_database_size('sbtest'))"
