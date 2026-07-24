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
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die "open: $!";
    local $/;
    <$fh>;
};

# --- parse the dispatch action set and the three gate maps from source --------
my %all = map { $_ => 1 } ( $src =~ /\$action eq '([a-z0-9-]+)'/g );

my ($cc_block) = $src =~ /my %COOKIE_CAP = \((.*?)\n    \);/s;
ok( $cc_block, 'found the %COOKIE_CAP map' );
my %cookie_caps;    # action => { cap => 1, ... }  (OR-set: any listed cap passes)
while ( $cc_block =~ /'([a-z0-9-]+)'\s*=>\s*'([a-z0-9_|]+)'/g ) {
    $cookie_caps{$1} = { map { $_ => 1 } split /\|/, $2 };
}

my ($need_block) = $src =~ /my %need = \((.*?)\n    \);/s;
ok( $need_block, 'found the token %need map' );
# Each entry is a single line: 'action' => sub { ... $_[0]->{cap} ... },
# The sub bodies contain nested { } (the cap hash lookups), so parse per line -
# capture the action, then every cap referenced on that same line.
my %need_caps;    # action => { cap => 1, ... }  (empty = any authenticated)
for my $line ( split /\n/, $need_block ) {
    next unless $line =~ /'([a-z0-9-]+)'\s*=>\s*sub \{/;
    my $act  = $1;
    my %caps = map { $_ => 1 } ( $line =~ /\$_\[0\]->\{(\w+)\}/g );
    $need_caps{$act} = \%caps;
}

my ($mut_block) = $src =~ /my %MUTATING = map \{ \$_ => 1 \} qw\((.*?)\)/s;
my %mutating = map { $_ => 1 } split ' ', ( $mut_block // '' );

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

# --- 3. cross-channel capability parity ---------------------------------------
# For an action gated on BOTH channels, the OR-set of accepted capabilities must
# be identical - otherwise one channel is a weaker door than the other. Any
# deliberate exception must be enrolled here with its rationale.
my %ALLOW_DIVERGENCE;    # action => 1  (none today)
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
my %COOKIE_READ = map { $_ => 1 } qw(
    domains-list domain-preview domain-check config-read bad-url-blocks
    backup-list backup-download lang-status git-status git-history git-history-summary git-show
    analyse_visitors plugin-read form-submissions site-backup-inspect
    site-backup-download
    principals
);
# 'users' is dual-mode (GET reads list/groups; writes self-enforce POST inside
# action_users), so it is deliberately NOT in %MUTATING - enrolled as a reviewed
# exception rather than a read.
$COOKIE_READ{users} = 1;
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
