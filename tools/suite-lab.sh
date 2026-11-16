#!/bin/bash
# tools/suite-lab.sh - run the whole suite on an HPS lab VM, or locally (SM1454 R3).
#
#   tools/suite-lab.sh STAGE_DIR JOBS OUTFILE
#
# THE CONTRACT (the gate's LAZYSITE_SUITE_RUNNER hook): run the suite of the
# staged tree STAGE_DIR, write prove's output to OUTFILE (and stdout), exit with
# prove's status. JOBS is the local parallelism; the VM runs at its own vCPUs.
#
# THE LAB PATH IS OFF UNLESS LAZYSITE_SUITE_LAB=1. It makes network calls (the
# lab operator API, ssh), and a host that keeps those on the command line, where
# they are visible, must opt in on purpose: set it in the environment of the
# person who runs the gate. Without it this prints
#   suite-lab: lab not available (LAZYSITE_SUITE_LAB is not 1) - running locally
# and runs tools/suite-local.sh, exactly the suite the gate runs without a runner.
#
# WITH IT, in order:
#   1. CHECK, bounded (about 30 s): not the lab's quiet hours (21:00-07:00 CET),
#      the IPS answers, `hps-issues` names nothing against sch-001, the host has
#      the memory, the project's ssh key exists. Any miss: the line above with
#      the reason, and the local run.
#   2. PROVISION: one VM (podman-host flavour, resized to 8 vCPU / 16 GiB - the
#      catalogue's "large" - capped at 75 % of a CPU per vCPU), define, create,
#      start, wait for its address and for cloud-init to finish.
#   3. PREPARE: the stage tree goes over as a tar stream; the Perl modules and
#      tools the suite uses are installed with apt (through the lab proxy).
#   4. RUN: `prove -lr -jN t/` on the VM, its output streamed into OUTFILE.
#   5. DESTROY the VM, always (an EXIT trap). A destroy that fails is said loudly.
# A failure in 1-3 is "tests never started": the reason is printed and the suite
# runs locally. A failure in 4 is a FAILURE, never a fallback, and a run that
# exits 0 without prove's "Result: PASS" line is a failure too: a pass that did
# not happen is never reported.
#
# Test seams: LAZYSITE_LAB_OP, LAZYSITE_LAB_FLAVOUR, LAZYSITE_LAB_SSH,
# LAZYSITE_LAB_KEY, LAZYSITE_LAB_HOUR (the CET hour), LAZYSITE_LAB_POLL (seconds
# between polls), LAZYSITE_LAB_WAIT (seconds to wait for the VM),
# LAZYSITE_SUITE_LOCAL (the local runner).
# shellcheck disable=SC2317,SC2016  # helpers are called through `step`; the bash -c text expands in the child
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAB_OP=${LAZYSITE_LAB_OP:-/srv/projects/hps/scripts/lab-op}
FLAVOUR=${LAZYSITE_LAB_FLAVOUR:-/home/claude/.claude/skills/hps-workloads/bin/hps-flavour}
SSH=${LAZYSITE_LAB_SSH:-ssh}
KEY=${LAZYSITE_LAB_KEY:-$HOME/.ssh/hps-lazysite}
LOCAL=${LAZYSITE_SUITE_LOCAL:-$HERE/suite-local.sh}
POLL=${LAZYSITE_LAB_POLL:-5}
WAIT=${LAZYSITE_LAB_WAIT:-600}
PROXY=http://10.100.1.2:3128
PROJECT=lazysite
VM_VCPUS=8
VM_MEM=16384
VM_ROOT=40G
NEED_FREE_MIB=$((VM_MEM + 4096))
LAB_USER=debian

if [ $# -ne 3 ]; then
    echo "usage: tools/suite-lab.sh STAGE_DIR JOBS OUTFILE" >&2
    exit 2
fi
STAGE=$1
JOBS=$2
OUT=$3
case "$OUT" in /*) ;; *) OUT=$PWD/$OUT ;; esac

NAME=""
ADDR=""
WORK=/tmp/suite-lab-$$
mkdir -p "$WORK"

cleanup() {
    local rc=0
    if [ -n "$NAME" ]; then
        if timeout 120 "$LAB_OP" hps-workload destroy "$NAME" --forget > "$WORK/destroy.txt" 2>&1; then
            echo "suite-lab: destroyed VM $NAME"
        else
            rc=1
            echo "suite-lab: *** VM $NAME WAS NOT DESTROYED - destroy it by hand:" >&2
            echo "suite-lab:     $LAB_OP hps-workload destroy $NAME --forget" >&2
            sed 's/^/suite-lab:     /' "$WORK/destroy.txt" >&2 || true
        fi
        NAME=""
    fi
    rm -rf "$WORK"
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Tests never started: say why, tear down what was made, run locally.
fallback() {
    echo "suite-lab: lab not available ($1) - running locally"
    cleanup || true
    trap - EXIT
    exec bash "$LOCAL" "$STAGE" "$JOBS" "$OUT"
}

ssh_vm() {
    "$SSH" -i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -o ConnectTimeout=10 -o ServerAliveInterval=30 "$LAB_USER@$ADDR" "$@"
}

# --- 1. the check ------------------------------------------------------------
check_lab() {
    [ "${LAZYSITE_SUITE_LAB:-}" = 1 ] || { echo "LAZYSITE_SUITE_LAB is not 1"; return 1; }
    local hour
    hour=${LAZYSITE_LAB_HOUR:-$(TZ=Europe/Berlin date +%H)}
    if [ $((10#$hour)) -ge 21 ] || [ $((10#$hour)) -lt 7 ]; then
        echo "HPS quiet hours, 21:00-07:00 CET"
        return 1
    fi
    [ -r "$KEY" ] || { echo "no ssh key $KEY"; return 1; }
    [ -x "$LAB_OP" ] || { echo "no $LAB_OP"; return 1; }
    if ! timeout 20 "$LAB_OP" hps-issues list > "$WORK/issues.txt" 2>&1; then
        echo "the lab IPS does not answer"
        return 1
    fi
    if grep -Eq 'sch-001|pool lab' "$WORK/issues.txt"; then
        echo "an open issue names sch-001 or the lab pool"
        return 1
    fi
    # The wrapper may exit 141 after printing; the figures stand.
    timeout 30 "$LAB_OP" hps-node resources sch-001 > "$WORK/resources.txt" 2>&1 || true
    local free
    free=$(sed -n 's/.*free_mem_mib=\([0-9][0-9]*\).*/\1/p' "$WORK/resources.txt" | head -1)
    if [ -z "$free" ]; then
        echo "the host's free memory could not be read"
        return 1
    fi
    if [ "$free" -lt "$NEED_FREE_MIB" ]; then
        echo "free guest memory ${free} MiB, need $NEED_FREE_MIB"
        return 1
    fi
    return 0
}

REASON=""
if ! REASON=$(check_lab); then
    fallback "$REASON"
fi

# --- 2. provision ------------------------------------------------------------
# One step that can fail before tests start: it names itself so the reason says
# which. Any non-zero exit here is a fallback, with the VM torn down.
step() {
    local what=$1
    shift
    "$@" > "$WORK/step.txt" 2>&1 || fallback "$what failed: $(tail -n 1 "$WORK/step.txt")"
}

console_has() {
    timeout 30 "$LAB_OP" hps-workload console "$NAME" --lines 200 > "$WORK/console.txt" 2>&1 || true
    grep -aq "$1" "$WORK/console.txt"
}

wait_for() {
    local what=$1 pattern=$2 waited=0
    while ! console_has "$pattern"; do
        waited=$((waited + POLL))
        [ "$waited" -le "$WAIT" ] || fallback "$what: no '$pattern' on the console after ${WAIT}s"
        sleep "$POLL"
    done
}

# The flavour's definition, with the 75 % CPU cap the house rule asks of a
# CPU-heavy VM (the catalogue's video-edit does the same).
add_cpu_cap() {
    perl -MJSON::PP -e '
        my ($f) = @ARGV;
        open my $in, "<", $f or die "$f: $!\n";
        my $d = decode_json(do { local $/; <$in> });
        close $in;
        $_->{cpu_max_pct} = 75 for @{ $d->{vms} };
        open my $o, ">", $f or die "$f: $!\n";
        print {$o} JSON::PP->new->canonical->pretty->encode($d);
        close $o or die "$f: $!\n";
    ' "$1"
}

DATE=$(date +%Y%m%d)
WANT=$PROJECT-suite-$DATE
step "render the VM definition" "$FLAVOUR" render podman-host --project "$PROJECT" --name "$WANT" \
    --key "$KEY.pub" --proxy "$PROXY" --memory "$VM_MEM" --vcpus "$VM_VCPUS" --root "$VM_ROOT" --out "$WORK"
step "add the CPU cap" add_cpu_cap "$WORK/$WANT.json"
step "define $WANT" bash -c '"$0" --input hps-workload-define "$1" < "$2"' "$LAB_OP" "$WANT" "$WORK/$WANT.json"
NAME=$WANT
# The first create on a host can stop at image-fetch; --resume is the documented answer.
if ! "$LAB_OP" hps-workload create "$NAME" > "$WORK/step.txt" 2>&1; then
    step "create $NAME" "$LAB_OP" hps-workload create "$NAME" --resume
fi
step "start $NAME" "$LAB_OP" hps-workload start "$NAME"
echo "suite-lab: VM $NAME started ($VM_VCPUS vCPU, $((VM_MEM / 1024)) GiB)"

wait_for "the VM's address" 'HPS-READY'
ADDR=$(sed -n 's/.*HPS-READY .*addr=[^ =]*=\([0-9][0-9.]*\)\/.*/\1/p' "$WORK/console.txt" | tail -1)
[ -n "$ADDR" ] || fallback "the console gave no address"
wait_for "first boot" 'HPS-CLOUD-INIT done'
echo "suite-lab: VM $NAME is at $ADDR"

# --- 3. prepare --------------------------------------------------------------
# sshd may lag the console line by a moment.
ssh_ready() {
    local waited=0
    while ! ssh_vm true > /dev/null 2>&1; do
        waited=$((waited + POLL))
        [ "$waited" -le "$WAIT" ] || return 1
        sleep "$POLL"
    done
}
step "ssh to $ADDR" ssh_ready

# What the suite uses beyond core Perl: the CPAN modules the tests load, the two
# web servers two harnesses drive (policy-rc.d keeps them from starting: nothing
# on the VM answers HTTP on the lab segment), git and the lint tools.
deps_script() {
    cat << 'DEPS'
set -eu
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -q -y install perl git curl openssl sqlite3 nginx-light apache2 perltidy shellcheck nodejs \
    libarchive-zip-perl libcryptx-perl libdatetime-perl libdatetime-timezone-perl libdbi-perl \
    libdbd-sqlite3-perl libfcgi-perl libhttp-daemon-perl libwww-perl libio-socket-ssl-perl \
    libnet-ssleay-perl libnet-dns-perl libtext-csv-xs-perl libtext-multimarkdown-perl liburi-perl \
    libxml-libxml-perl libyaml-pp-perl libtemplate-perl libjson-xs-perl \
    libdevel-cover-perl libperl-critic-perl libppi-perl
DEPS
}
install_deps() { deps_script | ssh_vm 'sudo bash -s'; }
send_tree() {
    tar -C "$STAGE" -cf - . | ssh_vm 'rm -rf suite && mkdir suite && tar -C suite -xf -'
}
step "install the suite's dependencies" install_deps
step "copy the stage tree" send_tree

# --- 4. run ------------------------------------------------------------------
# From here the tests have started: nothing falls back.
echo "suite-lab: running prove -lr -j$VM_VCPUS on $NAME"
RC=0
set +e
ssh_vm "cd suite && LC_ALL=C.UTF-8 prove -lr -j$VM_VCPUS t/" < /dev/null 2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -eq 0 ] && ! grep -q '^Result: PASS' "$OUT"; then
    echo "suite-lab: the VM run exited 0 without a 'Result: PASS' line - a failure, not a pass" >&2
    RC=1
fi
if [ "$RC" -ne 0 ]; then
    echo "suite-lab: the run on $NAME FAILED (exit $RC) after the tests started - no local fallback" >&2
fi
CLEAN=0
cleanup || CLEAN=$?
trap - EXIT
[ "$CLEAN" -eq 0 ] || echo "suite-lab: the VM was not destroyed (see above); the suite result is exit $RC" >&2
exit "$RC"
