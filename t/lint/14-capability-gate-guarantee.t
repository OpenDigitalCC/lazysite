#!/usr/bin/perl
# SECURITY GUARANTEE (adversarial breadth, 2026-07): the manager/control API
# authorizes on two channels with two maps - the cookie (manager UI) channel via
# %COOKIE_CAP, and the token (API/MCP partner) channel via %need, which is
# DEFAULT-DENY (an action absent from %need is unreachable by a token). The
# failure mode this test exists to prevent is an action shipping through the
# dispatch with NO gate on it, or the two channels drifting so one is more
# permissive than the other for the same action (a privilege bypass). It is the
# structural analogue of t/lint/13-trust-gate-guarantee.t.
#
# The test scans lazysite-manager-api.pl and asserts, mechanically:
#   1. the token channel is default-deny (the %need lookup + refusal survive);
#   2. every dispatched action is CLASSIFIED - it is capability-gated
#      (%COOKIE_CAP or %need), CSRF-gated (%MUTATING), or explicitly listed here
#      in the reviewed read / bespoke / pre-auth allowlists. A new action that no
#      one classified fails the build with its name;
#   3. for an action gated on BOTH channels, the required capability SETS match -
#      neither channel is a weaker door than the other.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root gate_caps);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die "open: $!";
    local $/;
    <$fh>;
};

# --- parse the dispatch action set and the three gate maps from source --------
my %all = map { $_ => 1 } ( $src =~ /\$action eq '([a-z0-9-]+)'/g );

# SM943: the CGI's tables are DERIVED from Lazysite::ControlApi::Actions, so the
# data is read from there. That the CGI builds each of them from it, and keeps
# no copy, is asserted once for all ten tables in
# t/unit/lib/200-every-action-table-derives-from-one-declaration.t (subtest 1);
# the four lines that repeated it here for this lint's tables went in stage 3.
my %cc_decl = Lazysite::ControlApi::Actions::cookie_caps();
ok( %cc_decl, 'found the %COOKIE_CAP map' );
my %cookie_caps;    # action => { cap => 1, ... }  (OR-set: any listed cap passes)
for my $act ( keys %cc_decl ) {    # SM958: `a+b` values stay whole, as before
    $cookie_caps{$act} = { map { $_ => 1 } split /\|/, $cc_decl{$act} };
}

# SM662: the gate DECLARES its capabilities, so this reads data rather than
# picking capability names out of a sub body with a regex. TestHelper::gate_caps
# is the one place that extraction lives.
my %need_caps = gate_caps($src);
ok( scalar keys %need_caps, 'found the token gate table' );

my %mutating = Lazysite::ControlApi::Actions::mutating();

# --- 1. the token channel is DEFAULT-DENY -------------------------------------
ok( $src =~ /my \$check = \$need\{\$action\};/,
    'token channel resolves authorization from the %need map' );
ok( $src =~ /my \$check = \$need\{\$action\};\s*\n\s*unless\s*\(\s*\$check\s*\)/,
    'token channel is default-deny (an action absent from %need is refused)' );

# --- non-vacuity: the parse actually found the surface ------------------------
cmp_ok( scalar keys %all,         '>=', 90, 'dispatch exposes the full action set' );
cmp_ok( scalar keys %cookie_caps, '>=', 30, '%COOKIE_CAP parsed non-trivially' );
cmp_ok( scalar keys %need_caps,   '>=', 30, '%need parsed non-trivially' );
cmp_ok( scalar keys %mutating,    '>=', 30, '%MUTATING parsed non-trivially' );

# --- 2. every dispatched action is CLASSIFIED ---------------------------------
# Reviewed allowlists. READ = a read/introspection action any authenticated
# manager may call (must NOT mutate state). BESPOKE = a user/session/key/notice
# action with its own actor-confined gate in the dispatch body. PREAUTH = issued
# before/around the auth boundary. Adding a NEW action means consciously placing
# it in a cap map or one of these buckets - which is the whole point.
my %READ = map { $_ => 1 } qw(
    list read cache-list recent-changes channel-services principals version preview
    start-page
    connector-list connector-calls
    file-download file-zip-download handler-list form-targets-read plugin-list
    layouts-releases layouts-release-contents layouts-repo-get
);
my %BESPOKE = map { $_ => 1 } qw(
    users audit notices keys-list key-revoke sessions-list session-revoke
    user-revoke
);
my %PREAUTH = map { $_ => 1 } qw( csrf-token );

my @unclassified;
for my $act ( sort keys %all ) {
    next
        if $cookie_caps{$act}
        || $need_caps{$act}
        || $mutating{$act}
        || $READ{$act}
        || $BESPOKE{$act}
        || $PREAUTH{$act};
    push @unclassified, $act;
}
is( "@unclassified", '',
    'every dispatched action is capability-gated, CSRF-gated, or on a reviewed read/bespoke/pre-auth allowlist' )
    or diag "UNCLASSIFIED (add to a cap map or a reviewed allowlist): @unclassified";

# A read-allowlisted action must not secretly mutate state (no CSRF gate = it
# had better be a genuine read).
my @read_but_mutating = sort grep { $mutating{$_} } keys %READ;
is( "@read_but_mutating", '',
    'no read-allowlisted action is also in %MUTATING (reads do not change state)' );

# --- 2b. every path-bearing read/write verb is under the SM268 H4 gate --------
# SM517: %file_surface keys the carve-out gate (nav.conf needs manage_nav, the
# submission store needs read_submissions). It listed read, list, preview and
# git-show but neither download verb, so a manage_content-only account was
# refused `read` of the store and then downloaded it - the same defect SM418
# closed for file-upload. %SCOPED_ACTION is the reviewed set of verbs that take
# a content path; every one of them must be in %file_surface, except the two
# that carry no path at all.
my %fs_decl = Lazysite::ControlApi::Actions::file_surface();
ok( %fs_decl, 'found the %file_surface carve-out map' );
my %file_surface = map { $_ => 1 } grep { $fs_decl{$_} =~ /\A(?:read|write)\z/ } keys %fs_decl;
my %scoped       = Lazysite::ControlApi::Actions::scoped_actions();
cmp_ok( scalar keys %scoped, '>=', 20, '%SCOPED_ACTION parsed non-trivially' );
my %NO_PATH = map       { $_ => 1 } qw( git-status cache-invalidate );
my @ungated = sort grep { !$file_surface{$_} && !$NO_PATH{$_} } keys %scoped;
is( "@ungated", '',
    'every path-bearing action in %SCOPED_ACTION is keyed in %file_surface (SM268 H4 carve-out gate)' )
    or diag "OUTSIDE THE CARVE-OUT GATE: @ungated";

# --- 3. cross-channel capability parity ---------------------------------------
# For an action gated on BOTH channels, the OR-set of accepted capabilities must
# be identical - otherwise one channel is a weaker door than the other. Any
# deliberate exception must be enrolled here with its rationale.
# SM958: these two were never compared - the parser above dropped every `a+b`
# value until SM958 - and they differ ON PURPOSE. A manager deletes a submission
# with manage_forms AND read_submissions (SM660: you may not destroy what you may
# not see); a token uses delete_submissions, a dedicated, off-by-default grant for
# the API alone (Capabilities.pm). Two models, both deliberate, so listed here
# with the reason rather than reported.
my %ALLOW_DIVERGENCE = (
    'form-submission-delete'       => 'manager: manage_forms+read_submissions (SM660); token: delete_submissions',
    'form-submissions-delete-bulk' => 'the same split as form-submission-delete',
);
my @divergent;
for my $act ( sort keys %all ) {
    next unless $cookie_caps{$act} && $need_caps{$act};
    next if $ALLOW_DIVERGENCE{$act};
    my $ck = join ',', sort keys %{ $cookie_caps{$act} };
    my $nd = join ',', sort keys %{ $need_caps{$act} };
    push @divergent, "$act (cookie=[$ck] token=[$nd])" if $ck ne $nd;
}
is( "@divergent", '',
    'actions gated on both channels require the same capability set (no weaker door)' )
    or diag "CHANNEL DIVERGENCE: @divergent";

# --- 3b. every capability-gated cookie MUTATOR is also POST-forced -------------
# A cookie action in %COOKIE_CAP that changes state must also be in %MUTATING, or
# it is reachable via a CSRF-free GET (the method-keyed CSRF gate only covers
# POST). Reads are exempt via an explicit reviewed allowlist. This catches the
# 0.8.1 site-backup-* gap class: capability-gated, state-changing, but not
# POST-forced.
# SM943 follow-up: a heredoc, comments stripped. As a qw() list the comment
# lines below were split into words and every word became an entry - a comment
# naming an action would have exempted it.
my %COOKIE_READ = map { $_ => 1 } map { ( my $l = $_ ) =~ s/#.*//; split ' ', $l } split /\n/, <<'COOKIE_READ';
    connector-list connector-calls remap-list
    domains-list domain-preview domain-check config-read bad-url-blocks
    backup-list backup-download lang-status git-status git-history git-history-summary git-show
    analyse_visitors plugin-read form-submissions form-submission form-list site-backup-inspect
    site-backup-download
    principals protected-sections

    # SM447: the three data READS. Each takes a table name and returns what is
    # declared or stored; none changes anything, so a CSRF-free GET of one
    # discloses to a session that already holds manage_data and could ask
    # anyway. The three data WRITERS - data-migrate, data-row-save,
    # data-row-delete - are in %MUTATING and POST-forced.
    data-tables data-table data-rows data-safety-exports data-safety-export-read

    # SM245: the brief store's read. Takes a path, returns the recorded
    # "why", changes nothing; the writers (brief-append, briefs-migrate) are
    # in %MUTATING and POST-forced.
    brief-read briefs-list

    # DM-2: the download is a READ, and a big one. It returns every row rather
    # than a capped page, which is worth saying out loud - but the caller
    # already holds manage_data and could page through data-rows to the same
    # end, so a CSRF-free GET discloses nothing a session could not already
    # ask for. It is a GET because a browser download is a navigation.
    data-export

    # DM-5: two more reads. The descriptor's source text, and a migration
    # PLAN that applies nothing - a preview for a person deciding.
    data-table-source data-migrate-plan

    # SM687: reading the rule that says who may read a table. A read, like
    # acl-get which it mirrors; its two writers are in %MUTATING.
    data-table-acl-get

    # SM842: the handler contract's three reads - the handlers, one form's
    # binding, the schedule. Gated now that the Handlers page opens for any of
    # three capabilities; their writers are in %MUTATING.
    handler-list form-targets-read schedule-list
COOKIE_READ
# 'users' is dual-mode (GET reads list/groups; writes self-enforce POST inside
# action_users), so it is deliberately NOT in %MUTATING - enrolled as a reviewed
# exception rather than a read.
$COOKIE_READ{users} = 1;
# SM475: THE POST REQUIREMENT MUST NOT LIVE INSIDE THE COOKIE BRANCH.
#
# It did, so it never applied to a token client - and the field proved the
# consequence: an authenticated GET of data-migrate returned 200 and RAN, a
# no-op only because the schema happened to be current. CSRF is the cookie
# path's reason and not the only one; a state-changing action reachable by GET
# is prefetchable, retried by intermediaries that believe GET is safe, and
# lands in logs and history as a URL somebody can paste.
{
    my ($before) = $src =~ /\A(.*?)\nif \( !\$token_auth \) \{/s;
    ok( defined $before && $before =~ /\$MUTATING\{\$action\} && \$method ne 'POST'/,
        'the POST requirement applies before the cookie/token split' )
        or diag( 'Inside the cookie branch it is a rule for one channel, and '
            . 'the other one changes state on a GET.' );
}

my @cookie_mut_gap = sort grep { !$COOKIE_READ{$_} && !$mutating{$_} } keys %cookie_caps;
is( "@cookie_mut_gap", '',
    'every capability-gated cookie action that is not a reviewed read is POST-forced (in %MUTATING)' )
    or diag "COOKIE MUTATORS MISSING FROM %MUTATING (CSRF-free GET risk): @cookie_mut_gap";

# --- 4. known escalation-sensitive actions really are gated -------------------
for my $act ( qw(domain-add domain-set domain-remove config-set rotate-auth-secret
    backup-restore theme-activate layout-activate) ) {
    ok( $cookie_caps{$act}, "sensitive action '$act' carries a cookie capability gate" );
    ok( $mutating{$act},    "sensitive action '$act' requires CSRF (is in %MUTATING)" );
}
ok( $cookie_caps{'users'}, "account management ('users') carries a capability gate" );

done_testing;
