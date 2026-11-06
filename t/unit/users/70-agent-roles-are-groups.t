#!/usr/bin/perl
# SM1371 (ruling 122): ROLES FOR AGENT ACCOUNTS, BUILT ON GROUPS.
#
# Four named roles ship as assignable groups (ADR 0003: capabilities are
# group-only, and a role is a group-like grant on that model): content agent,
# data agent, forms reader and analytics, each the measured grants of real sites
# and nothing more. A site seeded before them adopts them once, with no members,
# so adopting changes nobody's access. The account view (users-page) and whoami
# say which roles an account holds and what it holds beyond them - an over-grant
# is drawn rather than left unnoticed.
#
# With the change reverted: the four groups are absent from the seed and from an
# existing site, users-page rows carry no `roles`, and role_summary does not exist.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir run_cmd run_child);

my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub cli   { my ( $d, @a ) = @_; return run_cmd( $^X, $tool, '--docroot', $d, @a ) }
sub gs_read { decode_json( slurp("$_[0]/lazysite/auth/groups-settings.json") ) }
sub api {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub seeded_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\nbot:x\n" );
    cli( $d, 'setup-sysop', '--user', 'boss' );
    return $d;
}

my %WANT = (
    'content-agent'   => [qw(manage_content manage_forms manage_nav mcp)],
    'data-agent'      => [qw(manage_briefs manage_data mcp write_data)],
    'forms-reader'    => [qw(mcp read_submissions)],
    'analytics-agent' => [qw(analytics mcp)],
);
use Lazysite::Auth::Settings qw(@CAP_KEYS);
my @CAPS = @CAP_KEYS;
sub caps_of { my $r = shift; return [ sort grep { $r->{$_} } @CAPS ] }

subtest 'a fresh site ships the four agent roles, assignable, holding exactly their grants' => sub {
    my $d  = seeded_site();
    my $gs = gs_read($d);
    for my $role ( sort keys %WANT ) {
        ok( ref $gs->{$role} eq 'HASH', "$role is seeded" ) or next;
        ok( $gs->{$role}{assignable}, '...as a role (assignable)' );
        is_deeply( caps_of( $gs->{$role} ), $WANT{$role}, "...granting @{ $WANT{$role} }" );
        ok( length( $gs->{$role}{label} // '' ) && length( $gs->{$role}{description} // '' ),
            '...with a label and a description' );
    }
    ok( !$gs->{'content-agent'}{ui} && !$gs->{'content-agent'}{manage_themes}
            && !$gs->{'content-agent'}{api},
        'no role carries the manager UI, design or the control API' );
};

subtest 'an existing site adopts them once, empty, and a deleted one stays deleted' => sub {
    my $d  = seeded_site();
    my $gs = gs_read($d);
    delete @{$gs}{ keys %WANT };
    spit( "$d/lazysite/auth/groups-settings.json", encode_json($gs) );
    unlink "$d/lazysite/auth/bundles-adopted.json";
    ok( !gs_read($d)->{'data-agent'}, 'the store has the shape an earlier release left' );

    api( $d, { action => 'users-page', me => 'boss' } );
    my $after = gs_read($d);
    ok( $after->{$_}, "$_ is adopted" ) for sort keys %WANT;
    is_deeply( caps_of( $after->{'data-agent'} ), $WANT{'data-agent'}, '...as shipped' );
    unlike( slurp("$d/lazysite/auth/groups"), qr/^(?:content-agent|data-agent|forms-reader|analytics-agent):/m,
        '...with no members: adopting a role gives nobody anything' );

    api( $d, { action => 'group-delete', group => 'forms-reader' } );
    ok( !gs_read($d)->{'forms-reader'}, 'an operator deletes one' );
    api( $d, { action => 'users-page', me => 'boss' } );
    ok( !gs_read($d)->{'forms-reader'}, 'the next use of the tool does not bring it back' );
};

subtest 'the account view names the role held and what is held beyond it' => sub {
    my $d = seeded_site();
    cli( $d, 'group-add', 'bot', 'content-agent' );
    cli( $d, 'group-add', 'bot', 'role-bot' );
    cli( $d, 'group-set', 'role-bot', 'analytics', 'on' );
    my $page = api( $d, { action => 'users-page', me => 'boss' } );
    my ($row) = grep { $_->{user} eq 'bot' } @{ $page->{users} || [] };
    ok( $row && ref $row->{roles} eq 'HASH', 'users-page carries the account\'s roles' ) or return;
    is_deeply( [ map { $_->{group} } @{ $row->{roles}{roles} } ], ['content-agent'],
        'the role held is the content agent (its own role-bot group is not a role)' );
    is( $row->{roles}{roles}[0]{label}, 'Content agent', '...by its label' );
    is_deeply( [ sort @{ $row->{roles}{roles}[0]{capabilities} } ], $WANT{'content-agent'},
        '...with what it grants' );
    is_deeply( $row->{roles}{beyond}, ['analytics'], 'and analytics is reported beyond the role' );

    cli( $d, 'group-add', 'bot', 'analytics-agent' );
    $page = api( $d, { action => 'users-page', me => 'boss' } );
    ($row) = grep { $_->{user} eq 'bot' } @{ $page->{users} || [] };
    is_deeply( $row->{roles}{beyond}, [], 'held through a second role, nothing is beyond the roles' );
    is_deeply( [ sort map { $_->{group} } @{ $row->{roles}{roles} } ], [qw(analytics-agent content-agent)],
        '...and both roles are named' );
};

subtest 'a role that draws on a bundle reports the bundle\'s grants' => sub {
    my $d = seeded_site();
    cli( $d, 'group-add', 'bot', 'app-developers' );
    my $page = api( $d, { action => 'users-page', me => 'boss' } );
    my ($row) = grep { $_->{user} eq 'bot' } @{ $page->{users} || [] };
    my ($r)   = grep { $_->{group} eq 'app-developers' } @{ $row->{roles}{roles} || [] };
    ok( $r, 'app-developers is a role held' ) or return;
    ok( ( grep { $_ eq 'manage_data' } @{ $r->{capabilities} } ) && ( grep { $_ eq 'mcp' } @{ $r->{capabilities} } ),
        '...granting what its nested bundles carry (cap-data, ch-agent)' );
    is_deeply( $row->{roles}{beyond}, [], 'and nothing is beyond it' );
};

done_testing;
