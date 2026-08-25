#!/usr/bin/perl
# SM591: destruction across every store answers a LATERAL grant, in two tiers
# assigned by SM587's copy test.
#
# Measured on edge 2026-08-25: a principal holding `manage_data` and nothing
# else dropped another principal's table and deleted its safety export four
# seconds later. One capability, no ownership check, and the engine's own
# recoverability removed by the same grant in the next call.
#
# So the assertions here are about the SEAM, not about any one verb: "may use"
# and "may destroy inside" are now different sentences, and "recoverable" and
# "irreversible" are different sentences again. The third assertion is the one
# that would have been missed - a grant holding the recoverable tier must be
# REFUSED the export delete, because a drop is recoverable only while the
# export exists.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root grant_caps revoke_caps);
use Lazysite::Capabilities ();

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $d;

    # Pin the user-management tool this CGI shells to - _tool_path() resolves a
    # cgi-bin SIBLING first, which can be a stale copy outside the checkout.
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\nplugins:\n  - plugins/briefs.pl\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1,"assignable":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;
open my $pg, '>', "$d/about.md" or die $!;
print $pg "---\ntitle: About\n---\n\nAbout us.\n";
close $pg;

uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
ok( $tok, 'partner has a token' );

sub hold {
    my (@caps) = @_;
    revoke_caps( $d, 'partner',
        qw(manage_data manage_briefs manage_content housekeeping purge) );
    grant_caps( $d, 'partner', 'api', @caps );
    return;
}

sub post {
    my ( $qs, $body ) = @_;
    return mapi( $d, QUERY_STRING => $qs, REQUEST_METHOD => 'POST',
        body => ( $body // '{}' ), HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
}

sub refused {
    my ($r) = @_;
    return ( $r->{ok} ? 0 : 1 ) if ( $r->{error} // '' ) =~ /Insufficient capability/;
    return 0;
}

# --- 1. "may use" is no longer "may destroy inside" --------------------------
hold('manage_data');
ok( refused( post('action=data-table-drop&table=t') ),
    'manage_data alone cannot DROP a table' )
    or diag( explain post('action=data-table-drop&table=t') );
ok( refused( post('action=data-safety-export-delete&file=x.json') ),
    'nor delete the safety export that made a drop recoverable' );
ok( !refused( post('action=data-tables') ),
    'and still USES the module - the working verbs stay where they were' );

hold('manage_briefs');
ok( !refused( post( 'action=brief-append&path=/about', encode_json( { entry => 'why' } ) ) ),
    'manage_briefs still appends' );
ok( refused( post('action=brief-delete&path=/about') ),
    'and cannot DELETE another principal\'s brief - which is SM575' );

# --- 2. the two tiers are two grants -----------------------------------------
# The assertion that matters. A drop is recoverable ONLY because the export
# exists, so the tier that may drop must NOT be the tier that may delete the
# export - otherwise the split is a label rather than a boundary.
hold('housekeeping');
ok( !refused( post('action=data-table-drop&table=t') ),
    'the recoverable tier REACHES data-table-drop' );
ok( refused( post('action=data-safety-export-delete&file=x.json') ),
    'and is REFUSED the safety-export delete' );
ok( refused( post('action=brief-delete&path=/about') ), 'and brief-delete' );

hold('purge');
ok( !refused( post('action=data-safety-export-delete&file=x.json') ),
    'the irreversible tier reaches the export delete' );
ok( !refused( post('action=brief-delete&path=/about') ), 'and brief-delete' );
ok( refused( post('action=data-table-drop&table=t') ),
    'and does NOT imply the recoverable tier - two grants, not a ladder' );

# --- 3. the ACL verbs did not join the grant ---------------------------------
# The whole point of the operator's ruling on SM587. If clearing old backups
# also un-gated content, an operator who wanted a housekeeper would have handed
# over the permission surface.
{
    my $map = Lazysite::Capabilities::describe();
    my %under;
    for my $c ( Lazysite::Capabilities::action_keys() ) {
        $under{$_} = $c for @{ $map->{capabilities}{$c}{unlocks}{api} || [] };
    }
    is( $under{'acl-remove'}, 'manage_content',
        'acl-remove stays under manage_content' );
    is( $under{'acl-set'},                   'manage_content', 'and acl-set' );
    is( $under{'data-safety-export-delete'}, 'purge', 'while the export delete is lateral' );
    is( $under{'data-table-drop'}, 'housekeeping', 'and the drop is the recoverable tier' );
    is( $under{'brief-delete'},    'purge', 'and brief-delete the irreversible one' );

    # backup-delete is COOKIE-ONLY, so it belongs in the ui list and not the
    # api one: a capability that named it under `api` would send a token client
    # after a door that is not there, which is SM435 pointed the other way.
    ok( ( grep { /backup-delete/ } @{ $map->{capabilities}{purge}{unlocks}{ui} || [] } ),
        'backup-delete is named on the surface that actually serves it' )
        or diag( explain $map->{capabilities}{purge}{unlocks} );

    # SM577: the backup store is INSTANCE-wide - package_create writes any
    # configured domain's archive into the local _backups_dir - so the grant
    # that authorised a deletion does not bound what it can destroy. Said where
    # the capability is described, which is what a partner reads before asking
    # for it.
    like( $map->{capabilities}{purge}{title}, qr/instance/i,
        'the purge description says the backup store is instance-wide' );
    like( $map->{capabilities}{purge}{title}, qr/not scoped|other|another/i,
        'and that a deletion is not scoped by the site whose grant allowed it' );
}

# --- 4. the roster is readable, through the closure --------------------------
# SM591's concentration note: one grant reaching every store makes a mis-scoped
# lateral grant the most valuable mistake on the estate, so who holds it must be
# answerable - and answerable through the NESTING, since SM573's
# seven-vs-seventeen was invisible precisely because the capabilities arrived by
# membership.
uapi( $d, { action => 'add', username => 'housekeeper', password => 'x' } );
uapi( $d, { action => 'group-settings-set', group => 'lateral', key => 'purge', value => 'on' } );
uapi( $d, { action => 'group-settings-set', group => 'ops', key => 'assignable', value => 'on' } );
uapi( $d, { action => 'group-nest', sub      => 'ops',         parent => 'lateral' } );
uapi( $d, { action => 'group-add',  username => 'housekeeper', group  => 'ops' } );

my $holders = uapi( $d, { action => 'capability-holders' } )->{holders} || {};
ok( $holders->{purge}, 'the roster covers the lateral capability' )
    or diag( explain $holders );
ok( ( grep { $_ eq 'lateral' } @{ $holders->{purge}{group_names} || [] } ),
    'and names the group that carries it' )
    or diag( explain $holders->{purge} );
cmp_ok( $holders->{purge}{users}, '>=', 1,
    'an account that holds it only through a NESTED group is counted in the roster' )
    or diag( explain $holders->{purge} );

done_testing();
