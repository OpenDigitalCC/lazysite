#!/usr/bin/perl
# SM1369 X6, H-11 (ruling 55): ONE SECRETS STORE, AND THE SECRETS SET BEFORE IT
# STAY READABLE.
#
# Lazysite::Secrets is the store the connectors and the Odoo extension both use
# now, by owner: lazysite/<owner>/keys/<name>.key. Held here:
#
#   * a secret is written alone, 0600, in a 0700 directory, whatever the umask;
#     has() answers 1, 0, or undef when it is there and cannot be read, and a put
#     over one that cannot be read is refused; there is nothing that lists them;
#   * A STORE FROM BEFORE THE CHANGE: a connector whose secret is in the older
#     map (connectors/secrets.json) is listed with has_secret 1 and its call
#     carries that secret; set again, the secret moves into the store and leaves
#     the map, which goes when it is empty;
#   * an Odoo key set before the change (odoo/keys/<account>.key) is the store's
#     file for that account: read where it is, set and cleared there;
#   * each owner's secrets are its own: the same name under two owners is two
#     secrets.
#
# Sabotage: drop the fallback to the older map in Connectors::_secret_state and
# the connector set before the change reads as having no secret - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use JSON::PP;

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; 1 } or plan skip_all => 'HTTP::Daemon/LWP not available';
}
use Lazysite::Secrets ();
use Lazysite::Manager::Connectors;

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c, $m ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; chmod $m, $p if $m; return }
sub mode_of { return ( stat $_[0] )[2] & 0777 }

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path( "$lz/connectors", "$lz/odoo/keys", "$lz/auth" );
$Lazysite::Manager::Connectors::DOCROOT = $d;

# A remote that says which Authorization it was sent.
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
my $base = $srv->url;
my $pid  = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content( encode_json( { auth => ( $req->header('Authorization') // '' ) } ) );
            $conn->send_response($res);
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

subtest 'the store: alone, 0600, never listed, and "cannot tell" is not "none"' => sub {
    my $old = umask 0;
    my ( $ok, $why ) = Lazysite::Secrets::put( $lz, 'probe', 'token', 's3cret' );
    umask $old;
    ok( $ok, 'put' ) or diag $why;
    my $p = Lazysite::Secrets::path( $lz, 'probe', 'token' );
    is( $p, "$lz/probe/keys/token.key", 'one file, under its owner' );
    is( mode_of($p), 0600, '0600 under a umask of 0' );
    is( mode_of("$lz/probe/keys"), 0700, 'in a 0700 directory' );
    is( Lazysite::Secrets::has( $lz, 'probe', 'token' ), 1, 'has: 1' );
    is( Lazysite::Secrets::has( $lz, 'probe', 'other' ), 0, 'has: 0 for none' );
    is( Lazysite::Secrets::has( $lz, 'odoo', 'token' ), 0, 'another owner\'s same name is another secret' );
    ok( !Lazysite::Secrets->can('list') && !Lazysite::Secrets->can('all'), 'nothing lists the store' );
    ok( !( Lazysite::Secrets::put( $lz, 'probe', 'token', "two\nlines" ) )[0], 'a secret is one line' );
    ok( !( Lazysite::Secrets::put( $lz, '../x', 'token', 'v' ) )[0], 'an owner is an id, never a path' );
    ok( !( Lazysite::Secrets::put( $lz, 'probe', '../t', 'v' ) )[0], 'a name is a name, never a path' );
  SKIP: {
        skip 'root opens everything', 3 if $> == 0;
        chmod 0, $p;
        ok( !defined Lazysite::Secrets::has( $lz, 'probe', 'token' ), 'unreadable: undef, not 0' );
        my ( $pok, $pwhy ) = Lazysite::Secrets::put( $lz, 'probe', 'token', 'over' );
        ok( !$pok, 'nothing is written over a secret that cannot be read' );
        like( $pwhy, qr/cannot be read by this process; nothing was written/, '...and it says so' );
        chmod 0600, $p;
    }
    ok( ( Lazysite::Secrets::clear( $lz, 'probe', 'token' ) )[0], 'clear' );
    ok( !-e $p, 'the file is gone' );
    ok( ( Lazysite::Secrets::clear( $lz, 'probe', 'token' ) )[0], 'clearing what is gone is cleared' );
};

subtest 'a connector secret set before the change is read, and moves on its next set' => sub {
    # The connectors' store as an earlier release wrote it.
    spit( "$lz/connectors/connectors.json", encode_json( {
                old => { name => 'old', url => "${base}x", method => 'POST', secret_header => 'Authorization',
                    secret_prefix => 'Bearer ', modes => { scheduled => 0, authenticated => 1, public => 0 },
                    callers => [], rate_per_hour => 0, timeout => 5, answer_table => '', data_class => 'form' },
                two => { name => 'two', url => "${base}y", method => 'POST', secret_header => 'Authorization',
                    secret_prefix => 'Bearer ', modes => { scheduled => 0, authenticated => 1, public => 0 },
                    callers => [], rate_per_hour => 0, timeout => 5, answer_table => '', data_class => 'form' } } ), 0660 );
    spit( "$lz/connectors/secrets.json", encode_json( { old => 'tok-legacy', two => 'tok-two' } ), 0600 );

    my $list = Lazysite::Manager::Connectors::action_connector_list();
    my %has  = map { $_->{id} => $_->{has_secret} } @{ $list->{connectors} };
    is( $has{old}, 1, 'listed with its secret' );
    is( $list->{secrets_readable}, 1, 'and the store reads' );
    my $c = Lazysite::Manager::Connectors::call( 'old', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 },
        actor => 'ops', trigger => 'test' );
    is( $c->{answer}{auth}, 'Bearer tok-legacy', 'its call carries the secret set before the change' ) or diag explain $c;

    my $r = Lazysite::Manager::Connectors::action_connector_secret_set( 'old', 'tok-new' );
    ok( $r->{ok}, 'set again' ) or diag $r->{error};
    is( mode_of("$lz/connectors/keys/old.key"), 0600, 'now in the store, 0600' );
    my $map = decode_json( do { local ( @ARGV, $/ ) = "$lz/connectors/secrets.json"; <> } );
    ok( !exists $map->{old}, 'and out of the older map' );
    is( $map->{two}, 'tok-two', 'which keeps the others' );
    $c = Lazysite::Manager::Connectors::call( 'old', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 },
        actor => 'ops', trigger => 'test' );
    is( $c->{answer}{auth}, 'Bearer tok-new', 'the call carries the new one' );

    $r = Lazysite::Manager::Connectors::action_connector_delete('two');
    ok( $r->{ok}, 'the last connector in the map deleted' );
    ok( !-e "$lz/connectors/secrets.json", 'and the empty map is gone' );
};

subtest 'an Odoo key set before the change is the store\'s file for its account' => sub {
    require Lazysite::Extensions;
    Lazysite::Extensions::add_payload_lib("$FindBin::Bin/../../../extensions/odoo.pl");
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $d;
    spit( "$lz/odoo/keys/connection.key", "old-api-key\n", 0600 );
    is( Lazysite::Odoo::Secret::has_key('connection'), 1, 'read where it is' );
    is( Lazysite::Odoo::Secret::key_path('connection'), "$lz/odoo/keys/connection.key", 'the file OOM is given' );
    is( ( Lazysite::Secrets::get( $lz, 'odoo', 'connection' ) )[0], 'old-api-key', 'the store reads it as its own' );
    ok( ( Lazysite::Odoo::Secret::set_key( 'connection', 'new-api-key' ) )[0], 'set again' );
    is( mode_of("$lz/odoo/keys/connection.key"), 0600, 'in the same file, 0600' );
    ok( !( Lazysite::Odoo::Secret::set_key( 'connection', 'has space' ) )[0], 'the extension\'s own rule for a key still holds' );
    ok( ( Lazysite::Odoo::Secret::clear_key('connection') )[0], 'cleared' );
    is( Lazysite::Odoo::Secret::has_key('connection'), 0, 'and gone' );
};

done_testing;
