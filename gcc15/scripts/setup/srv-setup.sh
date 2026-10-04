#!/bin/bash
# New 48xl sysbench-training box: toolchain, same recipe as the HammerDB gcc15 box. Detached; logs in ~/g15/.
mkdir -p ~/g15 && cd ~/g15
sudo dnf -y install gcc gcc-c++ make cmake ninja-build git gmp-devel mpfr-devel libmpc-devel flex bison \
  readline-devel openssl-devel zlib-devel libicu-devel perf elfutils-libelf-devel libzstd-devel \
  python3 tar xz wget numactl time sysstat rsync file protobuf-devel > dnf.log 2>&1 && echo DNF-OK || echo DNF-FAIL
( wget -q https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz && tar xf gcc-15.2.0.tar.xz && \
  mkdir -p gcc-build && cd gcc-build && \
  ../gcc-15.2.0/configure --prefix=/opt/gcc15 --enable-languages=c,c++ --disable-multilib --disable-bootstrap \
     --enable-lto --with-system-zlib > ../gcc-conf.log 2>&1 && \
  make -j192 > ../gcc-make.log 2>&1 && sudo make install > ../gcc-install.log 2>&1 && echo GCC15-OK || echo GCC15-FAIL ) > gcc.status 2>&1 &
( git clone -q --recursive https://github.com/google/autofdo.git > af-clone.log 2>&1; cd autofdo && git checkout -q f95d1a1 && git submodule update -q --init --recursive && git log -1 --format=%h > ../af-rev && \
  mkdir -p build-gcov && cd build-gcov && \
  cmake -G Ninja -DENABLE_TOOL=GCOV -DCMAKE_BUILD_TYPE=Release .. > ../../af-cmake.log 2>&1 && \
  ninja -j96 create_gcov dump_gcov > ../../af-build.log 2>&1 && echo AFDO-OK || echo AFDO-FAIL ) > af.status 2>&1 &
( git clone -q --depth 1 -b llvmorg-18.1.3 https://github.com/llvm/llvm-project.git llvm-18.1.3 && mkdir -p llvm-18.1.3/build && cd llvm-18.1.3/build && \
  cmake -G Ninja ../llvm -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF -DCMAKE_INSTALL_PREFIX=/opt/llvm-bolt-18.1.3 > ../../bolt-cmake.log 2>&1 && \
  ninja -j64 bolt > ../../bolt-build.log 2>&1 && sudo ninja install-llvm-bolt install-perf2bolt install-merge-fdata > ../../bolt-install.log 2>&1 && echo BOLT-OK || echo BOLT-FAIL ) > bolt.status 2>&1 &
( cd ~ && git clone -q https://git.postgresql.org/git/postgresql.git postgres && cd postgres && git log --oneline -1 REL_18_3 && echo PGSRC-OK || echo PGSRC-FAIL ) > pgsrc.status 2>&1 &
wait; echo ALL-DONE $(date -u +%T)
