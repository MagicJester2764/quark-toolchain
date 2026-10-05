#!/bin/sh
# Lay out the Rust compiler that runs on Quark, as a root.
#
#     ./rust-native.sh <components-dir> [outdir]
#
# rustc and cargo are not built here. The Rust project publishes them built
# for x86_64-unknown-linux-musl — position-independent, linked to libc.so,
# their own code making some of Linux's system calls itself — and Quark runs
# such a program on its C library: one that asks for its loader by Linux's
# name is told it was built for Linux, and libc.so answers the calls its own
# code makes (quarkutils' CLAUDE.md, *Shared libraries*). What this does is
# lay them out where they run, under /usr — where musl finds
# librustc_driver on its default path, since musl would resolve rustc's
# $ORIGIN through /proc/self/exe, which Quark has not got — in `outdir`
# (~/opt/native-rust by default), for a distribution to stage.
#
# <components-dir> holds the nightly the userland is pinned to (its
# rust-toolchain.toml says which), each tarball with its signature, and the
# key they are signed with:
#
#   rustc-nightly-x86_64-unknown-linux-musl.tar.xz
#   cargo-nightly-x86_64-unknown-linux-musl.tar.xz
#   rust-std-nightly-x86_64-unknown-linux-musl.tar.xz  build scripts, proc macros
#   rust-std-nightly-x86_64-unknown-none.tar.xz        the kernel, no_std programs
#   rust-src-nightly.tar.xz                            the library's source, which
#                                                      -Z build-std compiles: the
#                                                      kernel's two modules do
#   rust-key.gpg.ascii                                 the Rust release key
#
# Each is checked against its signature before it is unpacked; the key's
# fingerprint is the caller's to have checked when it was fetched.
#
# Left out: what rustlib's bin/ holds — rust-lld, rust-objcopy and the
# linkers' wrappers — is linked at 0x400000, below where Quark maps
# anything, and cannot run there; GNU ld links instead, which cargo is told
# by a configuration that is a distribution's to give. And the
# documentation, the debuggers' scripts, and rust-analyzer's macro server.
# What runs is stripped, keeping the dynamic symbols and the unwind tables:
# librustc_driver is 230 MB so.
#
# And libgcc_s.so.1, which every one of them asks for, for unwinding.
# Quark's libgcc is static, and gcc's unwinder finds a program's frames
# through dl_iterate_phdr only on systems its source names; LLVM's does on
# any ELF system, and Rust's own musl runtime carries it, built
# position-independent (rust-std's self-contained libunwind.a). It is linked
# whole into a shared object of that name, with libgcc_s.so beside it for a
# program rustc links on Quark to find.
set -e
SRC=${1:?usage: rust-native.sh <components-dir> [outdir]}
OUT=${2:-$HOME/opt/native-rust}
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
COMPONENTS="rustc-nightly-x86_64-unknown-linux-musl cargo-nightly-x86_64-unknown-linux-musl
rust-std-nightly-x86_64-unknown-linux-musl rust-std-nightly-x86_64-unknown-none rust-src-nightly"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gpg --dearmor < "$SRC/rust-key.gpg.ascii" > "$WORK/rust-key.gpg"
for c in $COMPONENTS; do
    echo "==> $c"
    gpgv --keyring "$WORK/rust-key.gpg" "$SRC/$c.tar.xz.asc" "$SRC/$c.tar.xz"
    tar -C "$WORK" -xJf "$SRC/$c.tar.xz"
    sh "$WORK/$c/install.sh" --prefix=/usr --destdir="$OUT" --disable-ldconfig
    rm -rf "$WORK/$c"
done

echo "==> what cannot run on Quark, and what is not needed there"
rm -rf "$OUT/usr/lib/rustlib/x86_64-unknown-linux-musl/bin" "$OUT/usr/share" \
       "$OUT/usr/libexec" "$OUT/usr/etc"
rm -f "$OUT/usr/bin/rust-gdb" "$OUT/usr/bin/rust-gdbgui" "$OUT/usr/bin/rust-lldb"

echo "==> stripped"
for f in "$OUT/usr/bin/rustc" "$OUT/usr/bin/rustdoc" "$OUT/usr/bin/cargo" \
         "$OUT"/usr/lib/librustc_driver-*.so; do
    x86_64-quark-strip --strip-unneeded "$f"
done

echo "==> libgcc_s.so.1"
x86_64-quark-musl-gcc -shared -fPIC -o "$OUT/usr/lib/libgcc_s.so.1" -Wl,-soname,libgcc_s.so.1 \
    -Wl,--whole-archive \
    "$OUT/usr/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained/libunwind.a" \
    -Wl,--no-whole-archive
x86_64-quark-strip --strip-unneeded "$OUT/usr/lib/libgcc_s.so.1"
cp "$OUT/usr/lib/libgcc_s.so.1" "$OUT/usr/lib/libgcc_s.so"

echo
echo "Rust for Quark is in $OUT, laid out as its root:"
echo "    rustc -vV      # there"
