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
