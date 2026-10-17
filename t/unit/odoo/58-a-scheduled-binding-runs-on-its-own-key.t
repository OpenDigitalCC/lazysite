#!/usr/bin/perl
# SM1161 (L5, release manager 2026-10-18: "Scheduled keys now, person keys
# later"): A SCHEDULED BINDING RUNS AS A NAMED ODOO LOGIN WITH ITS OWN KEY.
#
# The operator sets it per binding. The key is held as the connection user's
# and an MCP grant's are (its own 0600 file, written alone, never returned,
# has_secret 1/0/null); the call record and the audit name the actor
# `scheduled:<binding>` and the Odoo login the run used; a binding with no key
# of its own runs as the connection user as before. odoo-status shows each
# scheduled key's login and, where OOM reports it, its expiry.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo     ();
use Lazysite::Handlers ();

my ( $d, $fake ) = shop_ready( shop => { fake => { series => 18 } } );

# The models core.whoami reads, so the key's expiry can be asked of Odoo as OOM does.
my $c = sub { { type => 'char', store => 1 } };
$fake->{fields}{'res.users'} = { login => $c->(), name => $c->(),
    groups_id => { type => 'many2many', relation => 'res.groups' } };
$fake->{fields}{'res.groups'} = { name => $c->(), full_name => $c->(), display_name => $c->() };
$fake->{fields}{'res.users.apikeys'} = { name => $c->(), scope => $c->(), create_date => $c->(),
    expiration_date => $c->(), user_id => { type => 'many2one', relation => 'res.users' } };
$fake->insert( 'res.users', { id => 2, login => 'sched-bot', name => 'Scheduled bot', groups_id => [] } );
my $T0 = time;    # one clock for the file, so a date is the same date when asked again
sub when { return strftime( '%Y-%m-%d %H:%M:%S', gmtime( $T0 + $_[0] * 86400 ) ) }
$fake->insert( 'res.users.apikeys', { name => 'nightly', scope => '', create_date => when(-1), expiration_date => when(10), user_id => 2 } );

bind( $d, id => 'nightly', operation => 'shop.products', modes => 'scheduled' );
bind( $d, id => 'other',   operation => 'shop.products', modes => 'scheduled' );
bind( $d, id => 'paged',   operation => 'shop.products', modes => 'authenticated', callers => 'staff' );

my $KEY = 'sched-own-k3y-77';
sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }
sub keys_sent { return [ map { $_->[4] } grep { $_->[1] eq 'execute_kw' } @{ $fake->calls } ] }

# Run a binding as the scheduler does: through the handler delivery.
sub timer {
    my ($id) = @_;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    my ( $log, $r ) = quiet( sub { Lazysite::Handlers::deliver( $id, {}, origin => 'timer', source => "timer:$id",
                store => $id, actor => 'scheduler-job' ) } );
    return ( $r, $log );
}

subtest 'without a key of its own it runs as the connection user' => sub {
    my ($r) = timer('nightly');
    ok( $r->{ok}, 'delivered' ) or diag explain $r;
    is( keys_sent()->[-1],                        'k3y-for-tests',   'with the connection user\'s key' );
    is( Lazysite::Odoo::read_calls()->[0]{login}, 'site-connection', 'as its login' );
};

subtest 'setting and refusing' => sub {
    my $r = act( 'action_odoo_secret_set', $KEY, scheduled => 'nightly' );
    like( $r->{error}, qr/login is required/, 'the Odoo login is required' );
    $r = act( 'action_odoo_secret_set', $KEY, scheduled => 'nope', login => 'sched-bot' );
    is( $r->{field}, 'scheduled', 'a binding that does not exist is refused' );
    $r = act( 'action_odoo_secret_set', $KEY, scheduled => 'paged', login => 'sched-bot' );
    is( $r->{field}, 'scheduled', 'a binding that is not scheduled is refused' );
    $r = act( 'action_odoo_secret_set', $KEY, scheduled => 'nightly', grant => 'x', login => 'sched-bot' );
    ok( !$r->{ok}, 'a grant and a scheduled binding at once is refused' );
    $r = act( 'action_odoo_secret_set', "two\nlines", scheduled => 'nightly', login => 'sched-bot' );
    ok( !$r->{ok}, 'a key that is not one line is refused' );

    $r = act( 'action_odoo_secret_set', $KEY, scheduled => 'nightly', login => 'sched-bot' );
    ok( $r->{ok}, 'set' ) or diag explain $r;
    is( $r->{has_secret}, 1, 'the answer says has_secret' );
    unlike( encode_json($r), qr/\Q$KEY\E/, 'and never the key' );
    my @files = glob("$d/lazysite/odoo/keys/sched-*.key");
    is( scalar @files, 1, 'the key is a file of its own' );
    is( sprintf( '%04o', ( stat $files[0] )[2] & 07777 ), '0600', 'mode 0600' );
    unlike( $files[0], qr/nightly/, 'named by a hash of the binding' );
    open my $fh, '<', $files[0] or die;
    is( do { local $/; <$fh> }, "$KEY\n", 'alone in its file' );
    close $fh;
};

subtest 'it runs as that login, on its own key, recorded as scheduled:<binding>' => sub {
    my ( $r, $log ) = timer('nightly');
    ok( $r->{ok}, 'delivered' ) or diag explain $r;
    is( keys_sent()->[-1], $KEY, 'the fake saw the binding\'s own key' );
    my $rec = Lazysite::Odoo::read_calls()->[0];
    is( $rec->{actor}, 'scheduled:nightly', 'the call record\'s actor' );
    is( $rec->{login}, 'sched-bot',         'and the Odoo login it ran as' );
    is( $rec->{mode},  'scheduled',         'in scheduled mode' );
    my $audit = '';
    if ( open my $afh, '<', "$d/lazysite/logs/audit.log" ) { local $/; $audit = <$afh> }
    like( $audit, qr/odoo-call \| nightly -> shop\.products/, 'the audit has the Odoo call' );
    like( $audit, qr/\| scheduled:nightly \| odoo-call/, 'and names the actor' );

    ( $r, $log ) = timer('other');
    ok( $r->{ok}, 'another scheduled binding is delivered' );
    is( keys_sent()->[-1],                        'k3y-for-tests',   'and runs as the connection user' );
    is( Lazysite::Odoo::read_calls()->[0]{login}, 'site-connection', 'its record names the connection login' );
    isnt( Lazysite::Odoo::read_calls()->[0]{actor}, 'scheduled:other', 'without the scheduled actor' );
};

subtest 'an authenticated run never takes a scheduled key' => sub {
    my $r = act( 'action_odoo_run', 'paged', {}, user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5',
        channel => 'api' );
    ok( $r->{ok}, 'answered' );
    is( keys_sent()->[-1], 'k3y-for-tests', 'the connection user\'s key' );
};

subtest 'the status: login, has_secret, expiry - never the key' => sub {
    my $s = act('action_odoo_status');
    is( scalar @{ $s->{scheduled} }, 1, 'one scheduled key listed' );
    my $row = $s->{scheduled}[0];
    is( $row->{binding},    'nightly',   'the binding' );
    is( $row->{login},      'sched-bot', 'its login' );
    is( $row->{has_secret}, 1,           'has_secret' );
    is( $row->{expiry},     'exact',     'the expiry is the one key row\'s' );
    is( $row->{expires},    when(10),    'and its date' );
    unlike( encode_json($s), qr/\Q$KEY\E/, 'the status carries no key' );
    ok( -s "$d/lazysite/odoo/scheduled-expiry.json", 'the date is recorded for lazysite check' );
};

subtest 'more than one key row: the date is only a bound' => sub {
    $fake->insert( 'res.users.apikeys', { name => 'old', scope => '', create_date => when(-30), expiration_date => when(3), user_id => 2 } );
    my $row = act('action_odoo_status')->{scheduled}[0];
    is( $row->{expiry},  'latest-of',  'which key is held is not reported, so the latest date is a bound' );
    is( $row->{keys},    2,            'with the count' );
    is( $row->{expires}, when(10),     'the latest' );
    $fake->insert( 'res.users.apikeys', { name => 'forever', scope => '', create_date => when(-30), expiration_date => 0, user_id => 2 } );
    $row = act('action_odoo_status')->{scheduled}[0];
    is( $row->{expiry}, 'unknown-which', 'a key with no expiry among them: nothing can be said' );
    ok( !defined $row->{expires}, 'and no date is shown' );
    my $cache = do { open my $fh, '<', "$d/lazysite/odoo/scheduled-expiry.json" or die; local $/; <$fh> };
    unlike( $cache, qr/"nightly":\{[^}]*"expires_by"/, 'nothing is recorded for lazysite check to warn on' );
    delete $fake->{data}{'res.users.apikeys'}{$_} for @{ $fake->all_ids('res.users.apikeys') }[ 1, 2 ];
};

subtest 'a series that does not report an expiry is said so, not guessed' => sub {
    my $saved = delete $fake->{fields}{'res.users.apikeys'}{expiration_date};
    my $row   = act('action_odoo_status')->{scheduled}[0];
    is( $row->{expiry}, 'not-reported', 'said' );
    ok( !defined $row->{expires}, 'no date' );
    $fake->{fields}{'res.users.apikeys'}{expiration_date} = $saved;
};

subtest 'no key, or a key that cannot be read' => sub {
    plan skip_all => 'root reads anything' if $> == 0;
    my ($file) = glob("$d/lazysite/odoo/keys/sched-*.key");
    chmod 0000, $file;
    my $s = act('action_odoo_status');
    chmod 0600, $file;
    ok( !defined $s->{scheduled}[0]{has_secret}, 'has_secret is null when the file cannot be opened' );
};

subtest 'the key is in no answer, record, audit or log' => sub {
    my $all = '';
    $all .= encode_json( act('action_odoo_status') );
    $all .= encode_json( act( 'action_odoo_calls', binding => 'nightly' ) );
    my ( $r, $log ) = timer('nightly');
    $all .= $log . encode_json($r);
    my $leaks = 0;
    require File::Find;
    File::Find::find( { no_chdir => 1, wanted => sub {
                return unless -f $_ && $_ !~ m{/odoo/keys/};
                open my $fh, '<', $_ or return;
                local $/;
                my $t = <$fh>;
                $leaks++ if defined $t && index( $t, $KEY ) >= 0;
            } }, $d );
    is( $leaks, 0, 'no file outside the key store holds it' );
    unlike( $all, qr/\Q$KEY\E/, 'nor any answer or log line' );
};

subtest 'a configured binding without its key is refused, not run as the connection user' => sub {
    unlink glob("$d/lazysite/odoo/keys/sched-*.key");
    my $before = scalar @{ $fake->calls };
    my ($r) = timer('nightly');
    ok( !$r->{ok}, 'not delivered' );
    is( scalar @{ $fake->calls }, $before, 'and nothing reached Odoo as anybody' );
    is( Lazysite::Odoo::read_calls()->[0]{kind}, 'no-key', 'the record says no-key' );
    is( act('action_odoo_status')->{scheduled}[0]{has_secret}, 0, 'has_secret is 0' );
};

subtest 'clearing' => sub {
    act( 'action_odoo_secret_set', $KEY, scheduled => 'nightly', login => 'sched-bot' );
    my $r = act( 'action_odoo_secret_clear', scheduled => 'nightly' );
    ok( $r->{ok}, 'cleared' );
    is( $r->{has_secret}, 0, 'has_secret 0' );
    is_deeply( act('action_odoo_status')->{scheduled}, [], 'gone from the status' );
    my ($t) = timer('nightly');
    ok( $t->{ok}, 'the binding runs again' );
    is( keys_sent()->[-1], 'k3y-for-tests', 'as the connection user' );
};

done_testing();
