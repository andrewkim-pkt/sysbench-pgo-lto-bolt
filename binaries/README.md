# Prebuilt binaries

`pg18fc-afdoltob.tar.xz` is the complete install tree of the **afdoltob** arm from the full-CPU
campaign (`fc-mirror-2800c-20260925T102315Z`). It is the tree that was benchmarked, taken from
`/opt/pg18fc-afdoltob`.

| | |
|---|---|
| Version | PostgreSQL 18.3 (REL_18_3, `62d6c7d3df6`) |
| Build | afdoltoq (`-O3 -march=native -mtune=native -flto -ffat-lto-objects -g -fno-reorder-blocks-and-partition`, `-Wl,-q`, `-fauto-profile` on the link line only), then llvm-bolt 18.1.3 with [`profiles/full-cpu/bolt-afdoltob/profile.fdata`](../profiles/full-cpu/bolt-afdoltob/profile.fdata) |
| `bin/postgres` md5 | `2d3b38b0dee15cade7abe9cbb87440bf` |
| Result | +6.12% tps vs base (A/B spread 2.88%), −5.4% server CPU per transaction |

The AutoFDO profile has no effect under LTO (see the main README), so this binary is effectively
**LTO + BOLT**.

**Target:** built with `-march=native` on an Intel Xeon 6975P-C (Granite Rapids). It will likely stop
with an illegal-instruction error on CPUs without the same ISA extensions. It is also linked against
Amazon Linux 2023 system libraries (OpenSSL 3, ICU 67, zlib), and it expects to live at
`/opt/pg18fc-afdoltob`.

```
sha256sum -c SHA256SUMS
sudo tar xJf pg18fc-afdoltob.tar.xz -C /opt
/opt/pg18fc-afdoltob/bin/postgres --version
```

**Client tools and `libpq`:** the tree was cloned from the afdoltoq install, so `psql` and the other
client tools have `RUNPATH=/opt/pg18fc-afdoltoq/lib`. The server binary (`bin/postgres`) does not use
`libpq` and is unaffected. For the client tools, either add a symlink or set `LD_LIBRARY_PATH`:

```
sudo ln -sfn /opt/pg18fc-afdoltob /opt/pg18fc-afdoltoq
# or: export LD_LIBRARY_PATH=/opt/pg18fc-afdoltob/lib
```

## `g15sb-pg18-pgoltob.tar.xz`: gcc 15.2.0, sysbench-trained pgoltob

This is the complete install tree of the **sysbench-trained gcc 15.2.0 `pgoltob`** arm, the
`sbpgoltob` binary in [`../gcc15/README.md`](../gcc15/README.md). It was packed unchanged from the
tree that ran the 24xl and 16xl ladders (`/opt/g15sb-pg18-pgoltob`), which is a byte copy of the
tree built on the training box.

| | |
|---|---|
| Version | PostgreSQL 18.3 (REL_18_3, `62d6c7d3df6`) |
| Compiler | gcc 15.2.0 |
| Build | pgoltoq (`-O3 -march=native -mtune=native -fprofile-use -fprofile-correction -fprofile-partial-training -flto=96 -ffat-lto-objects -g`, `-Wl,-q -Wl,--build-id`), then llvm-bolt 18.1.3 with [`../gcc15/profiles/bolt-pgoltob/profile.fdata`](../gcc15/profiles/bolt-pgoltob/profile.fdata) |
| Training | sysbench `oltp_read_write`, 250 x 1M rows, 1200 connections, whole r8i.metal-48xl, unpinned |
| archive size | 37,381,888 bytes |
| archive md5 | `6e885f961f3652c0d9e6b0626fbc0f01` |
| archive sha256 | `2be96c833f553d64bd0d736969c1fd1c417069b736f4e729a1b8d9c0fb99db26` |
| unpacked | 150 MB, 1,655 files, not stripped |
| `bin/postgres` md5 | `81a3c772a9b4849fe1198ac57ceca802` |
| Result | sysbench ladder +4.33% (48xl) / +6.46% (24xl) / +9.26% (16xl) mean tps vs base, 8-22% less CPU per transaction |

```
sha256sum -c SHA256SUMS
sudo tar xJf g15sb-pg18-pgoltob.tar.xz -C /opt --no-same-owner
/opt/g15sb-pg18-pgoltob/bin/postgres --version
```

- **Not instrumented:** `bin/postgres`, `psql` and `pgbench` all have 0 gcov symbols.
- **Target:** built with `-march=native` on an Intel Xeon 6975P-C (Granite Rapids), so it will likely
  stop with an illegal-instruction error on other CPUs. It needs Amazon Linux 2023 system libraries
  (OpenSSL 3, ICU 67, zlib).
- **Prefix:** `pg_config --configure` reports `--prefix=/opt/g15-pg18-pgoltoq`, because the tree was
  cloned from the BOLT input install. The server finds `lib/` and `share/` relative to its own binary,
  so it works wherever it is unpacked.
- **Client tools:** the client tools have `RUNPATH=/opt/g15-pg18-pgoltoq/lib`. The server binary
  (`bin/postgres`) does not use `libpq` and is unaffected. For the client tools, add a symlink or set
  `LD_LIBRARY_PATH`:

```
sudo ln -sfn /opt/g15sb-pg18-pgoltob /opt/g15-pg18-pgoltoq
# or: export LD_LIBRARY_PATH=/opt/g15sb-pg18-pgoltob/lib
```
