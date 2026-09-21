#!/bin/sh
# install.sh - a SIGNPOST, not an installer. SM892 D4.
#
# It used to be `exec perl install.pl "$@"`, which made it a second spelling of
# the same operation - and it is the spelling the documentation gave, so it is
# the one the field used. On 2026-09-15 an operator ran it on a live site and
# the summary told them "Next steps: 1. Create the first account. A fresh
# install has NO accounts", because the installer had guessed 'reinstall' and
# there was no verb for it to speak from. Nothing in the output said which of
# install and upgrade the operator had meant, because nothing had asked.
#
# The ruling (U1/U2/U3) is that install and upgrade are different commands, the
# operator chooses which, and every doc and every script names ONE way to do
# each. Deleting this file would strand the readers that name it - so it stays
# and points, which is the only job a second spelling can honestly do.
#
# It refuses everything, including --verify and --channel-check: those are
# install.pl's own probes, and a script that wants them calls install.pl. The
# only thing this file knows is where to send a person.
set -e

here=$(dirname "$0")
lazysite=lazysite
# From an unpacked tarball with no package installed, the verb still works -
# payload_root() resolves $bin/.., so the CLI in this tree finds this tree.
[ -x /usr/bin/lazysite ] || lazysite="perl $here/tools/lazysite-cli.pl"

cat >&2 <<EOF
install.sh does not install anything. Say which operation you mean:

  $lazysite provision --docroot DIR --cgibin DIR
        A site that does not exist yet. Refused if one is already there.

  $lazysite upgrade --docroot DIR
        Move an installed site to this version. Refused if nothing is
        installed, and refused if the site is already at this version.

  $lazysite reinstall --docroot DIR
        Re-lay THIS version's files over a site that already has them,
        leaving content, accounts and config alone. For a site whose
        engine files were edited or lost.

Each verb checks the site against what you said and refuses rather than
doing the other one quietly. See UPGRADE.md, or \`$lazysite help\`.
EOF
exit 2
