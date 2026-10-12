#!/usr/bin/perl
# SM747 E / Q2 (ruled 2026-10-12): "MCP will use the default or specified
# account." An MCP grant runs as the connection user, or - when the operator
# configured one - as an Odoo account of its own, whose key is stored as the
# connection user's is and never shown. The control API's door stays the
# connection user's. A grant map that cannot be read refuses rather than
# falling back to the (likely wider) connection user.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'list', operation => 'shop.products', modes => 'authenticated', callers => 'agents' );
my %BOT = ( user => 'bot@agents', groups => ['agents'], caps => {}, ip => '192.0.2.9' );
my $KEY = 'grant-own-k3y-42';

sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }
sub keys_sent { return [ map { $_->[4] } grep { $_->[1] eq 'execute_kw' } @{ $fake->calls } ] }

subtest 'setting a grant\'s account' => sub {
    my $r = act( 'action_odoo_secret_set', $KEY, grant => 'bot@agents' );
    like( $r->{error}, qr/login is required with grant/, 'a grant needs its Odoo login' );
    $r = act( 'action_odoo_secret_set', $KEY, grant => '../x', login => 'agent' );
    is( $r->{field}, 'grant', 'a grant that is not an account name is refused' );
    $r = act( 'action_odoo_secret_set', $KEY, grant => 'bot@agents', login => 'odoo-agent' );
    ok( $r->{ok}, 'set' ) or diag explain $r;
    unlike( encode_json($r), qr/\Q$KEY\E/, 'the answer does not carry the key' );
    my $s = act('action_odoo_status');
    is_deeply( $s->{grants}, [ { grant => 'bot@agents', login => 'odoo-agent', has_secret => 1 } ],
        'the status lists it, with has_secret and never the key' );
    unlike( encode_json($s), qr/\Q$KEY\E/, 'the status carries no key' );
    my @files = glob("$d/lazysite/odoo/keys/*.key");
    is( scalar @files, 2, 'the grant\'s key is a file of its own beside the connection user\'s' );
    unlike( join( ' ', @files ), qr/bot|agents/, 'named by a hash, not by the account' );
};

subtest 'over MCP the grant runs as its own account' => sub {
    my $r = act( 'action_odoo_run', 'list', {}, %BOT, channel => 'mcp' );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( keys_sent()->[-1],                        $KEY, 'with the grant\'s key' );
    is( Lazysite::Odoo::read_calls()->[0]{login}, 'odoo-agent', 'and the record names its Odoo login' );
};

subtest 'over the control API it is the connection user' => sub {
    my $r = act( 'action_odoo_run', 'list', {}, %BOT, channel => 'api' );
    ok( $r->{ok}, 'answered' );
    is( keys_sent()->[-1], 'k3y-for-tests', 'with the connection user\'s key' );
    is( Lazysite::Odoo::read_calls()->[0]{login}, 'site-connection', 'and its login' );
};

subtest 'a grant with no account of its own is the connection user' => sub {
    my $r = act( 'action_odoo_run', 'list', {}, %BOT, user => 'other@agents', channel => 'mcp' );
    ok( $r->{ok}, 'answered' );
    is( keys_sent()->[-1], 'k3y-for-tests', 'the default account' );
};

subtest 'a grant map that cannot be read refuses' => sub {
    plan skip_all => 'root reads anything' if $> == 0;
    chmod 0000, "$d/lazysite/odoo/grants.json";
    my $before = scalar @{ $fake->calls };
    my $r      = act( 'action_odoo_run', 'list', {}, %BOT, channel => 'mcp' );
    chmod 0660, "$d/lazysite/odoo/grants.json";
    is( $r->{kind},               'cannot-tell', 'refused as cannot-tell' );
    is( scalar @{ $fake->calls }, $before,       'and nothing reached Odoo as anybody' );
};

subtest 'clearing a grant\'s account' => sub {
    unlink glob("$d/lazysite/odoo/keys/grant-*.key");
    my $r = act( 'action_odoo_run', 'list', {}, %BOT, channel => 'mcp' );
    is( $r->{kind}, 'no-key', 'a configured grant without its key is refused, not run as the connection user' );
    like( $r->{error}, qr/this grant's Odoo account has no API key/, 'and says whose key' );
    $r = act( 'action_odoo_secret_clear', grant => 'bot@agents' );
    ok( $r->{ok}, 'cleared' );
    is_deeply( act('action_odoo_status')->{grants}, [], 'and gone from the status' );
};

done_testing();
