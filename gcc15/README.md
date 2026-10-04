# gcc 15.2.0: sysbench-trained PGO / AutoFDO / LTO / BOLT for PostgreSQL 18.3

This directory holds the gcc 15.2.0 round of the campaign. A full arm matrix of stock PostgreSQL 18.3
was built and **trained on sysbench `oltp_read_write`**. The arms were benchmarked on the training
box, and then the selected `pgoltob` binary was measured with a 32-1024 thread ladder on three
machine sizes (r8i.metal-48xl, r8i.24xlarge, r8i.16xlarge).

The ladders compare three binaries:

| name in results | binary | trained on | `bin/postgres` md5 |
|---|---|---|---|
| `base` | `-O3 -march=native -mtune=native`, no profile | none | `6085cabc1498` (48xl leg: `f8459d95d7de`, code-identical, only the build-id differs) |
| `sbpgoltob` | PGO + LTO + BOLT, **this directory** | sysbench `oltp_read_write`, whole box | `81a3c772a9b4` |
| `hdbpgoltob` | PGO + LTO + BOLT from the HammerDB-trained gcc 15.2.0 round (published in `postgres-pgo-lto-bolt`) | HammerDB TPROC-C | `2b4d8844dc0c` |

The `sbpgoltob` install tree is in [`../binaries/g15sb-pg18-pgoltob.tar.xz`](../binaries/README.md).

## Results

### Machine-size ladder (sysbench `oltp_read_write`, 32-1024 threads)

All three boxes ran 6 mirrored passes per box (base, sbpgoltob, hdbpgoltob, hdbpgoltob, sbpgoltob,
base), so every arm has n=2 per rung. Each rung had 120 s of warm-up and 240 s of measurement. There
were 0 errors, 0 checkpoints and 0 autovacuum workers in every measured window.

Mean gain over the six rungs:

| box | vCPU / NUMA nodes | dataset | sbpgoltob | hdbpgoltob | base busy @1024 |
|---|---|---|---|---|---|
| r8i.metal-48xl | 192 / 3 | 250 x 2.4M rows | **+4.33%** | +2.95% | 63% |
| r8i.24xlarge | 96 / 2 | 250 x 1.2M rows | **+6.46%** | +5.24% | 94% |
| r8i.16xlarge | 64 / 1 | 250 x 0.8M rows | **+9.26%** | +6.48% | 99% |

Per rung, % tps vs base:

| threads | 48xl sb | 48xl hdb | 24xl sb | 24xl hdb | 16xl sb | 16xl hdb |
|---|---|---|---|---|---|---|
| 32 | +7.89 | +5.53 | +2.64 | +3.04 | +6.74 | +4.21 |
| 64 | +6.84 | +5.39 | +4.66 | +4.99 | +5.08 | +5.54 |
| 128 | +0.86 | +1.09 | +9.19 | +6.84 | +6.96 | +4.36 |
| 256 | +3.74 | +2.25 | +4.41 | +3.11 | +10.09 | +6.89 |
| 512 | +7.00 | +5.21 | +7.30 | +5.72 | +13.73 | +9.00 |
| 1024 | -0.38 | -1.78 | +10.56 | +7.74 | +12.94 | +8.86 |

Base tps per rung:

| threads | 48xl | 24xl | 16xl |
|---|---|---|---|
| 32 | 2,536 | 12,952 | 13,320 |
| 64 | 5,800 | 23,461 | 26,053 |
| 128 | 14,968 | 33,647 | 39,164 |
| 256 | 38,148 | 50,581 | 51,308 |
| 512 | 56,272 | 69,767 | 55,243 |
| 1024 | 73,936 | 70,094 | 50,380 |

CPU per transaction vs base, sbpgoltob / hdbpgoltob:

| threads | 48xl | 24xl | 16xl |
|---|---|---|---|
| 32 | -22.1% / -16.2% | -10.9% / -8.3% | -14.1% / -9.6% |
| 64 | -19.7% / -16.0% | -12.9% / -10.7% | -15.2% / -9.3% |
| 128 | -16.4% / -12.0% | -8.0% / -7.5% | -13.7% / -10.4% |
| 256 | -17.6% / -12.7% | -12.7% / -10.3% | -12.0% / -8.4% |
| 512 | -16.3% / -12.0% | -10.0% / -6.8% | -13.4% / -9.3% |
| 1024 | -5.7% / +2.9% | -10.7% / -7.5% | -11.8% / -8.2% |

p95 latency, ms, base / sbpgoltob / hdbpgoltob:

| threads | 48xl | 24xl | 16xl |
|---|---|---|---|
| 512 | 12.0 / 11.3 / 11.3 | 11.7 / 10.8 / 10.9 | 15.9 / 13.6 / 14.5 |
| 1024 | 20.2 / 20.4 / 20.5 | 26.2 / 23.4 / 24.1 | 45.3 / 37.5 / 39.8 |

Pass-to-pass spread was at most 3% on the 48xl (except base at 32 threads, 6%), at most 4% on the
24xl, and at most 2% on the 16xl.

What it shows:

1. **The gain grows as the box becomes CPU-bound.** The 48xl stalls on lock contention at about 74k
   tps while only 63% busy, and its gain disappears at 1024 threads. The 16xl is 98-99% busy from 512
   threads, and the 12-15% CPU-per-transaction saving turns almost entirely into throughput
   (+13-14%).
2. **Every box saves 8-22% CPU per transaction.** The one exception is the 48xl at 1024 threads.
3. **The sysbench-trained profile beats the HammerDB-trained one on every box,** by 1.2-2.8 points on
   the mean. The HammerDB-trained binary still keeps 68-81% of that gain on a workload it was never
   trained on.

### Arm matrix on the training box (r8i.metal-48xl, 64 and 128 threads)

7 arms were measured with a mirrored A/B order (n=2), one sysbench process, 120 s warm-up plus 240 s
measured. The dataset was the training dataset (250 x 1M rows).

| arm | 64 threads tps | vs base | 128 threads tps | vs base | mean gain | CPU/txn (64 / 128) |
|---|---|---|---|---|---|---|
| base | 5,550 | | 13,179 | | | |
| afdo | 5,756 | +3.73% | 13,386 | +1.57% | +2.65% | -13.0% / -11.9% |
| afdolto | 5,664 | +2.06% | 13,229 | +0.38% | +1.22% | -15.5% / -11.4% |
| afdoltob | 5,755 | +3.71% | 13,530 | +2.66% | +3.18% | -18.7% / -17.8% |
| pgo | 5,834 | +5.13% | 13,380 | +1.52% | +3.33% | -17.0% / -12.4% |
| pgolto | 5,803 | +4.58% | 13,430 | +1.90% | +3.24% | -19.4% / -16.7% |
| **pgoltob** | 5,948 | **+7.17%** | 13,658 | **+3.64%** | **+5.41%** | **-21.3% / -19.5%** |

The server was only 4-10% busy at these thread counts, so most of the CPU saving cannot show as
throughput. That is why the selected arm was then run on the thread ladder above.

## The pipeline, step by step

Driver: [`scripts/train/sbp.sh`](scripts/train/sbp.sh), run detached on the client. Server side:
[`scripts/server/sb-srv.sh`](scripts/server/sb-srv.sh) and
[`scripts/build/pg-build.sh`](scripts/build/pg-build.sh). PostgreSQL ran **unpinned** on all 192
vCPUs for every training and recording step. Each profile had to be taken with the server above 60%
busy, or the chain stopped.

| step | what | result |
|---|---|---|
| 0 | toolchain: gcc 15.2.0, AutoFDO `create_gcov`, llvm-bolt 18.1.3, PG source | |
| 1 | build `base`, `prep`, `pgogen` | 3 prefixes |
| 2 | sysbench data (250 x 1M rows) + golden copy | 61 GB database, 126 GB golden |
| 3 | calibrate the training load (gate: > 62% busy) | 3 x 400 = 1200 connections, 69.1% busy |
| 4 | PGO training on `pgogen` | 846 `.gcda` files |
| 5 | build `pgo`, `pgolto`, `pgoltoq` | |
| 6 | AutoFDO recording on `prep` | 22.6 GB perf.data |
| 7 | `create_gcov` | 1.79 MB `.afdo`, 1,699 functions |
| 8 | build `afdo`, `afdolto`, `afdoltoq` | |
| 9 | BOLT recordings on `pgoltoq` and `afdoltoq` | 2 x 2.0 GB perf.data |
| 10 | `perf2bolt` + `llvm-bolt` | `pgoltob` 81a3c772, `afdoltob` 347bd901 |
| 11 | md5 list | [`results/train-48xl/res/md5.txt`](results/train-48xl/res/md5.txt) |
| 12 | 7-arm benchmark | table above |

### 0. Toolchain ([`scripts/setup/srv-setup.sh`](scripts/setup/srv-setup.sh))

- **gcc 15.2.0**, from the GNU tarball:
  `configure --prefix=/opt/gcc15 --enable-languages=c,c++ --disable-multilib --disable-bootstrap --enable-lto --with-system-zlib`,
  then `make -j192`.
- **AutoFDO**, `google/autofdo` at commit `f95d1a1`:
  `cmake -G Ninja -DENABLE_TOOL=GCOV -DCMAKE_BUILD_TYPE=Release`, then `ninja create_gcov dump_gcov`.
- **llvm-bolt 18.1.3**, `llvm-project` tag `llvmorg-18.1.3`:
  `cmake -G Ninja ../llvm -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF`.
  Installs `llvm-bolt`, `perf2bolt` and `merge-fdata`.
- **PostgreSQL source**: git tag `REL_18_3` (`62d6c7d3df6`), stock, `NUM_XLOGINSERT_LOCKS` left at
  8. Each arm builds from a fresh `git archive` tree.

### 1, 5, 8. Builds ([`scripts/build/pg-build.sh`](scripts/build/pg-build.sh))

Every arm:

- is compiled with `-O3 -march=native -mtune=native` plus the flags below;
- uses the same configure line: `./configure --prefix=<arm> --with-openssl --with-readline CC=/opt/gcc15/bin/gcc`
  (no `--with-llvm`, so JIT is off);
- links with `-Wl,--build-id`, which `create_gcov` needs to match samples (no codegen change).

The LTO arms use `-flto=96 -ffat-lto-objects`, with `AR`/`RANLIB`/`NM` set to gcc 15's
`gcc-ar`/`gcc-ranlib`/`gcc-nm`. Builds run `make -j192`.

Each build is gated. The gate checks:
- `-O3` is present in `Makefile.global`;
- the expected flags appear on the compile lines;
- no gcov symbols are anywhere in the prefix (except `pgogen`);
- the binary is not already BOLTed;
- an initdb + SELECT smoke test passes.

The PGO arms reuse the `pgogen` tree, so each object finds its `.gcda` next to it. They delete
objects, `objfiles.txt` and linked executables but keep the `.gcda` files, and build with
`make enable_coverage=yes`.

`$P` below is `-fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile`.
`$AFDO` is the sysbench `.afdo` profile.

| arm | extra CFLAGS | extra LDFLAGS | md5 | .text bytes |
|---|---|---|---|---|
| base | none | none | `6085cabc` | 7,033,986 |
| prep (AutoFDO + BOLT input for base; not benchmarked) | `-g` | `-Wl,-q` | `e4fce276` | 7,033,986 |
| pgogen (instrumented) | `-fprofile-generate -fprofile-update=prefer-atomic` | `-fprofile-generate` | `780a3ca2` | 10,282,962 |
| pgo | `$P` | none | `2e16e7c8` | 7,075,634 |
| pgolto | `$P -flto=96 -ffat-lto-objects` | LTO flags | `4d540e3d` | 9,111,682 |
| pgoltoq (BOLT input) | pgolto + `-g` | LTO flags + `-Wl,-q` | `8ca3b172` | 9,111,682 |
| afdo | `-fauto-profile=$AFDO` | none | `116bdf01` | 7,236,210 |
| afdolto | LTO flags + `-fauto-profile=$AFDO` on the **compile and link line** | LTO flags + `-fauto-profile=$AFDO` | `75e183fd` | 9,107,090 |
| afdoltoq (BOLT input) | afdolto + `-g -fno-reorder-blocks-and-partition` | LTO flags + `-Wl,-q -fauto-profile=$AFDO -fno-reorder-blocks-and-partition` | `8a618222` | 9,049,474 |

Notes:

- **Compile-line profile:** gcc 15.2.0 builds `-flto` together with `-fauto-profile` with no ICE, so
  the profile goes on the compile line. The gate counted 1,298 compile lines carrying it. Passing it
  on the link line only would apply no profile at all.
- **Hot/cold splitting:** `afdoltoq` turns it off (`-fno-reorder-blocks-and-partition`), because
  `-fauto-profile` turns splitting on and BOLT handles pre-split functions badly. `pgoltoq` keeps it
  on.
- **base:** it has no `-g` and no `-Wl,-q`. Those live only in `prep`.

### 2. Dataset (`sb-srv.sh boot`, `init`, `snapshot`)

- **Memory:** 206 x 1 GB hugepages (69 / 69 / 68 per node) and a 180 GB tmpfs at `/mnt/pgramdisk`.
  The tmpfs uses the default memory policy.
- **Cluster:** `initdb` with base's binaries, the training config
  [`config/postgresql-training.conf`](config/postgresql-training.conf), `max_connections=4000`, and
  the role and database `sbtest`.
- **Load:**
  `sysbench --db-driver=pgsql --tables=250 --table-size=1000000 --rand-type=uniform --threads=50 oltp_read_write prepare`.
- **Golden copy:** `vacuumdb -z -j 64`, then `CHECKPOINT`, a fast stop, and `cp -a` to the golden
  directory. Every later start restores from it.

The training config has:
- `shared_buffers=200GB` on 1 GB hugepages;
- `synchronous_commit=off`, `full_page_writes=off`, `wal_level=minimal`, `wal_buffers=1GB`;
- `max_wal_size=64GB`, `checkpoint_timeout=30min`;
- `autovacuum=on` with 8 workers;
- `jit=off`.

### 3. Calibrating the training load

The client is sysbench 1.0.20 (`ebf1c90`) built with the pgsql driver, on a 64-vCPU r8i.16xlarge
about 0.34 ms from the server.

`base` runs unpinned while 400-thread sysbench processes are added one at a time. Each process is
capped at 400 threads because of a LuaJIT limit. Each step has a 120 s settle and a 240 s window.
**3 x 400 = 1200 connections gave 69.1% server busy and 70,877 tps**, which passed the 62% gate. Every
training and recording step below used this load.

### 4. PGO training

1. Delete the 850 stale `.gcda` files that the build's own tools left in the tree.
2. Start `pgogen`. `pg_ctl` and `psql` always come from base, so no instrumented tool writes into the
   profile.
3. Run 3 x 400 `oltp_read_write` for 960 s. The measured window is a 300 s settle plus 590 s:
   **87.3% busy, 31,669 tps** (the instrumented build is slower, so the box is busier).
4. Stop with `pg_ctl -m fast`, so the backend exit handlers write the counters.

Result: **846 `.gcda` files (774 from the backend), 1.69 MB**, archived as
[`profiles/pgogen-gcda-sysbench.tgz`](profiles/pgogen-gcda-sysbench.tgz). The gate requires more than
700 files and more than 60% busy.

### 6. AutoFDO recording (`sb-srv.sh record afdo prep 60`)

`prep` ran under the 1200-connection load. After a 120 s settle, perf recorded for 60 s inside a 240 s
window. The server was **71.1% busy at 65,191 tps**, and perf.data was 22.6 GB.

```
perf record -e cycles:u -j any,u -c 800011 --no-buildid --no-buildid-cache \
  -a -m 128M --proc-map-timeout 5000 -o afdo-prep.data -- sleep 60
```

### 7. `create_gcov` (`sb-srv.sh afdo-post`)

```
perf inject --build-ids -i afdo-prep.data -o afdo-prep.data.bid    # --no-buildid left the table empty
perf buildid-list -i afdo-prep.data --force                       # gate: prep's build-id must be listed
create_gcov --binary=<prep>/bin/postgres --profile=afdo-prep.data \
            --gcov=pg18-g15-sysbench.afdo --gcov_version=2        # gcc 15 needs --gcov_version=2
```

Result: [`profiles/pg18-g15-sysbench.afdo`](profiles/pg18-g15-sysbench.afdo), 1,788,768 bytes, 1,699
functions. The top function is `xmin_cmp`. The gate requires more than 200 KB and more than 500
functions.

### 9. BOLT recordings (`sb-srv.sh record bolt <arm> 60`)

The same load and window as step 6, on each BOLT input:

```
perf record -b -z1 --aio=4 -c 100003 -e branches:u --no-buildid --no-buildid-cache \
  -a -m 128M --proc-map-timeout 5000 -o bolt-<arm>.data -- sleep 60
```

| input | server busy | tps | perf.data |
|---|---|---|---|
| pgoltoq | 66.6% | 69,982 | 1.99 GB |
| afdoltoq | 69.3% | 68,923 | 1.99 GB |

### 10. BOLT ([`scripts/build/g15-bolt.sh`](scripts/build/g15-bolt.sh))

```
cp <pgoltoq>/bin/postgres W/postgres          # keep the file name: perf2bolt matches by name
perf2bolt -p bolt-pgoltoq.data -o profile.fdata W/postgres
llvm-bolt W/postgres -o postgres.bolt -data=profile.fdata \
  -reorder-blocks=ext-tsp -reorder-functions=cdsort \
  -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections
cp -a <pgoltoq prefix> <pgoltob prefix>; install postgres.bolt -> <pgoltob>/bin/postgres
```

Gates:
- the input must have `.rela.text` and must not already be BOLTed;
- the fdata file must be larger than 500 KB;
- more than 200 functions must have a profile.

| output | fdata | profiled functions | md5 |
|---|---|---|---|
| **pgoltob** | 1.84 MB | 1,330 of 21,056 (6.3%) | `81a3c772` |
| afdoltob | 1.66 MB | 1,203 of 14,990 (8.0%) | `347bd901` |

The fdata files and BOLT logs are in [`profiles/bolt-pgoltob/`](profiles/bolt-pgoltob/) and
[`profiles/bolt-afdoltob/`](profiles/bolt-afdoltob/).

### 12. Training-box benchmark

`sbp.sh` step 12 ran all 7 arms in the order base, afdo, afdolto, afdoltob, pgo, pgolto, pgoltob,
then the reverse. Each arm got a fresh golden restore and a server start, then one sysbench process at
64 and then 128 threads, each with 120 s warm-up plus 240 s measured. Results are in
[`results/train-48xl/`](results/train-48xl/).

## How the machine-size ladder was run

The ladder scripts are in [`scripts/ladder/`](scripts/ladder/): `sb48.sh` / `sb24.sh` / `sb16.sh` run
on the client, and the matching `-srv.sh` scripts run on the server.

| | 48xl | 24xl | 16xl |
|---|---|---|---|
| dataset | 250 x 2.4M rows | 250 x 1.2M rows | 250 x 0.8M rows |
| `shared_buffers` / 1 GB hugepages | 384 GB / 402 | 192 GB / 201 | 128 GB / 134 |
| datadir tmpfs | interleaved over 3 nodes | 450 GB, interleaved over 2 nodes | 300 GB, 1 node |

The dataset sizes match each box's HammerDB TPROC-C warehouse count (1536 / 768 / 512 WH).

Common to all three boxes:

- **Server config:** `max_connections=2500`, `synchronous_commit=off`, `full_page_writes=off`,
  `wal_level=minimal`, `wal_buffers=1GB`, `min_wal_size=24GB`, `jit=off`, `bgwriter_delay=10ms`.
- **Measurement overrides:** `autovacuum=off`, `autovacuum_freeze_max_age` and
  `autovacuum_multixact_freeze_max_age` = 1.5B, `checkpoint_timeout=1h`, `max_wal_size=800GB`. These
  keep checkpoints and autovacuum out of every measured window; each rung logged 0 of both.
- **Server process:** PostgreSQL unpinned on all vCPUs.
- **Operation:**
  1. Load the data once, then `vacuumdb -z -j64`, `CHECKPOINT`, and a golden copy to EBS.
  2. Run 6 mirrored passes. Each pass does a fresh golden restore and a server start, and the running
     exe is checked against the arm's md5.
  3. Within a pass, run rungs of 32, 64, 128, 256, 512 and 1024 threads.
  4. Each rung uses `ceil(threads/256)` sysbench processes (`oltp_read_write --rand-type=uniform --report-interval=10`),
     with 120 s warm-up and 240 s measured.
- **Metrics:**
  - **tps:** the mean of the 10 s interval tps after 120 s, summed over the processes.
  - **p95:** the mean of the interval `(ms,95%)` values.
  - **Server and client busy %:** from `/proc/stat` over the measured window.
  - **CPU/txn:** busy / tps, compared with base.
- **p95 on the 48xl:** the 48xl driver searched for the wrong p95 label, so its `bench.tsv` p95 column
  is 0. The 48xl p95 was recomputed from the raw logs into
  [`results/ladder-48xl/res/p95-recomputed.tsv`](results/ladder-48xl/res/p95-recomputed.tsv). Also on
  the 48xl, the `errs` column counted sysbench's own `ignored errors:` summary line, which equals the
  number of processes, not real errors. The 24xl and 16xl drivers fix both problems.

### Training vs measurement

The profile was trained at one heavy load point and measured across the whole thread range. The
setups differ:

| | training (step 4, 6, 9) | ladder measurement |
|---|---|---|
| dataset | 250 x 1M rows | 2.4M / 1.2M / 0.8M rows |
| `shared_buffers` | 200 GB on 206 hugepages | 384 / 192 / 128 GB |
| autovacuum / checkpoints | on / 30 min, 64 GB | off / 1 h, 800 GB |
| `max_connections` | 4000 | 2500 |
| load | fixed 1200 connections (3 x 400), 66-87% busy | 32 to 1024 threads |
| tmpfs placement | default policy | interleaved (48xl, 24xl) |

## Files

```
gcc15/
  scripts/setup/srv-setup.sh          toolchain build (gcc 15.2.0, AutoFDO, llvm-bolt 18.1.3, PG source)
  scripts/setup/autofdo-rev.txt       AutoFDO commit used
  scripts/build/pg-build.sh           one script, every arm (flags and gates as above)
  scripts/build/g15-bolt.sh           perf2bolt + llvm-bolt
  scripts/server/sb-srv.sh            server side of training: boot, init, snapshot, start/stop, record, afdo-post
  scripts/train/sbp.sh                client driver: steps 0-13 (calibrate, train, record, build, bolt, benchmark)
  scripts/ladder/sb{48,24,16}.sh      client drivers of the machine-size ladder
  scripts/ladder/sb{48,24,16}-srv.sh  server side of the ladder (config, golden restore, start/stop)
  config/postgresql-training.conf     training config
  profiles/pg18-g15-sysbench.afdo     AutoFDO profile (create_gcov output)
  profiles/pgogen-gcda-sysbench.tgz   PGO counters (.gcda) from step 4
  profiles/bolt-{pgoltob,afdoltob}/   BOLT profile.fdata + perf2bolt/llvm-bolt logs
  logs/server/                        build gates (build-*.out), create_gcov, perf, per-arm server logs
  results/train-48xl/                 calibration, training, recording and 7-arm benchmark (res/ + raw sysbench logs)
  results/ladder-{48,24,16}xl/        ladder results: res/bench.tsv, res/summary.md, res/md5.txt, raw sysbench logs
```

Private addresses in the scripts and logs are replaced with `<PRIVATE_IP>`, `<host>` and
`<VPC_CIDR>`.
