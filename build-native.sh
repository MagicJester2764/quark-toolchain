#!/bin/sh
# Build the compilers that run on Quark: binutils and gcc whose host is
# x86_64-quark as well as their target, laid out as a root.
#
#     ./build-native.sh /path/to/binutils-gdb /path/to/gcc [outdir]
#
# A Canadian cross: built here, by the cross compilers build.sh made, to run
# there and make programs for there. What comes out is a directory laid out
# like the root of a Quark system — usr/bin/gcc, g++, cc, as, ld and the
# rest, the compilers' own programs under usr/libexec, and what they compile
# against: musl's headers and archives, libstdc++, the layer musl's calls go
# through, Linux's userspace headers and Quark's own — for a distribution to
# stage. `~/opt/native` unless an outdir is given. Its build directories,
# `build-*-native`, are made where this is run, as build.sh's are.
#
# Needs everything README.md's order makes first: the cross compilers on
# PATH, musl and libstdc++ installed (build-musl.sh, build-libstdcxx.sh), and
# Linux's headers (install-linux-headers.sh). The trees are the ones build.sh
# patched; this applies the patches again, which does nothing to a tree that
# has them.
#
# gcc needs GMP, MPFR and MPC to run, so they are built for Quark too, from
# their tarballs in $QUARK_SRC (~/opt/src): GMP 6.3.0, MPFR 4.2.2 and
# MPC 1.3.1, each checked against its signature when it was fetched. GMP's
# configure tests the compiler with C written before C23, so GMP is told
# which C it is written in.
#
# On Quark the compiler's C library is musl, as x86_64-quark-musl-gcc's is
# here, and its headers are /usr/include. So the compiler there needs none
# of the wrapper's -nostdinc: its own order — libstdc++'s directories, its
# own, then /usr/include — is the right one, and is the one C++ needs, whose
# headers reach the C library's with #include_next. What the compiler is
# told about the C library it learns while it is built: musl's headers are
# laid out in the output first and are the build's sysroot, so the limits.h
# it makes for itself goes on to musl's rather than standing in for it.
#
# What is left for the specs is which files a program is linked from, and
# that is a file in the compiler's library directory, read in place of its
# built-in specs — so it is all of them, the target's as the cross compiler
# has them with cross_compile turned off, and musl's start files and
# libraries on top. The small C library in quarkutils, which
# x86_64-quark-gcc links against here, is not on Quark: one /usr/lib cannot
# hold two libc.a.
#
# Static, as every compiler here is, and with no debugging information:
# cc1 and cc1plus are forty megabytes each stripped.
set -e
BINUTILS_SRC=${1:?usage: build-native.sh <binutils-src> <gcc-src> [outdir]}
GCC_SRC=${2:?usage: build-native.sh <binutils-src> <gcc-src> [outdir]}
OUT=${3:-$HOME/opt/native}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${QUARK_SRC:-$HOME/opt/src}
CROSS=${CROSS:-$HOME/opt/cross}
MUSL=${MUSL:-$CROSS/x86_64-quark/musl}
SYSROOT=$CROSS/x86_64-quark/sys-root
QUARKUTILS_DIR=${QUARKUTILS_DIR:-$HERE/../quarkutils}
QUARKUTILS_DIR=$(cd "$QUARKUTILS_DIR" && pwd)
JOBS=${JOBS:-$(nproc)}
TARGET=x86_64-quark
BUILD=$(sh "$GCC_SRC/config.guess")
WORK=$(pwd)
VER=$(x86_64-quark-gcc -dumpversion)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
GCCLIB=$OUT/usr/lib/gcc/$TARGET/$VER

echo "==> patching $BINUTILS_SRC and $GCC_SRC"
( cd "$BINUTILS_SRC" && patch -p1 -N -r - < "$HERE/patches/binutils-x86_64-quark.patch" || true )
( cd "$GCC_SRC" && patch -p1 -N -r - < "$HERE/patches/gcc-x86_64-quark.patch" || true )
cp "$HERE/patches/gcc-config-quark.h" "$GCC_SRC/gcc/config/quark.h"
cp "$HERE/patches/gcc-config-quark.opt" "$GCC_SRC/gcc/config/quark.opt"
cp "$HERE/patches/gcc-config-quark.opt.urls" "$GCC_SRC/gcc/config/quark.opt.urls"

HOSTCC="CC=x86_64-quark-musl-gcc CXX=x86_64-quark-musl-g++ AR=x86_64-quark-ar RANLIB=x86_64-quark-ranlib"

# What the compilers compile against, first: gcc is built with it as its
# sysroot.
echo "==> musl, libstdc++ and Quark's own, into $OUT"

# musl's headers, by musl's own list — what its tarball has under include/
# and its architecture's bits — taken from where they were installed, the
# generated ones with them. musl's prefix holds every port's headers too,
# and those are a distribution's, not the compiler's.
LIST=$(mktemp -d)
tar -C "$LIST" -xzf "$SRC/musl-1.2.5.tar.gz"
M=$(ls -d "$LIST"/musl-*)
{
    ( cd "$M/include" && find . -type f -name '*.h' | sed 's|^\./||' )
    ( cd "$M/arch/generic" && find bits -type f -name '*.h' )
    ( cd "$M/arch/x86_64" && find bits -type f -name '*.h' )
    echo bits/alltypes.h
    echo bits/syscall.h
} | sort -u > "$LIST/headers"
mkdir -p "$OUT/usr/include" "$OUT/usr/lib"
while read -r h; do
    mkdir -p "$OUT/usr/include/$(dirname "$h")"
    cp "$MUSL/include/$h" "$OUT/usr/include/$h"
done < "$LIST/headers"
rm -rf "$LIST"

# musl's startup files and archives. The empty ones are there for a build
# that passes -lm, -lpthread or the rest, as on Linux. libc.so is not here:
# it is the C library every program linked to it runs on and its loader
# too, kept under three names, and a distribution stages it — a second
# copy staged over the first would be the one the compiler links against
# and not the one programs run on.
for f in crt1.o crti.o crtn.o Scrt1.o rcrt1.o libc.a libcrypt.a libdl.a \
         libm.a libpthread.a libresolv.a librt.a libutil.a libxnet.a; do
    cp "$MUSL/lib/$f" "$OUT/usr/lib/"
done

# C++: the headers where a native g++ looks for them, and the archives.
mkdir -p "$OUT/usr/include/c++"
rm -rf "$OUT/usr/include/c++/$VER"
cp -R "$MUSL/include/c++/$VER" "$OUT/usr/include/c++/$VER"
for f in libstdc++.a libsupc++.a libstdc++exp.a; do
    if [ -f "$MUSL/lib/$f" ]; then cp "$MUSL/lib/$f" "$OUT/usr/lib/"; fi
done

# Linux's userspace headers, for a program that includes <linux/...>.
for d in linux asm asm-generic; do
    rm -rf "$OUT/usr/include/$d"
    cp -R "$MUSL/include/$d" "$OUT/usr/include/$d"
done

# Quark's: the layer musl's calls go through, the object that carries a
# program's manifest, the link script the target's link spec names, and the
# platform headers. The kernel installs its own beside these, quark/abi.h.
mkdir -p "$OUT/usr/lib/quark" "$OUT/usr/include/quark"
cp "$QUARKUTILS_DIR/linux-abi/liblinux-abi.a" "$QUARKUTILS_DIR/linux-abi/src/manifest.o" "$OUT/usr/lib/quark/"
cp "$SYSROOT/usr/lib/quark.ld" "$OUT/usr/lib/quark.ld"
cp "$QUARKUTILS_DIR"/libc/include/quark/*.h "$OUT/usr/include/quark/"

# What gcc needs to run, for Quark.
echo "==> gmp, mpfr, mpc"
DEPS=$WORK/build-deps-native
rm -rf "$DEPS"
mkdir -p "$DEPS/src"
for t in gmp-6.3.0.tar.xz mpfr-4.2.2.tar.xz mpc-1.3.1.tar.gz; do
    tar -C "$DEPS/src" -xf "$SRC/$t"
done
"$HERE/teach-config-sub.sh" "$DEPS/src/gmp-6.3.0/configfsf.sub"
"$HERE/teach-config-sub.sh" "$DEPS/src/mpfr-4.2.2/config.sub"
"$HERE/teach-config-sub.sh" "$DEPS/src/mpc-1.3.1/build-aux/config.sub"
( cd "$DEPS/src/gmp-6.3.0" && ./configure --build="$BUILD" --host=$TARGET \
      --prefix="$DEPS/prefix" --disable-shared --enable-static \
      $HOSTCC CFLAGS="-O2 -std=gnu17" && make -j"$JOBS" && make install )
( cd "$DEPS/src/mpfr-4.2.2" && ./configure --build="$BUILD" --host=$TARGET \
      --prefix="$DEPS/prefix" --disable-shared --enable-static \
      --with-gmp="$DEPS/prefix" $HOSTCC CFLAGS=-O2 && make -j"$JOBS" && make install )
( cd "$DEPS/src/mpc-1.3.1" && ./configure --build="$BUILD" --host=$TARGET \
      --prefix="$DEPS/prefix" --disable-shared --enable-static \
      --with-gmp="$DEPS/prefix" --with-mpfr="$DEPS/prefix" $HOSTCC CFLAGS=-O2 && \
  make -j"$JOBS" && make install )

# The tools, without the libraries they are made of: libbfd and its
# headers are installed by default where host and target are the same, and
# nothing on Quark builds against them.
echo "==> binutils"
rm -rf "$WORK/build-binutils-native"
mkdir -p "$WORK/build-binutils-native"
( cd "$WORK/build-binutils-native" && "$BINUTILS_SRC/configure" \
      --build="$BUILD" --host=$TARGET --target=$TARGET \
      --prefix=/usr --with-sysroot=/ --disable-install-libbfd \
      --disable-nls --disable-werror --disable-gdb --disable-gdbserver \
      --disable-sim --disable-libdecnumber --disable-readline \
      --disable-gprofng --disable-gold --without-zstd \
      $HOSTCC CFLAGS=-O2 CXXFLAGS=-O2 && \
  make -j"$JOBS" && make install DESTDIR="$OUT" )

# The compiler, and nothing built for the target: libgcc is the cross
# compiler's, which is the same library for the same target.
echo "==> gcc"
rm -rf "$WORK/build-gcc-native"
mkdir -p "$WORK/build-gcc-native"
( cd "$WORK/build-gcc-native" && "$GCC_SRC/configure" \
      --build="$BUILD" --host=$TARGET --target=$TARGET \
      --prefix=/usr --with-sysroot=/ --with-build-sysroot="$OUT" \
      --with-gmp="$DEPS/prefix" --with-mpfr="$DEPS/prefix" --with-mpc="$DEPS/prefix" \
      --enable-languages=c,c++ --enable-initfini-array \
      --disable-nls --disable-shared --disable-threads --disable-multilib \
      --disable-bootstrap --disable-lto --disable-plugin \
      --disable-libssp --disable-libquadmath --disable-libatomic \
      --disable-libgomp --disable-libvtv --disable-libstdcxx \
      $HOSTCC CFLAGS=-O2 CXXFLAGS=-O2 && \
  make -j"$JOBS" all-gcc && make install-gcc DESTDIR="$OUT" )
cp "$CROSS/lib/gcc/$TARGET/$VER/libgcc.a" "$CROSS/lib/gcc/$TARGET/$VER/crtbegin.o" \
   "$CROSS/lib/gcc/$TARGET/$VER/crtend.o" "$GCCLIB/"
# The name build systems call a C compiler by.
cp "$OUT/usr/bin/gcc" "$OUT/usr/bin/cc"

# What the installs leave twice: the compilers again under the target's
# prefixed names, ld again as ld.bfd, and binutils' programs again in the
# target's own directory, where a cross compiler looks for them — here they
# are on PATH. And fixincludes' copies of musl's headers: musl needs no
# fixing, and a copy in include-fixed stands in front of the header it was
# made from for as long as the compiler is installed, whatever /usr/include
# holds by then.
for f in gcc "gcc-$VER" g++ c++ gcc-ar gcc-nm gcc-ranlib; do
    rm -f "$OUT/usr/bin/$TARGET-$f"
done
rm -f "$OUT/usr/bin/ld.bfd"
rm -rf "$OUT/usr/$TARGET" "$GCCLIB/include-fixed"

echo "==> specs"
x86_64-quark-gcc -dumpspecs | awk '
    /^\*cross_compile:$/ { print; getline; print "0"; next }
    { print }' > "$GCCLIB/specs"
# The dump ends with a blank line, and two together end the file as far as
# gcc reads it: what is added begins at once.
cat >> "$GCCLIB/specs" <<'SPECS'
# musl, as the C library: the files a program is linked from, as
# x86_64-quark-musl-gcc's specs name them on the build machine, at the paths
# they have here. crtbegin.o and crtend.o bracket the rest of a static
# program, so that a C++ program's table of frames has a beginning and an
# end. A program linked -pie and a shared object take neither, as the
# wrapper's do not: they are built for the large model, as a static program
# is, and their absolute addresses would be relocations in its text — which
# the loaders map read-only, so that musl relocating it faults.
#
# Static, as everything here is, unless asked: -shared makes a shared
# object and -pie a program linked to libc.so that the loaders put where
# they choose — which is how rustc links what it builds for this system
# itself (its build scripts, its macros), and what the wrapper's second
# specs file makes of -dynamic on the build machine. The target's link
# spec says -static and names Quark's link script, so it is replaced whole.
*link:
%{shared:-shared;pie:-dynamic-linker /usr/lib/ld-musl-x86_64.so.1;:-static -no-pie %{!T*:-T /usr/lib/quark.ld}} -z noexecstack --build-id=none %{rdynamic:-export-dynamic}

*startfile:
%{shared:/usr/lib/crti.o;pie:/usr/lib/Scrt1.o /usr/lib/quark/manifest.o /usr/lib/crti.o;:/usr/lib/crt1.o /usr/lib/crti.o crtbegin.o%s /usr/lib/quark/manifest.o}

*endfile:
%{shared|pie:;:crtend.o%s} /usr/lib/crtn.o

# -pthread asks for a threading library and a feature macro, and musl has
# neither: its threads are in libc. The target declares it (quark.opt), and
# named here it is an option the driver takes and does nothing with, which
# is what the wrapper on the build machine makes it by taking it out. Only
# an option the driver knows can be vouched for by these specs, the
# compiler's own; a -specs file of a user's could vouch for any.
*lib:
%{pthread:} %{shared|pie:-lc;:/usr/lib/libc.a /usr/lib/quark/liblinux-abi.a}

# Position-independent code in the small code model, as the wrapper on the
# build machine has it: in the target's large one, code built -fPIC reaches
# its globals through a table whose base it never sets up. And no linker
# plugin: the dump these specs begin with is the cross compiler's, which has
# one for LTO, and this compiler has neither.
*self_spec:
%{fPIC|fpic|fPIE|fpie:-mcmodel=small} -fno-use-linker-plugin
SPECS

echo "==> stripped"
for f in "$OUT"/usr/bin/* \
         "$OUT/usr/libexec/gcc/$TARGET/$VER"/cc1 "$OUT/usr/libexec/gcc/$TARGET/$VER"/cc1plus \
         "$OUT/usr/libexec/gcc/$TARGET/$VER"/collect2 "$OUT/usr/libexec/gcc/$TARGET/$VER"/lto-wrapper; do
    if [ -f "$f" ]; then x86_64-quark-strip "$f" 2>/dev/null || true; fi
done
rm -rf "$OUT/usr/share/info" "$OUT/usr/share/man" "$OUT/usr/lib/bfd-plugins"

echo
echo "The compilers for Quark are in $OUT, laid out as its root:"
echo "    gcc hello.c -o hello      # there"
