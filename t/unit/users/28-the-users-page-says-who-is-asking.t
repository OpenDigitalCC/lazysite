#!/usr/bin/perl
# SM346: the Users page gated operator-only controls on an identity it was never given.
#
# REPORTED as "a human sub-user of a manager has no 'promote to top level' menu
# option, whereas AI agents do". The reported shape is narrower than the defect.
#
# The page decides whether to offer its operator-only controls with `amOperator`,
# which it computes by looking for ITSELF in the groups that grant manage_users:
#
#     if (ME && info.caps && info.caps.manage_users && members.indexOf(ME) !== -1)
#
# `ME` comes from `d.partner || d.me` on the `users-page` response - and that
# response carried NEITHER. The call is a consolidation of three earlier ones
# (users-detail + group-settings-get + whoami, per its own comment) which brought
# forward the data of the first two and the identity of the third not at all.
#
# So `ME` stayed empty, `amOperator` was false for EVERY human including a full
# operator, and the controls it gates - promote-to-top-level and the
# scope-independence toggle - were invisible to all of them. An agent driving the
# control API or MCP is not subject to a UI gate at all, which is why the same
# operation appeared to work for agents and not for people.
#
# The API always enforced this correctly; the page's own comment says so ("the
# API enforces it regardless"). Nothing was ever wrongly PERMITTED. A capability
# was wrongly WITHHELD, and silently - there is no error to read when a control
# is simply absent, which is why it presented as a difference between humans and
# agents rather than as a bug.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

subtest 'the payload carries the caller identity' => sub {
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($handler) = $src =~ /elsif \( \$action eq 'users-page' \) \{(.*?)\n        \}/s;
    ok( $handler, 'the users-page handler was found' ) or return;

    like( $handler, qr/me\s*=>/,
        'users-page reports who is asking' )
        or diag( 'Without it the page cannot tell whether the caller is an '
            . 'operator, and hides every operator-only control from everyone.' );

    # NOT `actor`. That key carries authorisation meaning in this tool - the
    # ACTOR_FORBIDDEN backstop refuses privileged verbs when it names a
    # non-operator - so reusing it for "who is asking" would attach an
    # authorisation signal to a read-only call.
    unlike( $handler, qr/me\s*=>\s*\$req->\{actor\}/,
        'and does it with an inert key, not the authorisation-bearing one' );
};

subtest 'the API supplies it, and only for this read' => sub {
    my $src = do {
        open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/\$act eq 'users-page'.*?\$parsed->\{me\} = \$auth_user/s,
        'the API puts the authenticated caller on the users-page request' )
        or diag( 'The tool cannot invent the identity - only the CGI knows who '
            . 'authenticated.' );

    # The identity must not become a second way to assert an actor on the verbs
    # where `actor` is load-bearing.
    my ($block) = $src =~ /(if \( \$auth_user ne 'local' && \$act eq 'users-page' \).*?\n            \})/s;
    ok( $block, 'the injection block was isolated' ) or return;
    unlike( $block, qr/\{actor\}/,
        'and it sets no actor, so no authorisation path changes' );
};

subtest 'ACTOR_FORBIDDEN still governs the verbs it was written for' => sub {
    # The half that must not regress. SM346 adds an identity to a read; it must
    # not weaken the backstop that refuses privileged verbs driven with a
    # non-operator actor.
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($forbidden) = $src =~ /%ACTOR_FORBIDDEN = map \{ \$_ => 1 \} qw\((.*?)\)/s;
    ok( $forbidden, 'the backstop is present' ) or return;
    for my $verb (qw(add remove group-add group-settings-set token)) {
        like( $forbidden, qr/\b\Q$verb\E\b/, "$verb is still confined" );
    }
    unlike( $forbidden, qr/\busers-page\b/,
        'and the new read was not added to it - it is a read, not a verb' );
};

subtest 'the page reads the field the payload now provides' => sub {
    # Both halves of one fact, in two files that cannot see each other. This is
    # the join that was missing, so it is the join worth asserting.
    my $page = do {
        open my $fh, '<', "$root/starter/manager/users.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $page, qr/ME = d\.partner \|\| d\.me/,
        'the page reads partner-or-me from the payload' );
    like( $page, qr/amOperator && !s\.top_level/,
        'and the promote control is gated on being an operator' )
        or diag( 'If this gate moved, the test above is guarding a field '
            . 'nothing consumes.' );
};

done_testing();
