# The x86_64-quark cross toolchain

Scripts that turn a binutils, a gcc and a musl source tree into compilers
that target [Quark](https://github.com/MagicJester2764/quark):

```
x86_64-quark-gcc        C, against the small C library in quarkutils
x86_64-quark-musl-gcc   C, against musl — what every ported program uses
x86_64-quark-musl-g++   C++, against musl and libstdc++
```

Nothing here is a compiler. It is three patches, each the size a new
operating system target is, and the order to build things in.

It is one of the repositories that are checked out side by side, and it needs
one of the others: [quarkutils](https://github.com/MagicJester2764/quarkutils),
which has the C library the compiler's sysroot is filled from and the layer
that answers musl's system calls.

```
quarkutils/        the C library, and linux-abi
quark-toolchain/   this
```

## Building it

Sources wherever you keep them; what is built goes under `~/opt/cross` unless
`PREFIX` says otherwise. It was last built from binutils 2.45.50 and gcc
15.2.0, with musl 1.2.5.

```bash
# 1. The sysroot: headers, libc.a, crt0.o and the link script. gcc builds
#    its own support library against these, so they come first. The host
#    compiler builds them: Quark is x86-64 and so is this machine.
make -C ../quarkutils/libc install-sysroot

# 2. binutils and gcc.
./build.sh /path/to/binutils-gdb /path/to/gcc
export PATH="$HOME/opt/cross/bin:$PATH"

# 3. musl, on the layer that answers its system calls — built for programs
#    and again position-independent, for libc.so. This also writes the
#    x86_64-quark-musl-gcc and -g++ wrappers.
make -C ../quarkutils/linux-abi all pic
./build-musl.sh /path/to/musl-1.2.5

# 4. The C++ standard library, against musl.
./build-libstdcxx.sh /path/to/gcc

# 5. Linux's userspace headers, for programs that include <linux/...>.
./install-linux-headers.sh
```

The patches are applied to the source trees by the scripts, and applying
them twice does nothing.

## Why a target and not a pile of flags

Quark is x86-64 and so is every machine this has been built on, so
`-ffreestanding -nostdlib` plus Quark's own headers already produced working
binaries — that is how quarkutils' `libc` and the programs against it were
built before this existed, and how step 1 still builds them.

What a target triple buys is that the compiler knows the answers itself. A
Quark program loads above 512 GiB, is not relocated, runs with no red zone,
links against a C library called `libc.a`, starts at a `crt0.o` that builds
argv out of a page the spawner maps, and is laid out by a script that belongs
to the system rather than to any one program. Those are properties of the
platform. A build system that was not written for Quark has no way to be told
them, and `./configure` will not accept them from somebody who already knows —
it runs the compiler and believes what happens.

So the difference is not what can be built but what can be *ported*.

## What was changed

Small and in the usual places, the same shape as any other OS target:

- **binutils** — `config.sub` accepts `quark` as an operating system;
  `bfd/config.bfd`, `gas/configure.tgt` and `ld/configure.tgt` map
  `x86_64-*-quark*` onto the ordinary x86-64 ELF vectors. Nothing about the
  object format is unusual, so nothing about it is new.
- **gcc** — the same `config.sub` line, a target in `gcc/config.gcc` built like
  the bare `x86_64-*-elf*` one plus `gcc/config/quark.h`, and the target added
  to `libgcc/config.host`.
- **`gcc/config/quark.h`** (`patches/gcc-config-quark.h`) — the whole port,
  and it is short: the default code model, red zone and PIC settings;
  `crt0.o`; `-lc`; the link script by absolute path through the sysroot; and
  `__quark__`.
- **`gcc/config/quark.opt`** (`patches/gcc-config-quark.opt`, and the
  `.urls` file gcc wants beside every option file) — the options the driver
  takes that are a system's rather than the compiler's. There is one:
  `-rdynamic`. It asks for symbols to go in a table a static program has not
  got, so `LINK_SPEC` passes it to the linker and nothing comes of it — but
  a driver whose target does not declare the word refuses it, and e2fsprogs
  links with it without asking. A program built with it is byte for byte the
  program built without.
- **`--enable-initfini-array` is not optional.** Without it gcc puts every
  constructor in `.ctors`, which only `crtbegin.o` and `crtend.o` know how to
  run, and no constructor in any C program ran. musl runs `.init_array`, and
  configure only turns it on by itself for targets it recognises.
- **libgcc is built without coverage.** `libgcov` calls `fork` and `exec`,
  and when this was configured Quark had neither. It has both now; coverage
  stays off because nothing has asked for it, and turning it on is one
  `--enable-gcov` and a rebuild.

## The sysroot

`make -C ../quarkutils/libc install-sysroot` puts the headers, `libc.a`,
`crt0.o` and the link script where the toolchain looks. It has to run *before*
`build.sh`, because gcc compiles its own support library against those
headers.

Two gaps in the C library were found by exactly that, and both were real
rather than gcc being fussy: there was no `sys/types.h` and no `time.h`, and
`stdio.h` had no `FILE` — `fprintf` took a descriptor. A library that cannot
say `fprintf(stderr, ...)` is not one anybody can port to.

## musl

`build-musl.sh` builds musl against the same target.

The patch is seven files, which is the point — musl's system call interface
is that narrow. `syscall_arch.h` calls a translation layer instead of issuing
the `syscall` instruction, because Quark's numbers mean different things;
`crt_arch.h` builds the argc/argv/environment/auxv block musl expects to find
on its stack out of the page Quark's spawner maps instead; and the other five
are the assembly files that issue `syscall` themselves, each pointed at the
layer. Two of those do it as any call would. Three are places musl asks the
kernel for something Quark has not the shape of, and become a tail call:
`clone`, where Linux has the child return from the same call on a new stack;
`vfork`, where it returns through a stack it has borrowed; and the last thing
a detached thread does, which is unmap the stack it is standing on.

Every file under an `x86_64` directory with that instruction in it has to be
one of them. Two were found late — a first cut that patched five left `vfork`
and a detached thread's exit making Linux's calls, by number, at a kernel
that numbers them differently — and the way to find the next is to look, in
the library that was built:

```bash
x86_64-quark-objdump -d ~/opt/cross/x86_64-quark/musl/lib/libc.a | grep -B30 -w syscall
```

One is left on purpose: `__restore_rt`, which is where Linux returns to
after a signal handler. Nothing returns there on Quark, where a handler is
called as a function.

The layer itself is `quarkutils/linux-abi`. It is mostly an IPC client
wearing Linux's numbers: on a microkernel, `write` to a descriptor is a
message to whatever is on the other end of it, and `open` is a message to the
file server. Where there is no equivalent it returns `-ENOSYS` rather than
pretending — a libc told "no" copes, and one handed a lie fails somewhere
unrelated and much later.

`build-musl.sh` also writes a specs file and the `x86_64-quark-musl-gcc`
wrapper, so musl is a choice the compiler knows how to make rather than a
pile of flags every build system would have to be told.

The writing is `musl-wrappers.sh`, a script of its own, because the specs
name three things inside the userland's checkout by absolute path: the C
library's headers, `manifest.o` and `liblinux-abi.a`. Every musl program is
linked against whatever is at those paths *now* — which is why a change to
the layer needs no rebuild of musl, and why every static program built
before the change needs building again. When the checkout moves, the specs
have to be written again and musl does not have to be built again: run
`./musl-wrappers.sh`, with `QUARKUTILS_DIR` set if the userland is not the
sibling `../quarkutils`.

## C++

`build.sh` builds `c,c++`, which gives `x86_64-quark-g++` and `cc1plus`;
`build-libstdcxx.sh` builds the standard library afterwards, against musl.
The two are separate because gcc's in-tree libstdc++ would be built against
the sysroot's C library — the small `libc` in quarkutils, enough for libgcc
and no more — and libstdc++ wants `wchar.h`, a locale and threads.
libstdc++-v3 configures on its own, so it is built like any other library:
with the musl wrapper, for the musl prefix.

The port needed three lines, in the usual places:

- **`libstdc++-v3/crossconfig.m4`** (and the generated `configure`) list the
  hosts libstdc++ knows how to be cross-built for, and an unknown one is
  "No support for this host/target combination". `*-quark*` joins the Linux
  arm, which is the truthful one: the C library underneath is musl.
- **`libgcc/config.host`** builds `crtbegin.o` and `crtend.o` for quark. They
  are not about constructors here — `--enable-initfini-array` puts those in
  `.init_array` — but about `.eh_frame`: crtbegin contributes the empty frame
  table the unwinder is handed and the constructor that registers it, crtend
  the zero word that ends it.
- **Quark's user link script** used to discard `.eh_frame`, which was free
  while nothing unwound. The first C++ `throw` walked a table that was not
  there and took a page fault instead of finding its handler.

## Linux's headers

Quark answers Linux system calls, so a program built for it is a Linux
program, and Linux programs include `<linux/input.h>` for key codes and the
like. `install-linux-headers.sh` copies the host's kernel headers into musl's
prefix: constants and structure layouts, which are the same wherever they
are installed. A header that describes something Quark does not do gives a
program `ENOSYS` when it runs, which is the answer an old Linux would give.

## Static, unless a program asks

The compilers are configured with `--disable-shared`, and the wrappers link
a program whole unless it asks otherwise. musl is built shared as well:
`libc.so` — musl and the translation layer in one, the layer's objects
built a second time, position-independent (`liblinux-abi-pic.a`) — is the C
library of a program linked to it, and that program's dynamic loader, by
the name musl gives it (`/usr/lib/ld-musl-x86_64.so.1`, a link a
distribution makes to its `libc.so`).

```bash
x86_64-quark-musl-gcc -fPIC -shared -o libthing.so thing.c
x86_64-quark-musl-gcc -dynamic -o prog prog.c -L. -lthing
```

`-dynamic` (taken out before gcc sees it, which does not know it) and
`-shared` each read `musl-quark-dynamic.specs` after the static specs, and
that replaces the link spec whole: ld's own scripts rather than the one a
static program is linked with, the program at the same base and with an
interpreter. `-fPIC` is kept, in the small code model.

How a program starts is Linux's: a loader leaves argc, argv, the
environment and the auxiliary vector on its stack, which musl's own entry
reads — and its dynamic loader, which can call nothing until it has
relocated itself. A program built before that read its arguments from a
page the spawner maps, which every loader still maps, so it runs as it
did.
