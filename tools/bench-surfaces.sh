#!/bin/bash
# tools/bench-surfaces.sh - the per-surface, per-phase benchmark (SM1144, SM1082 T0),
# constrained so it cannot add load to a shared host.
#
# It pins itself to ONE CPU at the lowest priority (taskset -c N nice -n 19, and
# ionice class 3 where there is an ionice) and then runs tools/bench-surfaces.pl,
# which sends its requests one at a time and starts no parallel work. A host that
# cannot pin (no taskset) is refused rather than measured loose: a figure taken
# while competing with Odoo is the host's, not the engine's.
#
#   tools/bench-surfaces.sh [--n N] [--surface a,b] [--with-pool] [--json]
#                           [--docroot D [--socket S]]
#
# N defaults to 3, so the dry run is quick enough to be a test. Quote a figure
# from --n 20 or more.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if [ -z "${BENCH_SURFACES_CONSTRAINED:-}" ]; then
    if ! command -v taskset >/dev/null 2>&1; then
        echo "bench-surfaces: taskset is not installed, so this cannot pin itself to one CPU; refusing to run unconstrained" >&2
        exit 2
    fi
    # The first CPU this process may use: CPU 0 when it is allowed, else the first
    # of the allowed list (a container may be confined to others).
    allowed=$(taskset -cp $$ | sed 's/.*: //')
    cpu=${allowed%%[,-]*}
    export BENCH_SURFACES_CONSTRAINED="cpu$cpu"
    if command -v ionice >/dev/null 2>&1; then
        exec taskset -c "$cpu" nice -n 19 ionice -c3 "$0" "$@"
    fi
    exec taskset -c "$cpu" nice -n 19 "$0" "$@"
fi

exec perl "$here/bench-surfaces.pl" "$@"
