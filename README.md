# PostgreSQL 18.3 PGO / LTO / AutoFDO / BOLT on sysbench oltp_read_write

This repo holds a build matrix of PostgreSQL 18.3 binaries, each built with profile-guided optimization
(PGO), link-time optimization (LTO), sample-based AutoFDO, and/or the BOLT post-link optimizer. Each
binary was benchmarked against a plain `-O3` build with sysbench `oltp_read_write` on an AWS
r8i.metal-48xl. All profiles were collected with postgres running on all 192 vCPUs, loaded from a
separate client machine at more than 60% server CPU.

The build, profiling and benchmark scripts are in [`scripts/`](scripts/). The profiles are in
[`profiles/`](profiles/). The raw per-run logs are in [`results/`](results/).

**Newest result (2026-09-29):** the HammerDB-TPROC-C-trained PGO + LTO + BOLT binary published in
[postgres-pgo-lto-bolt](https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt), measured on sysbench across
five r8i sizes. It is **+7 to +12% tps** where the server is CPU-bound. It comes first below. The earlier
sysbench-trained build matrix follows it, under [Sysbench-trained build matrix](#sysbench-trained-build-matrix-2026-09-24-to-09-25).

# Sysbench benchmark of PostgreSQL 18.3 with the HammerDB-trained HWPGO build (PGO + LTO + BOLT)

**Question:** the published `pgoltob` binary was profile-trained on HammerDB TPROC-C. Does it also speed up a
different OLTP workload, sysbench `oltp_read_write`, that it was never trained on?

**Answer: yes, once the server is CPU-bound.** On single-NUMA-node boxes the unmodified published binary is
**+7 to +12% tps** over a plain `-O3 -march=native` build at the saturated thread counts. On 31 of the 32
box x thread cells it needs less CPU per transaction, typically **5-10% less**. Where the server is not CPU-bound, or
is limited by lock contention (the 2- and 3-node boxes above ~1024 threads), that saving does not turn into
throughput.

Measured 2026-09-29 on five AWS r8i sizes (Xeon 6975P-C, us-east-2), 32 to 1024 threads (to 2048 on the
48xlarge), mirrored A/B/B/A order, 0 errors in all 128 runs. Raw data, per-box configs and the harness are
in [`sysbench-sweep-20260929/`](sysbench-sweep-20260929/).

## Binaries under test

| arm | what it is | `bin/postgres` md5 |
|---|---|---|
| `base` | stock PostgreSQL 18.3, `-O3 -march=native -mtune=native`, gcc 14.2.1 (`gcc14-gcc`), built on each box | `f1b62bb68d47...` |
| `pgoltob` | the published PGO + LTO + BOLT build, trained on HammerDB TPROC-C, installed unmodified from [`binaries/pg18-pgoltob.tar.xz`](https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt/tree/main/binaries) | `d27408aa2c40...` |

`base` built independently on all five boxes came out byte-identical, so the baseline is the same binary everywhere.

## Result: tps, pgoltob vs base

Each cell is the mean of both passes. **Bold** = distinguishable: the delta is larger than the pass-A-to-pass-B
spread of both arms. ° = not distinguishable from base.

| threads | 4xlarge<br>16 vCPU, 1 node | 8xlarge<br>32 vCPU, 1 node | 16xlarge<br>64 vCPU, 1 node | 24xlarge<br>96 vCPU, 2 nodes | 48xlarge\*<br>96 vCPU, 3 nodes |
|---|---|---|---|---|---|
| 32 | **+4.27%** | +0.72% ° | -0.05% ° | -0.34% ° | +0.75% ° |
| 64 | **+4.84%** | **+3.09%** | **+1.85%** | +3.14% ° | **+7.67%** |
| 128 | **+8.92%** | **+3.59%** | **+3.20%** | **+3.62%** | **+7.10%** |
| 256 | **+8.21%** | **+7.00%** | **+6.58%** | +4.38% ° | -0.27% ° |
| 512 | **+11.81%** | **+7.69%** | **+7.31%** | **+3.23%** | **+4.80%** |
| 1024 | **+8.62%** | **+10.70%** | **+6.96%** | **+4.72%** | **-1.64%** |
| 1536 | - | - | - | - | **+14.03%** |
| 2048 | - | - | - | - | **-2.22%** |
| **mean, 32-1024** | **+7.78%** | **+5.47%** | **+4.31%** | **+3.13%** | **+3.07%** |
| base peak | 13,895 tps @ 128 | 28,814 @ 256 | 53,550 @ 512 | 69,352 @ 512 | 65,155 @ 1024 |

\* The 48xlarge ran with **96 vCPU, not 192**: it was launched from the 24xlarge with "Launch more like this",
which copied the 24xlarge CPU options (48 cores x 2 threads). It is effectively a 24xlarge CPU with 1.5 TiB RAM
and 3 NUMA nodes (SNC-3). A run at the full 192 vCPU is still to do.

## Result: CPU per transaction, pgoltob vs base

Server CPU-microseconds per transaction (server busy fraction x vCPU / tps). Negative = cheaper.

| threads | 4xlarge | 8xlarge | 16xlarge | 24xlarge | 48xlarge\* |
|---|---|---|---|---|---|
| 32 | -10.0% | -5.9% | -6.9% | -5.1% | -9.1% |
| 64 | -6.7% | -9.2% | -9.1% | -6.6% | -8.5% |
| 128 | -9.1% | -6.2% | -7.7% | -3.5% | -8.3% |
| 256 | -7.6% | -7.4% | -6.4% | -3.7% | -5.6% |
| 512 | -10.6% | -7.2% | -8.0% | -5.4% | -8.1% |
| 1024 | -7.9% | -9.7% | -6.8% | -5.0% | -0.2% |
| 1536 | - | - | - | - | -13.5% |
| 2048 | - | - | - | - | +1.5% |

Base server busy % at each rung is in [`results/summary.tsv`](sysbench-sweep-20260929/results/summary.tsv).

## Reading the result

- **The binary is consistently cheaper per transaction**: cheaper on 31 of the 32 box x thread cells, typically
  by 5-10%.
- **On the single-node boxes that saving becomes throughput once the server is CPU-bound.** Below ~70% server
  busy the gain there is 0-5%; at 97-100% busy it is +7 to +12%. The 48xlarge is the exception at low load:
  +7% at 64-128 threads while only 26-30% busy.
- **Multi-node boxes gain less.** The 24xlarge (2 nodes) and 48xlarge (3 nodes) stop at 88-92% busy, and the
  pass-to-pass spread widens to as much as 5.5% (restart-to-restart memory placement varies across nodes). On
  the 48xlarge above 1024 threads the run is lock-contention-bound, where the CPU-per-transaction saving itself
  disappears (-0.2% at 1024, +1.5% at 2048). In that regime the order of the two arms is set by contention,
  not code layout, so the curve zig-zags. Both passes reproduce each rung within ~2%, so the zig-zag is real.
- **Consistent with earlier sysbench campaigns.** On a us-east-1 r8i.metal-48xl at 1200 connections and 78%
  busy the same binary was a null result (-0.66%, inside noise). The sysbench-TRAINED lattice on a us-east-2
  48xlarge at 60-68% busy put `pgoltob` at +4.11% with -12.8% CPU per transaction. Neither run saturated the server.

## Test setup

| | |
|---|---|
| servers | r8i.4xlarge / 8xlarge / 16xlarge / 24xlarge / 48xlarge, Xeon 6975P-C, 480 MiB L3 per socket, Amazon Linux 2023 |
| client | one r8i.16xlarge, same AZ (us-east-2c), sysbench 1.1.0 (git master, pgsql driver), never on the server |
| data dir | tmpfs, restored from an EBS golden copy before every arm-pass; `shared_buffers` on 1 GiB huge pages |
| workload | `oltp_read_write`, 250 tables, uniform random, 20 statements per transaction (checked on every rung) |
| per rung | 60 s warm-up + 120 s measured, 10 s report interval |
| per arm-pass | restore golden, start, 180 s prewarm at 64 threads (discarded), then all rungs in one server lifetime |
| order | pass A `base, pgoltob`, pass B `pgoltob, base`, so both arms have the same mean position in time |

**Sizing: every absolute scales with the box, every ratio is held.** Row count scales, table count does not.
Keeping 250 tables everywhere keeps the relation count, index count and lock-partition spread identical, so
only the data volume changes, not the contention structure.

| | 4xlarge | 8xlarge | 16xlarge | 24xlarge | 48xlarge |
|---|---|---|---|---|---|
| vCPU / RAM | 16 / 124 GiB | 32 / 248 GiB | 64 / 496 GiB | 96 / 743 GiB | 96\* / 1488 GiB |
| rows per table (x250) | 250k | 500k | 1M | 1.5M | 3M |
| golden data dir | 32 GB | 63 GB | 126 GB | 189 GB | 377 GB |
| `shared_buffers` / 1 GiB huge pages | 32GB / 34 | 64GB / 68 | 128GB / 134 | 192GB / 201 | 384GB / 402 |
| `max_wal_size` / `min_wal_size` | 16GB / 2GB | 32GB / 4GB | 64GB / 8GB | 96GB / 12GB | 192GB / 24GB |
| `max_connections` | 1500 | 1500 | 1500 | 1500 | 2500 |

Everything that shapes the workload is identical on all boxes: `synchronous_commit=off`, `full_page_writes=off`,
`wal_level=minimal`, `wal_buffers=1GB`, `checkpoint_timeout=30min`, `jit=off`, planner costs, autovacuum,
data checksums on (PG18 default). Full configs: [`config/`](sysbench-sweep-20260929/config/).

**Metrics.** tps and qps add across sysbench processes. p95 does not, so the worst process is reported.
Each process is averaged over its own measured intervals before summing. Server busy % comes from
`/proc/stat` on the server, sampled at the start and end of the measured window only.

**One sysbench process holds at most 512 threads.** At 250 tables each thread keeps per-table prepared-statement
state in its own LuaJIT heap, and above ~512 threads a single process runs out of LuaJIT memory. 1024 threads
run as 2 x 512, 1536 as 3 x 512, 2048 as 4 x 512.

## Files

```
sysbench-sweep-20260929/
  results/per-pass.tsv    every run: box, pass, arm, threads, procs, tps, server busy %, worst p95, CPU us/txn, errors
  results/summary.tsv     both passes side by side, mean, delta, per-arm spread, distinguishable flag
  config/<instance>/      pg-env.sh (sizing) and postgresql.conf for each box
  scripts/server/         provision.sh (bare AL2023 -> ready DUT), pg-hp.sh, pg-ds.sh, pg-srv.sh, pg-prep-local.sh,
                          keepalive.sh + ka-start.sh / ka-restart.sh (keep a waiting box above an idle-shutdown policy)
  scripts/client/         sb-env*.sh (per box), sb-lib.sh, sb-ladder*.sh (one arm, all rungs), sb-mirror*.sh (A/B/B/A)
```

Private addresses are replaced by `<SERVER_PRIVATE_IP>` / `<CLIENT_PRIVATE_IP>` and the database password by
`<SB_PASSWORD>`. Set them before running.

---

# Sysbench-trained build matrix (2026-09-24 to 09-25)

## Result (full-CPU campaign `fc-mirror-2800c-20260925T102315Z`)

Mirrored A/B order, 2800 client connections, 600 s warm-up + 240 s measured per run, 18/18 runs clean.
Server CPU was 60–68% busy.

| arm | tps pass A | tps pass B | mean tps | vs base | server CPU per txn vs base | A/B spread |
|---|---:|---:|---:|---:|---:|---:|
| afdoltob | 61,771 | 63,579 | 62,675 | +6.12% | −5.4% | 2.88% |
| pgob | 61,916 | 61,255 | 61,586 | +4.27% | −9.3% | 1.07% |
| **pgoltob** | 61,412 | 61,569 | 61,491 | **+4.11%** | **−12.8%** | 0.25% |
| afdob | 60,897 | 61,103 | 61,000 | +3.28% | −10.0% | 0.34% |
| pgo | 60,480 | 60,921 | 60,701 | +2.78% | −6.3% | 0.73% |
| afdolto | 59,778 | 61,250 | 60,514 | +2.46% | −0.7% | 2.43% |
| afdo | 60,116 | 60,670 | 60,393 | +2.25% | −6.5% | 0.92% |
| pgolto | 59,468 | 60,178 | 59,823 | +1.29% | −5.7% | 1.19% |
| base | 59,278 | 58,845 | 59,062 | — | — | 0.73% |

How to read this table:

- **Every profiled arm beats base on tps, but the gaps are small.** At this load the server stops
  scaling at about 60k tps. Server CPU per transaction (CPU busy % ÷ tps) is the clearer signal.
- **pgoltob (PGO + LTO + BOLT) is the most reliable winner.** It is +4.1% on tps, uses 12.8% less CPU
  per transaction than base, and its two passes agree within 0.25%.
- **afdoltob's top tps is inside its own noise.** Its A/B spread (2.9%) is larger than its lead. Its
  AutoFDO profile also never reaches the code (see [AutoFDO + LTO](#autofdo--lto-is-a-no-op-in-this-matrix)),
  so it is really LTO + BOLT.

Two earlier campaigns are also in [`results/`](results/). They used different setups, so quote each
one with its setup:

| campaign | setup | outcome |
|---|---|---|
| `sb-mirror-128T-20260924T085654Z` | postgres and profiling pinned to NUMA node 0 (64 vCPUs), 128 sysbench threads over loopback from the other nodes, 71–73% node-0 busy | pgoltob +20.90% (46,038 vs base 38,080 tps), pgolto +17.19%, pgob +14.04%, afdoltob +13.45%, pgo +13.07%, afdob +12.82%, afdo +8.60%, afdolto +4.37% |
| `fb-mirror-1200c-20260924T221600Z` | single-node binaries, postgres on all 192 vCPUs, 1200 connections from the client, only 31–37% server CPU | tps all within ±2.7% of base (limited by client–server network latency, ~1,100/1,200 backends waiting in ClientRead). CPU per txn: pgolto −17.7%, pgoltob −16.0%, pgob −15.4%, afdob −15.3%, pgo −14.4%, afdoltob −13.3%, afdo −11.6%, afdolto −3.8% |

## Second box: r8i.16xlarge, base vs afdoltob (`pg16-mirror-800c-20260925T224225Z`)

The benchmarked base and afdoltob binaries were copied unchanged to a smaller server (no re-profiling)
and compared again, with the dataset and load level scaled down to fit the box. Mirrored order
A1 B1 A2 B2, 8/8 runs clean, 600 s warm-up + 240 s measured, golden restore before every run.

| run | base tps | base server CPU | afdoltob tps | afdoltob server CPU |
|---|---:|---:|---:|---:|
| A1 | 33,439.5 | 69.9% | 34,462.5 | 66.1% |
| B1 | 33,384.9 | 69.4% | 34,475.3 | 66.1% |
| A2 | 33,407.1 | 69.7% | 34,479.0 | 66.1% |
| B2 | 33,431.3 | 69.8% | 34,493.6 | 65.9% |
| **mean** | **33,415.7** | 69.7% | **34,477.6 (+3.18%)** | 66.0% |
| spread (max−min) | 0.16% | | 0.09% | |

- afdoltob is **+3.18% tps** and uses **8.2% less server CPU per transaction**. p95 latency is 24.3 ms
  vs 25.9 ms. The slowest afdoltob run beats the fastest base run by 3.1%.
- The runs are far more repeatable than on the 48xl (spread < 0.2% vs 2.9%), and the ~120 s tps
  cycle seen on the 48xl did not appear here.
- The client was only ~15% busy. About 95% of backends were waiting in `ClientRead` (the cross-AZ
  round trip), equally in both arms, so CPU per transaction is the cleaner efficiency measure.

| | 48xl | 16xl |
|---|---|---|
| Server instance | r8i.metal-48xl, us-east-2a | r8i.16xlarge, us-east-2a |
| vCPUs / NUMA nodes | 192 / 3 (SNC-3) | 64 / 1 |
| Memory | 1.5 TB | 495 GB |
| Hugepages (1 GB) | 206 | 68 |
| tmpfs data directory | 180 GB | 120 GB |
| Client | r8i.24xlarge, us-east-2c | same client |
| Dataset | 250 tables × 1M rows (124 GB) | 84 tables × 1M rows (~45 GB incl. WAL) |
| `shared_buffers` / `effective_cache_size` | 200GB / 1000GB | 64GB / 320GB |
| other postgresql.conf settings | [`config/postgresql.conf`](config/postgresql.conf) | identical |
| `max_connections` (via `-o`) | 4000 | 2000 |
| Load | 7 × 400 = 2800 connections | 4 × 200 = 800 connections |
| Base server CPU at that load | 64.1% | 69.7% |
| Runs | 18 (9 arms × A/B) | 8 (2 arms × A1 B1 A2 B2) |
| afdoltob vs base, tps | +6.12% (spread 2.88%) | +3.18% (spread 0.09%) |
| afdoltob vs base, CPU per txn | −5.4% | −8.2% |

Load calibration on base, 240 s per point; 4 × 200 is the first point above 60%
([`results/pg16-calib-20260925/`](results/pg16-calib-20260925/)):

| connections | server CPU busy | tps | p95 |
|---:|---:|---:|---:|
| 400 (2×200) | 26.8% | 17,555 | 23.4 ms |
| 600 (3×200) | 49.0% | 26,098 | 23.6 ms |
| **800 (4×200)** | **69.7%** | 33,473 | 25.7 ms |
| 1000 (5×200) | 85.3% | 38,352 | 30.1 ms |
| 1200 (6×200) | 94.1% | 40,756 | 36.2 ms |
| 1600 (8×200) | 97.7% | 38,659 | 58.5 ms |

Scripts are in [`scripts/16xl/`](scripts/16xl/): `srv16-setup.sh boot|init` (hugepages, tmpfs,
cluster init with the scaled config), `fc16-srv.sh` (server helper), and `fc16-calib.sh` /
`fc16-mirror.sh` on the client (`NPROC=4 PER=200 bash fc16-mirror.sh`).

The afdoltob client tools (`psql`, `pg_ctl`, ...) carry `RUNPATH=/opt/pg18fc-afdoltoq/lib` (see
[`binaries/README.md`](binaries/README.md)). On the 16xl, a symlink
`/opt/pg18fc-afdoltoq -> /opt/pg18fc-afdoltob` fixes it. The postgres server binary is not affected.

## Test setup

### Server (runs postgres and perf only)

| | |
|---|---|
| Instance | AWS **r8i.metal-48xl**, us-east-2a |
| CPU | Intel Xeon 6975P-C, 1 socket, 96 cores / 192 vCPUs (2 threads per core) |
| NUMA | SNC-3, 3 nodes: node0 0-31,96-127; node1 32-63,128-159; node2 64-95,160-191 |
| Memory | 1.5 TB. 206 × 1 GB hugepages reserved at runtime (69/69/68 per node) for `shared_buffers` |
| OS | Amazon Linux 2023.12, kernel 6.18.48-109.150.amzn2023, stock boot command line |
| Storage | data directory on a 180 GB tmpfs (`/mnt/pgramdisk`, no mempolicy). Before every run, a fresh copy of a 124 GB golden data directory is restored. No disk I/O in the measured path. |
| Postgres placement | unpinned, all 192 vCPUs, for profiling and benchmarking |
| Compiler | gcc 14.2.1 20250110 (`gcc14-gcc`, Red Hat 14.2.1-7) |
| Source | PostgreSQL REL_18_3, commit `62d6c7d3df6`, `--with-openssl --with-readline` |
| perf | 6.1.186 |
| Limits | `ulimit -n` 65535 |

### Client (runs sysbench and the profile post-processing)

| | |
|---|---|
| Instance | AWS **r8i.24xlarge**, us-east-2c, same VPC. Different availability zone, ~1.2 ms round trip to the server. |
| CPU | Intel Xeon 6975P-C, 1 socket, 96 vCPUs, 2 NUMA nodes |
| Memory | 743 GB |
| OS | Amazon Linux 2023.12, kernel 6.18.48-109.150.amzn2023 |
| sysbench | 1.0.20 (`ebf1c90`), pgsql driver against the system `libpq.so.5` |
| Profile tools | llvm-bolt / perf2bolt 18.1.3; AutoFDO `create_gcov` / `dump_gcov` built from upstream `c0756f5` (GCOV build); perf 6.1.186 |
| Client load | 28–30% client CPU busy at 2800 connections, so the client is not the bottleneck |
| Limits | `ulimit -n` raised to the hard limit (65535) by the harness |

### PostgreSQL configuration

[`config/postgresql.conf`](config/postgresql.conf) is baked into the golden data directory.
**It is not a durability-realistic config**: commits are asynchronous, full-page writes are off and
WAL is minimal, so the benchmark measures CPU-side code efficiency rather than I/O.

```
listen_addresses = '*'
port = 5432
unix_socket_directories = '/tmp'
max_connections = 1500            # overridden per run: -o "-c max_connections=4000" (6500 for 4800-conn profiling)
shared_buffers = 200GB
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
effective_cache_size = 1000GB
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
```

Server start (from [`fc-srv.sh`](scripts/profile/fc-srv.sh)):

```
pg_ctl -D /mnt/pgramdisk/pg18sb250 -l /mnt/pgramdisk/pg-<arm>.log -o "-c max_connections=$MAXC" -w -t 600 start
```

### sysbench configuration

Dataset, loaded once on the server over loopback ([`sb-prepare.sh`](scripts/setup/sb-prepare.sh), sysbench pinned to node 2); 250 tables × 1M rows, 124 GB:

```
sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
  --pgsql-db=sbtest --tables=250 --table-size=1000000 --threads=50 oltp_read_write prepare
```

Load, from the client, one command per sysbench process (7 processes for 2800 connections):

```
sysbench --db-driver=pgsql --pgsql-host=<SERVER_PRIVATE_IP> --pgsql-port=5432 --pgsql-user=sbtest --pgsql-password=sbtest \
  --pgsql-db=sbtest --tables=250 --table-size=1000000 --threads=400 --time=840 \
  --report-interval=10 --rand-type=uniform oltp_read_write run
```

| setting | benchmark | profiling |
|---|---|---|
| processes × threads | 7 × 400 = 2800 | 7 × 400 (PGO, AutoFDO); 9 × 400 (pgoq BOLT); 12 × 400 (other BOLT) |
| `--time` | 840 s (600 s warm-up + 240 s measured) | 900 s (PGO), 360 s (AutoFDO, pgoq BOLT), 420 s (other BOLT) |
| `--report-interval` | 10 s | 30 s |
| script | `oltp_read_write`, default mix (10 point selects, 4 range queries, 2 updates, 1 delete, 1 insert per transaction) | same |

One sysbench process is limited to 400 threads because a single process dies above ~512 threads at
250 tables (LuaJIT, not memory).
## Method, step by step

### 1. Setup (after every server boot)

```
echo 206 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
sudo mount -t tmpfs -o size=180G tmpfs /mnt/pgramdisk && sudo chown ec2-user: /mnt/pgramdisk
```

The dataset is loaded once with [`scripts/setup/sb-prepare.sh`](scripts/setup/sb-prepare.sh) and kept
as the golden copy. `fc-srv.sh start` restores it into the tmpfs before every run (~4 min).

### 2. Finding a load level above 60% server CPU

[`scripts/harness/fc-calib.sh`](scripts/harness/fc-calib.sh) sweeps the number of sysbench
processes (400 threads each; one sysbench process becomes unstable above ~400–512 threads at 250
tables). Results on base, with postgres on all 192 vCPUs:

| connections | server CPU busy | tps |
|---:|---:|---:|
| 1200 (3×400) | 33.6% | 44.6k |
| 2000 (5×400) | 51.6% | 58.4k |
| **2800 (7×400)** | **64.1%** | 60.1k |
| 3600 (9×400) | 65.8% | 59.8k |

2800 connections is the profiling and benchmark load level. Every profile must be recorded at more
than 60% server CPU, or the pipeline stops.

**Two things that matter when measuring this:**

- **Better binaries do the same work with less CPU**, so they sit lower in busy % at a fixed
  connection count. The BOLT profile on pgoq at 2800 connections was only 59.2%, so the BOLT profiles
  were recorded at 3600 (pgoq) and 4800 (the other three) connections.
- **Throughput swings on a ~120 s cycle.** tps peaks at 65–68k and dips to 51–54k at 120, 240 and
  360 s. It is not the timed checkpoint (`checkpoint_timeout=30min`); the cause was not found. A 60 s
  window therefore gives a phase-dependent CPU reading: the first pgoltoq BOLT profile read 57.7%,
  although the calibration at the same load read 69%. From then on, profiling CPU is averaged over
  240 s (the 60 s perf record plus 180 s after it), and the benchmark measures 240 s. The PGO training
  (590 s window) and the three later BOLT profiles use the long window. The AutoFDO profile and the pgoq
  BOLT profile were measured over 60 s.

### 3. Profile collection

[`scripts/profile/fc-prof.sh`](scripts/profile/fc-prof.sh) runs the whole chain from the client
(`START_AT=N` resumes at step N). It calls [`scripts/profile/fc-srv.sh`](scripts/profile/fc-srv.sh) on
the server for start/stop/perf/CPU snapshots. All load comes from the client; nothing runs on the
server except postgres and perf.

| step | binary | load | method | server CPU | output |
|---|---|---|---|---:|---|
| 1 PGO training | `pgogen` (instrumented) | 2800 connections, 900 s | `.gcda` counters are written when postgres stops (the stop allows up to 2 h to finish writing) | 85.0% | 935 `.gcda`, 1.82 MB → [`pgogen-gcda-fc-20260925.tgz`](profiles/full-cpu/) |
| 2 build | pgo, pgoq, pgolto, pgoltoq | — | reuse the pgogen tree in place, `-fprofile-use` | — | |
| 3 AutoFDO record | `prep` (`-g -Wl,-q`) | 2800 connections | `perf record -a -e cycles:u -j any,u -c 800011` for 60 s | 61.4% | 20 GB perf data |
| 4 create_gcov | — | — | `perf inject --build-ids`, then `create_gcov --gcov_version=2` on the client ([`lat-post.sh afdo`](scripts/profile/lat-post.sh)) | — | [`pg18.afdo`](profiles/full-cpu/pg18.afdo) 1,581,949 B, 1,780 functions |
| 5 build | afdo, afdoq, afdolto, afdoltoq | — | `-fauto-profile=pg18.afdo` | — | |
| 6–9 BOLT records | pgoq, pgoltoq, afdoq, afdoltoq | 3600 (pgoq), 4800 (others) | `perf record -a -b -e branches:u -c 100003` for 60 s | 63.1%, 65.0%, 67.4%, 71.2% | 2.1–2.4 GB perf data each |
| 10 BOLT | pgob, pgoltob, afdob, afdoltob | — | `perf2bolt` → `llvm-bolt` on the client ([`lat-post.sh bolt`](scripts/profile/lat-post.sh)), then [`install-bolt.sh`](scripts/build/install-bolt.sh) | — | [`profiles/full-cpu/bolt-*/profile.fdata`](profiles/full-cpu/) |

`--no-buildid` perf records break `create_gcov`, which then produces an almost empty profile.
`perf inject --build-ids` fixes it. `perf2bolt` matches by path and is not affected.

### 4. Arms

All arms use `-O3 -march=native -mtune=native` and `--with-openssl --with-readline`. The flag matrix is
in [`scripts/build/pg-build-1n.sh`](scripts/build/pg-build-1n.sh). The `q` variants keep
relocations (`-Wl,-q`) and debug info so BOLT can rewrite them. They are built only to be profiled
and bolted, not benchmarked.

| arm | how it is built |
|---|---|
| **base** | `-O3 -march=native`. No profile. |
| prep | base + `-g -Wl,-q`. Used only to record the AutoFDO profile. |
| pgogen | `-fprofile-generate -fprofile-update=prefer-atomic`. Used only for PGO training. |
| **pgo** | Rebuilt in the pgogen tree, reusing its `.gcda`: `-fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile` |
| **pgolto** | pgo + `-flto -ffat-lto-objects` (gcc-ar / gcc-ranlib / gcc-nm) |
| **afdo** | `-fauto-profile=pg18.afdo` |
| **afdolto** | LTO, with `-fauto-profile` on the link line only. **Effectively plain LTO** (see below). |
| **pgob** | pgoq (pgo + `-g -Wl,-q`) → BOLT profile → `perf2bolt` → `llvm-bolt` |
| **pgoltob** | pgoltoq (pgolto + `-g -Wl,-q`) → BOLT profile → `perf2bolt` → `llvm-bolt` |
| **afdob** | afdoq (afdo + `-g -Wl,-q -fno-reorder-blocks-and-partition`) → BOLT profile → `perf2bolt` → `llvm-bolt` |
| **afdoltob** | afdoltoq (afdolto + `-g -Wl,-q -fno-reorder-blocks-and-partition`) → BOLT profile → `perf2bolt` → `llvm-bolt`. **Effectively LTO + BOLT.** |

llvm-bolt options:

```
-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections
```

Checks on every build (`gate()` in `pg-build-1n.sh`):

- `.text` size is recorded;
- the build log must contain `-fprofile-use` / `-fauto-profile`;
- a binary that should not be instrumented must contain no gcov symbols;
- the BOLT output must carry the BOLT note section;
- every full-CPU binary's md5 must differ from its single-node counterpart.

#### AutoFDO + LTO is a no-op in this matrix

gcc 14.2.1 crashes (ICE in einline) when `-flto` and `-fauto-profile` are on the same compile line.
So afdolto and afdoltoq pass the profile on the link line only. That does nothing: afdoltoq relinked
with and without `-fauto-profile` gives byte-identical `.text` (8,294,258 B), because GCC's AutoFDO
pass runs before LTO streaming. **Treat afdolto as plain LTO and afdoltob as LTO + BOLT**, not as
AutoFDO results.

### 5. Benchmark

[`scripts/harness/fc-mirror.sh`](scripts/harness/fc-mirror.sh), started automatically by
[`fc-chain-bench.sh`](scripts/harness/fc-chain-bench.sh) once all binaries are installed.

- **Mirrored order:** pass A runs base, pgo, pgolto, afdo, afdolto, pgob, pgoltob, afdob, afdoltob.
  Pass B runs the same arms in reverse. 18 runs in total.
- **Each run:** restore the golden data directory → start the arm (unpinned, all 192 vCPUs) → 7 sysbench
  processes × 400 threads from the client → 600 s warm-up → 240 s measured → stop.
- **tps:** for each sysbench process, the mean of its 10 s interval tps after warm-up, summed over the
  7 processes.
- **CPU:** server and client CPU busy % from `/proc/stat` over the measured window. `pg_stat_activity`
  wait events are sampled 8 times per run (`*.waits`).
- **CPU per transaction:** server busy % ÷ tps, averaged over both passes, compared against base.

## Repo layout

```
config/postgresql.conf        server config baked into the golden data directory
scripts/setup/                dataset load
scripts/build/                pg-build-1n.sh (all compiled arms), install-bolt.sh, relink.sh (AutoFDO+LTO no-op check)
scripts/profile/              full-CPU chain: fc-prof.sh (client) + fc-srv.sh (server) + lat-post.sh (create_gcov / perf2bolt / llvm-bolt)
                              single-node chain: pg-train.sh, sb-record.sh, rec-chain.sh
scripts/harness/              full-CPU: fc-calib.sh, fc-mirror.sh, fc-chain-bench.sh
                              full-box 1200c: fb-mirror.sh + fb-arm.sh;  single-node: sb-mirror.sh, sb-calib-lo.sh
scripts/16xl/                 r8i.16xlarge base vs afdoltob: srv16-setup.sh, fc16-srv.sh, fc16-calib.sh, fc16-mirror.sh
profiles/full-cpu/            pg18.afdo, bolt-<arm>/profile.fdata, PGO .gcda tarball used for the result above
profiles/single-node/         the same for the node-0 campaign
binaries/                     pg18fc-afdoltob.tar.xz: the benchmarked afdoltob install tree (see binaries/README.md)
results/<campaign>/           runs.tsv, summary.txt, campaign.log, per-process sysbench logs, wait-event samples
sysbench-sweep-20260929/      five-box sweep of the HammerDB-trained pgoltob vs base (results, per-box configs, lat16 harness)
logs/full-cpu/                profiling chain output, perf record post-checks, build gates
```

The scripts assume two hosts: a client with an ssh alias `srv` pointing at the server, and a server
with the PG source at `~/postgres` and scripts in `~/pg-lattice`. Private addresses are replaced by
`<SERVER_PRIVATE_IP>` / `<CLIENT_PRIVATE_IP>` / `<VPC_CIDR>`. The 16xl scripts use the aliases
`srv16` and `~/lat16` instead. Set them before running.
