#!/bin/sh
# Build musl for Quark.
#
#     ./build-musl.sh /path/to/musl-1.2.5
#
# Needs the x86_64-quark toolchain on PATH (build.sh) and the translation
# layer built twice, as it is for programs and position-independent for the
# shared library (`make -C ../quarkutils/linux-abi all pic`).
#
# musl is written against Linux — not against "a kernel", but against Linux's
# numbers, argument order, error convention and idea of what a process is.
# Quark's calls are a different set with different semantics, so this is a
# translation layer rather than a port, and the layer lives in Quark's tree
# where it can talk to the servers that actually answer most of it.
#
# The patch is seven files and no more, which is the interesting part: musl's
# system call interface really is that narrow. Three of them are about issuing
# a system call at all, and one about where a program is: half a terabyte up,
# out of reach of the four-byte reference to _DYNAMIC that musl's entry makes
# and only its dynamic loader needs. The other three are the places musl asks the kernel for
# something Quark does not have the shape of, each of which becomes a tail
# call into the translation layer: `clone`, where Linux has the child *return
# from the same call* on a new stack and Quark starts a task at an entry
# point; `vfork`, where the child returns through a stack it has borrowed; and
# the end of a detached thread, which unmaps the stack it is standing on.
#
# How a program finds its arguments is not among them any more. Quark's
# loaders leave on a new program's stack what Linux's kernel leaves there —
# argc, argv, the environment and the auxiliary vector — so musl's own entry
# reads it, and its dynamic loader, which cannot call anything until it has
# relocated itself, reads it too.
#
# musl is built shared as well as static: `libc.so`, with the translation
# layer in it, is the C library of a program linked to it and is its dynamic
# loader too, as it is on Linux. A program asks for that with `-dynamic`
# (musl-wrappers.sh); static is still what it gets otherwise.
set -e

MUSL_SRC=${1:?usage: build-musl.sh <musl-src>}
PREFIX=${PREFIX:-$HOME/opt/cross/x86_64-quark/musl}
HERE=$(cd "$(dirname "$0")" && pwd)
QUARKUTILS_DIR=${QUARKUTILS_DIR:-$HERE/../quarkutils}
LAYER=$(cd "$QUARKUTILS_DIR/linux-abi" && pwd)/liblinux-abi-pic.a
if [ ! -f "$LAYER" ]; then
    echo "no $LAYER: make -C $QUARKUTILS_DIR/linux-abi pic first" >&2
    exit 1
fi

echo "==> patching $MUSL_SRC"
( cd "$MUSL_SRC" && patch -p1 -N -r - < "$HERE/patches/musl-1.2.5-quark.patch" || true )

cd "$MUSL_SRC"
# The target's own link spec says `-static` and names the script programs
# are linked with; libc.so is a shared object, linked by ld's own script. So
# musl's build is given a link spec of its own — with the table of its
# frames an unwinder finds them by (--eh-frame-hdr), which GCC asks ld for
# in every dynamic link on Linux and the Quark target does not.
cat > quark-build.specs <<'SPECS'
*link:
%{shared:-shared --eh-frame-hdr} -z noexecstack --build-id=none
SPECS
./configure --target=x86_64-quark --prefix="$PREFIX" \
    CC="x86_64-quark-gcc -specs=$(pwd)/quark-build.specs"
# The translation layer goes into libc.so whole, ahead of libgcc: every call
# musl makes is made through it. libgcc gives the three functions complex
# multiplication needs, and is built position-independent already.
make LIBCC="-Wl,--whole-archive $LAYER -Wl,--no-whole-archive -lgcc"
# The link musl's install makes for its loader is where a system keeps it,
# and this is not a system: one in the prefix, which nothing reads. A
# distribution puts libc.so in /usr/lib and that link beside it.
make install LDSO_PATHNAME="$PREFIX/lib/ld-musl-x86_64.so.1"

# Make musl a choice the compiler knows how to make, rather than a pile of
# flags every build system would have to be told: a specs file and two
# wrappers, written by a script of its own because they name the userland's
# checkout and have to be rewritten when that moves.
sh "$HERE/musl-wrappers.sh"

echo
echo "Done. Programs build with no flags at all:"
echo "    x86_64-quark-musl-gcc hello.c -o hello"
