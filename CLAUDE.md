# Working on the Quark cross toolchain

This repository builds the compilers that target Quark: `x86_64-quark-gcc`
and, on top of musl, `x86_64-quark-musl-gcc` and `-g++`. It is scripts and
patches; the sources they are applied to are somebody else's and are not
here.

It is checked out beside the repositories it serves, and it reaches into one
of them:

```
repos/
  quarkutils/        the C library, and linux-abi, which answers musl
  quark-toolchain/   this repo
```

`musl-wrappers.sh` finds the userland at `../quarkutils` (or
`QUARKUTILS_DIR`) and writes its absolute path into the specs file. Nothing
else here names another repository, and nothing names a distribution: what
is built with these compilers is not this repository's business.

## The order

`README.md` has the commands. The order is forced:

1. quarkutils' `libc` into the sysroot — gcc compiles `libgcc` against its
   headers.
2. `build.sh`: binutils, then gcc with no C++ library.
3. quarkutils' `linux-abi`, then `build-musl.sh`: musl, and the wrappers.
4. `build-libstdcxx.sh`: needs the `-musl-g++` wrapper that step 3 wrote.
5. `install-linux-headers.sh`.

## Rules

- **A patch is the size of a target.** The three patches teach binutils, gcc
  and musl that Quark exists and what calling its kernel looks like. Anything
  more than that belongs in quarkutils — in the C library or in `linux-abi` —
  where it is code rather than a patch against somebody's release.
- **Patches apply twice without harm.** Each script runs `patch -N` on the
  tree it is given, so a second run is a rebuild. Keep it that way: a script
  that fails on an already-patched tree is one nobody can re-run.
- **A new musl or gcc release means a new patch file**, named for the
  version, and the scripts' default changed. The old one stays until nothing
  is built with it.
- **Static only.** `--disable-shared` everywhere. A dynamic loader is a
  project of its own, in quarkutils and the kernel first.
- **The specs hold absolute paths** into the userland checkout. If it moves,
  `./musl-wrappers.sh` again; nothing needs recompiling. After a gcc upgrade
  run it too: the C++ wrapper names the compiler's version.
- **What changes here changes every program.** Everything is linked
  statically against what these scripts install, so a change is verified by
  rebuilding the userland's C programs and a distribution's packages and
  booting them — not by the compiler building.

## Verifying

The compilers are tested by what is built with them:

```bash
x86_64-quark-musl-gcc -o hello hello.c      # links, with no flags at all
make -C ../quarkutils                       # the userland's C programs
sh ../quarkutils/tools/build-ctests.sh out  # the C library's own tests
```

and those tests run on a booted system, which is a distribution's to
assemble.
