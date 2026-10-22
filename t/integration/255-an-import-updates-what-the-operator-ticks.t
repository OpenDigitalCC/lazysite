#!/usr/bin/perl
# SM1053 (n572), the third of what the core left unbuilt: a row for an account
# that already exists was skipped. Now the dry run shows what it would change -
# the address, the groups to join and the groups to leave - and the apply makes
# ONLY the changes the operator ticks. Never a password. Groups are those that
# exist and never an operator group or a registration group, in either
# direction. An operator's own account is not changed by an import.
#
# Leaving a group does NOT end the account's sessions: groups are read fresh on
# every request (SEC-2026-07 M5), so the account loses the group's doors at
# once and keeps its own - SM1070's probe, held through the real cookie doors
# by t/integration/243 ("groups removed keep the member's doors and lose the
# group's"). SM1040's rule, a changed credential signs the other sessions out,
# is about credentials; an import changes none.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL = qw(ui api manage_users manage_content manage_nav);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d   = $s->docroot;
$s->add_user( 'op', 'pw-op-0123456789' );
$s->grant( 'op', 'g-op', [qw(ui manage_users manage_content)], \@ALL );
$s->users( 'group-set', 'g-op', 'manager', 'on' );    # SM991: the operator group
for my $u (qw(u1 u2 u3)) { $s->add_user( $u, "pw-$u-0123456789" ) }
$s->grant( 'u1', 'editors', [qw(ui manage_content)], \@ALL );
$s->grant( 'u2', 'authors', [qw(ui manage_nav)],     \@ALL );
$s->users( 'group-add', 'u3', 'authors' );
$s->users( 'group-create', 'reg' );
$s->users( 'group-set', 'reg', 'registration', 'on' );
$s->users( 'set', 'u1', 'email', 'old1@example.org' );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
sub api {
    my ( $who, $action, $body, $query ) = @_;
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ),
        query => $query // "action=$action" );
}
sub email_of { return uapi( { action => 'settings-get', username => $_[0] } )->{settings}{email} // '' }
sub in_group {
    my ( $u, $g ) = @_;
    return scalar grep { $_ eq $u } @{ ( uapi( { action => 'groups' } )->{groups} || {} )->{$g} || [] };
}
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; return scalar <$fh> }
sub audit { return grep { /accounts-import-update/ } split /\n/, slurp("$d/lazysite/logs/audit.log") }
sub stage {
    my (@rows) = @_;
    my $r = api( 'op', 'accounts-import-stage', { accounts => \@rows } );
    ok( $r->{ok}, 'staged' ) or diag( $r->{error} // '' );
    return $r->{id} // '';
}

my $users_before = slurp("$d/lazysite/auth/users");
my $id = stage(
    { username => 'u1', email => 'new1@example.org', groups => [qw(authors g-op reg nosuch)] },
    { username => 'u2' },                                  # names nothing: nothing to change
    { username => 'u3', groups => ['authors'] },           # already so
    { username => 'op', email => 'elsewhere@example.org', groups => [] },
    { username => 'n1', email => 'n1@example.org' } );

my %plan;
subtest 'the dry run shows the changes, and makes none' => sub {
    my $p = api( 'op', 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id" );
    ok( $p->{ok}, 'planned' ) or diag( $p->{error} // '' );
    is( $p->{create}, 1, 'one to create (n1)' );
    is( $p->{update}, 1, 'one to update (u1)' );
    is( $p->{skip},   3, 'three skipped (u2, u3, op)' );
    %plan = map { $_->{username} => $_ } @{ $p->{rows} || [] };
    my %ch = map { $_->{id} => $_ } @{ $plan{u1}{changes} || [] };
    is_deeply( [ sort keys %ch ], [ 'u1:+authors', 'u1:-editors', 'u1:email' ],
        'u1: the address, join authors, leave editors' );
    is( $ch{'u1:email'}{from}, 'old1@example.org', '...the address it has' );
    is( $ch{'u1:email'}{to},   'new1@example.org', '...and the one it would have' );
    my %ref = map { $_->{group} => $_->{why} } @{ $plan{u1}{groups_refused} || [] };
    like( $ref{'g-op'}   // '', qr/operator/,       'the operator group: never, said why' );
    like( $ref{reg}      // '', qr/registration/,   'a registration group: never, said why' );
    like( $ref{nosuch}   // '', qr/does not exist/, 'a group that does not exist: left out' );
    like( $plan{op}{why} // '', qr/operator/,       'the operator\'s own account: not changed by an import' );
    like( $plan{u3}{why} // '', qr/nothing differs/, 'an account already so: skipped' );
    ok( !exists $plan{u2}{changes}, 'a row naming no groups offers no group change' );
    is( email_of('u1'), 'old1@example.org', 'nothing was changed by the dry run' );
};

subtest 'the apply makes only what is ticked' => sub {
    my $r = api( 'op', 'accounts-import-apply',
        { id => $id, confirm => $id, updates => [ 'u1:email', 'u1:+authors', 'u2:email', 'op:email' ] } );
    ok( $r->{ok}, 'applied' ) or diag( $r->{error} // '' );
    is( email_of('u1'), 'new1@example.org', 'u1: the address, ticked, changed' );
    ok( in_group( 'u1', 'authors' ), 'u1: joined authors, ticked' );
    ok( in_group( 'u1', 'editors' ), 'u1: still in editors - leaving it was not ticked' );
    ok( !in_group( 'u1', 'g-op' ) && !in_group( 'u1', 'reg' ), 'u1: in neither refused group' );
    is( email_of('op'), '', 'the operator\'s account: untouched, ticked or not' );
    is_deeply( [ sort @{ $r->{unmatched} || [] } ], [ 'op:email', 'u2:email' ],
        'ticks that are no change in the plan: named, not applied' );
    my ($u1) = grep { $_->{username} eq 'u1' } @{ $r->{updated} || [] };
    is_deeply( [ sort @{ $u1->{applied} || [] } ], [ 'u1:+authors', 'u1:email' ], 'u1: what was applied' );
    ok( ( grep { $_->{username} eq 'n1' } @{ $r->{created} || [] } ), 'n1 created as before' );

    my $after = slurp("$d/lazysite/auth/users");
    my ($h0) = $users_before =~ /^u1:(.*)$/m;
    my ($h1) = $after        =~ /^u1:(.*)$/m;
    is( $h1, $h0, 'u1\'s password is what it was' );

    my @a = audit();
    is( scalar @a, 2, 'one audit row per change made' ) or diag( join "\n", @a );
    ok( ( grep { /\| u1 \|/ && /address changed/ } @a ), '...the address change, naming the account' );
    ok( !( grep { /example\.org/ } @a ), '...and no address' );
    ok( ( grep { /\| u1 \|/ && /joined authors/ } @a ), '...the group joined' );
};

subtest 'leaving a group takes its doors at once and keeps the session' => sub {
    my $before = api( 'u1', 'save', { content => "---\ntitle: Y\n---\ny\n" }, 'action=save&path=y.md' );
    ok( $before->{ok} && -f "$d/y.md", 'the control: in editors, u1 saves a page' ) or diag( encode_json($before) );
    my $id2 = stage( { username => 'u1', groups => ['authors'] } );
    my $r = api( 'op', 'accounts-import-apply', { id => $id2, confirm => $id2, updates => ['u1:-editors'] } );
    ok( $r->{ok}, 'applied' ) or diag( $r->{error} // '' );
    ok( !in_group( 'u1', 'editors' ), 'u1 left editors' );
    ok( in_group( 'u1', 'authors' ), '...and is still in authors' );
    my $rev = eval { decode_json( slurp("$d/lazysite/auth/revoked.json") ) } || {};
    ok( !exists( ( $rev->{not_before} || {} )->{u1} ), 'no revocation was written: the sessions stand' );
    my $c = api( 'u1', 'save', { content => "---\ntitle: X\n---\nx\n" }, 'action=save&path=x.md' );
    ok( !$c->{ok}, 'the next request no longer carries manage_content, which editors gave' )
        or diag( encode_json($c) );
    ok( !-f "$d/x.md", '...and wrote nothing' );
    ok( ( grep { /\| u1 \|/ && /left editors/ } audit() ), 'the leaving is audited' );
};

subtest 'an import never changes the operator group, either way' => sub {
    my $id3 = stage( { username => 'u3', groups => [] } );
    $s->users( 'group-add', 'u3', 'g-op' );    # as only local may
    my $p = api( 'op', 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id3" );
    my ($u3) = @{ $p->{rows} || [] };
    like( $u3->{why} // '', qr/operator/, 'u3, now an operator, is not changed' );
};

done_testing;
