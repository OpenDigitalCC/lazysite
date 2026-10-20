#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, "0.15.16 open points" 1: "site-admins also gets the
# maintenance capability: yes"): the site-admins ROLE holds access during
# maintenance, through a `cap-maintenance` bundle it draws on the way it draws on
# cap-tidy; a content-editor does not; and a site seeded BEFORE the bundle existed
# is given it on upgrade.
#
# Real requests through the real wrapper, against groups the users tool wrote -
# not a capability granted to a user by the test rig, which is what t/integration/
# 315 does for the operator.
#
#   fresh      setup-sysop seeds the roles; a site-admins member passes, a
#              content-editors member is sent to the page
#   upgrade    the store a release without the bundle left (the bundle and its
#              nesting removed from a seeded store): site-admins is shut out, an
#              ordinary use of the tool brings the bundle in, then it passes
#   edits      a site-admins group an operator edited is not rewritten, and an
#              operator who takes the role out of the bundle keeps it out
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root run_cmd);
use MaintenanceRig qw(build_site cookie_for conf_set via_wrapper slurp spit);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";

sub users_cli {
    my ( $d, @a ) = @_;
    return run_cmd( $^X, $tool, '--docroot', $d, @a );    # list form (t/lint/40)
}
# What the manager's own reads do first (users-page): the trigger an existing site
# adopts a release on.
sub touch {
    my ($d) = @_;
    require IPC::Open2;
    my $pid = IPC::Open2::open2( my $o, my $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json( { action => 'users-page', me => 'boss' } );
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return $out;
}
sub gs_file { "$_[0]/lazysite/auth/groups-settings.json" }
sub gs_read { decode_json( slurp( gs_file( $_[0] ) ) ) }
sub members_of {
    my ( $d, $g ) = @_;
    my ($line) = grep { /^\Q$g\E:/ } split /\n/, slurp("$d/lazysite/auth/groups");
    return () unless $line;
    $line =~ s/^[^:]+:\s*//;
    return grep { length } split /[,\s]+/, $line;
}
sub through {
    my ( $d, $u ) = @_;
    my $r = via_wrapper( $d, uri => '/about', cookie => cookie_for($u) );
    return $r->{code};
}

# A site with the roles seeded by the users tool, and no per-user grants for the
# two accounts under test.
sub role_site {
    my $d = build_site( conf => "maintenance: on\n" );
    unlink "$d/lazysite/auth/groups", gs_file($d);
    spit( "$d/lazysite/auth/users", "boss:x\nadmin1:x\neditor1:x\n" );
    users_cli( $d, 'setup-sysop', '--user',  'boss' );
    users_cli( $d, 'group-add',   'admin1',  'site-admins' );
    users_cli( $d, 'group-add',   'editor1', 'content-editors' );
    return $d;
}

# --- a fresh site ----------------------------------------------------------
{
    my $d  = role_site();
    my $gs = gs_read($d);
    ok( $gs->{'cap-maintenance'}, 'a fresh site is seeded with the cap-maintenance bundle' );
    is( $gs->{'cap-maintenance'}{maintenance_access}, 1, '...holding maintenance_access' );
    is( $gs->{'cap-maintenance'}{assignable}, 0, '...as a bundle, not a role a person is put in' );
    ok( length( $gs->{'cap-maintenance'}{description} // '' ), '...with a description' );
    is_deeply( [ members_of( $d, 'cap-maintenance' ) ], ['site-admins'], 'site-admins draws on it, and nobody else' );

    is( through( $d, 'boss' ),   200, 'the operator passes' );
    is( through( $d, 'admin1' ), 200, 'a site-admins member passes' );
    is( through( $d, 'editor1' ), 302, 'a content-editors member is sent to the maintenance page' );
}

# --- an existing site, seeded before the bundle ----------------------------
{
    my $d = role_site();
    # an operator's edit to the role must survive: take housekeeping from it
    users_cli( $d, 'group-set', 'site-admins', 'housekeeping', 'off' );
    my $edited = gs_read($d)->{'site-admins'};
    my $gs     = gs_read($d);
    delete $gs->{'cap-maintenance'};
    spit( gs_file($d), encode_json($gs) );
    my @keep = grep { !/^cap-maintenance:/ } split /\n/, slurp("$d/lazysite/auth/groups");
    spit( "$d/lazysite/auth/groups", join( "\n", @keep ) . "\n" );
    ok( !exists gs_read($d)->{'cap-maintenance'}, 'the store has the shape the earlier release left (no bundle)' );

    touch($d);
    my $after = gs_read($d);
    ok( $after->{'cap-maintenance'}, 'an ordinary use of the tool adds the bundle to the existing site' );
    is( $after->{'cap-maintenance'}{maintenance_access}, 1, '...holding maintenance_access' );
    is_deeply( [ members_of( $d, 'cap-maintenance' ) ], ['site-admins'], '...drawn on by site-admins' );
    is_deeply( $after->{'site-admins'}, $edited, 'the site-admins group an operator edited is not rewritten' );
    is( through( $d, 'admin1' ),  200, 'a site-admins member now passes' );
    is( through( $d, 'editor1' ), 302, 'a content-editors member still does not' );

    # an operator who takes the role out of the bundle keeps it out
    my @m = grep { /./ } split /\n/, slurp("$d/lazysite/auth/groups");
    s/^cap-maintenance:.*/cap-maintenance:/ for @m;
    spit( "$d/lazysite/auth/groups", join( "\n", @m ) . "\n" );
    touch($d);
    is_deeply( [ members_of( $d, 'cap-maintenance' ) ], [], 'a later use of the tool does not put the role back' );
    is( through( $d, 'admin1' ), 302, '...and site-admins is shut out again, as the operator chose' );
}

# --- a site that never had the role layer is left alone --------------------
{
    my $d = build_site( conf => "maintenance: on\n" );
    unlink "$d/lazysite/auth/groups", gs_file($d);
    spit( gs_file($d), encode_json( { 'my-team' => { assignable => 1, manage_content => 1 } } ) );
    spit( "$d/lazysite/auth/groups", "my-team: admin1\n" );
    touch($d);
    ok( !exists gs_read($d)->{'cap-maintenance'}, 'no shipped site-admins role: no bundle is invented' );
}

done_testing;
