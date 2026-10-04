#!/bin/sh
# Teach an autoconf config.sub that quark is an operating system.
#
#     ./teach-config-sub.sh path/to/config.sub
#
# binutils and gcc learn it from their patches. What else is built here —
# GMP, MPFR and MPC, which gcc needs in order to run — is built from its
# release tarball, and each carries its own copy of the script, which does
# not know the word. This adds it to the list of operating systems, in the
# unpacked copy and nowhere else. Running it twice does nothing.
#
# The script is regenerated every few years and the list is laid out
# differently in each vintage: one name to a line, several to a line
# continued with a backslash, the last line closed with `)`. So the list is
# found by what is in it — `zephyr*`, which every vintage names in it and
# names nowhere else after a `|` — and added to in the shape it has.
set -e
F=${1:?usage: teach-config-sub.sh <config.sub>}
grep -q 'quark\*' "$F" && exit 0
python3 - "$F" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path).read().split("\n")
hits = [i for i, l in enumerate(lines) if re.match(r"^\s*\|.*\bzephyr\*", l)]
if len(hits) != 1:
    sys.exit(path + ": no list of operating systems where one was expected")
i = hits[0]
line = lines[i]
indent = re.match(r"^(\s*)", line).group(1)
if line.rstrip().endswith("\\"):
    lines.insert(i + 1, indent + "| quark* \\")
elif line.rstrip().endswith(")"):
    lines[i] = line.rstrip()[:-1].rstrip() + " \\"
    lines.insert(i + 1, indent + "| quark*)")
else:
    sys.exit(path + ": the list ends in a way this does not recognise")
open(path, "w").write("\n".join(lines))
PY
echo "==> $F knows quark"
