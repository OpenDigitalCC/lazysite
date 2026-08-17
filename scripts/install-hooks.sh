#!/bin/bash
#
# SM357: point git at the repository's committed hooks.
#
# Git does not share hooks through a clone - .git/hooks is local and untracked -
# so a rule that only lives there is a rule each checkout has to be told about
# separately, and forgets silently. core.hooksPath moves that to a directory
# under version control, which means the rule is reviewable and arrives with the
# code.
#
# Idempotent. Run it again whenever you like.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "install-hooks: not a git checkout - nothing to do" >&2
    exit 0
fi

git config core.hooksPath githooks
chmod +x githooks/* 2>/dev/null || true

printf 'hooks enabled: core.hooksPath=%s\n' "$(git config core.hooksPath)"
printf '  %s\n' githooks/*
