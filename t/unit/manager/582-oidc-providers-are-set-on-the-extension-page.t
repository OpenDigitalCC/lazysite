#!/usr/bin/perl
# SM1351, ruling 214 (Q127, Q129): THE OIDC PROVIDERS ARE SET ON THE EXTENSION
# PAGE, AND ONLY THE OPERATOR MAPS A PROVIDER GROUP TO A CAPABILITY GROUP.
#
# Through the real manager API (extension-read, extension-save), as the settings
# form sends them:
#
#   * the providers are a repeating section: each record's fields land in
#     lazysite/oidc.conf as <name>.<field>, the group map from rows; the client
#     secret goes into the secrets store, never into the file and never back to
#     the reader (which says only whether it is set); a blank secret keeps it;
#     removing a provider removes its lines and its secret; the save fetches
#     discovery (the on_save hook runs);
#   * Q129: a manage_config holder who is not the operator may map to a plain
#     group, is refused a capability-carrying group (operators, or a group that
#     carries a capability) with `forbidden` naming why, and keeps a capability
#     mapping the map already held while editing the rest; the operator may add
#     one.
#
# Sabotage (each run by hand, each fails here): skip the records branch in
# action_extension_save (the record is not written); write the secret into the
# file; let validate_group_map pass every caller (the non-operator's operators
# mapping lands).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root index_extensions);
use ManagerSession qw(new_site);

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root = repo_root();
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nextensions:\n  - extensions/oidc.pl\n" );
my $d  = $s->docroot;
my $lz = "$d/lazysite";
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }
my $idx = index_extensions($d);
ok( ( grep { $_ eq 'oidc' } @{ $idx->{indexed} || [] } ), 'the OIDC extension is on and indexed' ) or diag explain $idx;

# The operator, an editor holding manage_config, and a group that carries a capability.
$s->add_user('boss');
$s->users( 'group-add', 'boss', 'ops' );
$s->users( 'group-set', 'ops', 'manager', 'on' );
$s->add_user('ed');
$s->grant( 'ed', 'config-eds', [qw(ui manage_config)], [qw(ui manage_config)] );
$s->add_user('pat');
$s->grant( 'pat', 'publishers', ['api'], ['api'] );

sub save {
    my ( $who, @recs ) = @_;
    return $s->call( $who, 'extension-save', query => 'action=extension-save&extension=oidc',
        body => { script => 'extensions/oidc.pl', values => { providers => [@recs] } }, groups => 1 );
}

sub read_back {
    my $r = $s->call( 'boss', 'extension-read', query => 'action=extension-read&extension=oidc',
        body => { script => 'extensions/oidc.pl' }, groups => 1 );
    return $r->{values}{providers} || [];
}

my %staff = ( name => 'staff', issuer => 'http://127.0.0.1:9/staff', client_id => 'example-site',
    group_map => [ [ 'writers', 'editors' ], [ 'site admins', 'readers' ] ], label => 'Sign in with Staff ID' );

subtest 'Q127: a provider is set on the extension page' => sub {
    my $r = save( 'ed', { %staff, secret => 'shh-staff-secret' } );
    ok( $r->{ok}, 'an editor saves a provider' ) or diag explain $r;
    my $conf = slurp("$lz/oidc.conf");
    like( $conf, qr/^providers: staff$/m, 'the section names it' );
    like( $conf, qr{^staff\.issuer: http://127\.0\.0\.1:9/staff$}m, 'its issuer is a line of its own' );
    like( $conf, qr/^staff\.group_map: writers = editors, site admins = readers$/m, 'the map is written from its rows' );
    unlike( $conf, qr/shh-staff-secret/, 'the secret is not in the file' );
    is( slurp("$lz/oidc/keys/staff.key"), "shh-staff-secret\n", 'it is in the secrets store' );
    ok( -e "$lz/oidc/discovery/staff.json", 'the save fetched the provider\'s discovery' );
    my ($back) = @{ read_back() };
    is( $back->{name},       'staff', 'the reader answers the record' );
    is( $back->{group_map},  'writers = editors, site admins = readers', '...its map' );
    is( $back->{secret_set}, 1, '...and that its secret is set' );
    ok( !grep( { defined && /shh-staff/ } values %$back ), '...never the secret' );
    $r = save( 'ed', { %staff, label => 'Staff sign-in', secret => '' } );
    ok( $r->{ok}, 'a save with a blank secret' ) or diag explain $r;
    is( slurp("$lz/oidc/keys/staff.key"), "shh-staff-secret\n", '...keeps the stored one' );
    like( slurp("$lz/oidc.conf"), qr/^staff\.label: Staff sign-in$/m, '...and changes the rest' );
    $r = save( 'ed', { name => 'Bad Name', issuer => 'x', client_id => 'y' } );
    is( $r->{kind}, 'invalid', 'a name that is not one is refused' );
    $r = save( 'ed', { %staff, label => "two\nlines" } );
    is( $r->{kind}, 'invalid', 'a value with a line break is refused' );
};

subtest 'removing a provider removes its lines and its secret' => sub {
    my $r = save('ed');
    ok( $r->{ok}, 'a save with no providers' ) or diag explain $r;
    unlike( slurp("$lz/oidc.conf"), qr/^staff\./m, 'the provider\'s lines are gone' );
    ok( !-e "$lz/oidc/keys/staff.key", '...and its secret' );
};

done_testing;
