#!/usr/bin/perl
# SM747 B: a binding with `credential: session` runs as the person who signed in
# to Odoo through the page - their own session, replayed on each call - and as
# nobody else. Tested through OOM's REAL session transport over a stand-in for
# HTTP, with the connection user's own (separate) fake Odoo beside it so that
# what ran as whom can be read off what each was asked.
#
#   * the shape: authenticated mode only, no callers, no visitor key;
#   * with a session it runs, the session carried as a cookie and never in a
#     URL, and the connection user's key is not needed and not used;
#   * WITHOUT a session it is refused and the connection user is NEVER asked -
#     no fallback to the (likely wider) account;
#   * a session that Odoo has ended is a sign-in to make again, the cookie is
#     to be cleared, and the connection user is still never asked;
#   * no other door runs one: not the control API or MCP, not a form, not the
#     schedule, not a page render (a page render is shared and cached);
#   * a session never changes what a connection binding runs as;
#   * a plan is the session's: another person's session cannot confirm it;
#   * a record names the session by a hash, never by the id.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();
use Lazysite::Handlers      ();

my ( $d, $conn_fake ) = shop_ready();    # the CONNECTION user's Odoo
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
my $PW          = 'a-long-enough-Password-77';
my $person_fake = fake_shop();                 # what the PERSON reaches, over the session
my $http        = OdooSessionHTTP->new( fake => $person_fake, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
        'tom@example.com' => { password => $PW, uid => 9, name => 'Tom', login => 'tom@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;    # the connection user's, as always

bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );
bind( $d, id => 'my-add', operation => 'shop.add', credential => 'session', modes => 'authenticated',
    params => 'product=product', fixed => 'basket_key=mine' );
bind( $d, id => 'shared', operation => 'shop.products', modes => 'public, authenticated', callers => 'staff' );
load_processor($d);
$Lazysite::Odoo::TRANSPORT = $conn_fake;

sub sign_in_as {
    my ($login) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::sign_in( login => $login, password => $PW, ip => '192.0.2.7' ) } );
    my $sid = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $r->{cookie} );
    return $sid;
}
my $JANE = sign_in_as('jane@example.com');
my $TOM  = sign_in_as('tom@example.com');
ok( $JANE && $TOM && $JANE ne $TOM, 'two people signed in' );

sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, mode => 'authenticated', ip => '192.0.2.7', %ctx );
    } );
    return $r;
}
sub conn_calls   { return scalar @{ $conn_fake->calls } }
sub person_posts { return scalar grep { $_->{path} =~ m{call_kw} } @{ $http->posts } }

subtest 'the shape of a session binding' => sub {
    require Lazysite::Odoo::Binding;
    my %h = ( id => 'x', operation => 'shop.products', credential => 'session', modes => 'authenticated' );
    my ($b) = Lazysite::Odoo::Binding::parse( {%h} );
    is( $b->{credential}, 'session', 'a session binding' );
    my ($c) = Lazysite::Odoo::Binding::parse( { id => 'y', operation => 'shop.products' } );
    is( $c->{credential}, 'connection', 'the default is the connection user' );
    my ( $u, $why ) = Lazysite::Odoo::Binding::parse( { %h, modes => 'authenticated, public' } );
    like( $why, qr/public and scheduled have no such person/, 'public is refused' );
    ( $u, $why ) = Lazysite::Odoo::Binding::parse( { %h, modes => 'scheduled' } );
    like( $why, qr/no such person/, 'the schedule is refused' );
    ( $u, $why ) = Lazysite::Odoo::Binding::parse( { %h, callers => 'staff' } );
    like( $why, qr/takes no callers/, 'callers are refused: Odoo decides' );
    ( $u, $why ) = Lazysite::Odoo::Binding::parse( { %h, visitor_param => 'k' } );
    like( $why, qr/no visitor key/, 'a visitor key is refused' );
    ( $u, $why ) = Lazysite::Odoo::Binding::parse( { %h, credential => 'master' } );
    like( $why, qr/credential must be connection or session/, 'nothing else is a credential' );
};

subtest 'with a sign-in it runs as the person, by cookie, with no key' => sub {
    require Lazysite::Odoo::Secret;
    {
        no warnings 'once';
        local $Lazysite::Odoo::Secret::DOCROOT = $d;
        Lazysite::Odoo::Secret::clear_key('connection');
        ok( !Lazysite::Odoo::Secret::has_key('connection'), 'the connection user has NO key at all' );
    }
    my $c0 = conn_calls();
    my $r  = run_b( 'mine', {}, odoo_session => $JANE );
    ok( $r->{ok}, 'it runs' ) or diag explain $r;
    is( scalar @{ $r->{report}{rows} }, 2,   'with Odoo\'s rows' );
    is( conn_calls(),                   $c0, 'the connection user was not asked' );
    my @posts = grep { $_->{path} =~ m{call_kw} } @{ $http->posts };
    ok( scalar @posts, 'the person\'s session was' );
    is( scalar( grep { $_->{cookie} ne "session_id=$JANE" } @posts ), 0, 'every call carried her session as the cookie' );
    is( scalar( grep { index( $_->{url}, $JANE ) >= 0 } @{ $http->posts } ), 0, 'and her session is in no URL' );
    my @recs = grep { $_->{binding} eq 'mine' } @{ Lazysite::Odoo::read_calls() };
    like( $recs[0]{actor}, qr/\Asession:[0-9a-f]{16}\z/, 'the record names her session by a hash' );
    is( $recs[0]{actor}, Lazysite::Odoo::Session::session_label($JANE), '...her own' );
    unlike( encode_json( Lazysite::Odoo::read_calls() ), qr/\Q$JANE\E/, 'and the record holds no session id' );
    require Lazysite::Odoo::Secret;
    {
        no warnings 'once';
        local $Lazysite::Odoo::Secret::DOCROOT = $d;
        Lazysite::Odoo::Secret::set_key( 'connection', 'k3y-for-tests' );
    }
};

subtest 'without a sign-in it is refused and the connection user is never asked' => sub {
    my ( $c0, $p0 ) = ( conn_calls(), scalar @{ $http->posts } );
    my $r = run_b('mine');
    is( $r->{kind}, 'signin-required', 'refused: sign in' );
    like( $r->{error}, qr/signed in to Odoo/, 'in words' );
    is( conn_calls(),             $c0, 'NOT run as the connection user' );
    is( scalar @{ $http->posts }, $p0, 'and nothing was sent to Odoo at all' );
    $r = run_b( 'mine', {}, odoo_session => '' );
    is( $r->{kind}, 'signin-required', 'an empty session is none' );
    $r = run_b( 'mine', {}, mode => 'public', groups => ['staff'], caps => { manage_connectors => 1 } );
    is( $r->{kind},   'signin-required', 'the override capability is not a sign-in' );
    is( conn_calls(), $c0,               'still never the connection user' );
};

subtest 'a session Odoo has ended is a sign-in to make again, never a fall back' => sub {
    my $sid = sign_in_as('jane@example.com');
    ok( run_b( 'mine', {}, odoo_session => $sid )->{ok}, 'live' );
    $http->expire($sid);
    my $c0 = conn_calls();
    my $r  = run_b( 'mine', {}, odoo_session => $sid );
    is( $r->{kind}, 'signin-required', 'refused: sign in again' );
    ok( $r->{clear_session}, 'and the cookie is to be cleared' );
    like( $r->{error}, qr/sign-in has ended/, 'in words' );
    is( conn_calls(), $c0, 'the connection user was not asked instead' );
    my @recs = grep { $_->{binding} eq 'mine' } @{ Lazysite::Odoo::read_calls() };
    is( $recs[0]{outcome}, 'odoo-fault', 'and the record says Odoo said so' );
};

subtest 'no other door runs it' => sub {
    my $c0 = conn_calls();
    my %SAM = ( user => 'sam', groups => ['staff'], caps => { manage_connectors => 1 }, ip => '192.0.2.5', channel => 'mcp' );
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::action_odoo_run( 'mine', {}, %SAM ) } );
    is( $r->{kind}, 'signin-required', 'the control API / MCP: refused, even for manage_connectors' );
    ( undef, $r ) = quiet( sub { Lazysite::Odoo::action_odoo_bindings(%SAM) } );
    ok( !( grep { $_->{id} eq 'mine' } @{ $r->{bindings} } ), 'and it is not even listed' );
    ok( ( grep { $_->{id} eq 'shared' } @{ $r->{bindings} } ), '(the connection binding is)' );
    {
        no warnings 'once';
        local $Lazysite::Handlers::DOCROOT = $d;
        ( undef, $r ) = quiet( sub { Lazysite::Handlers::deliver( 'mine', {}, source => 'form:x', origin => 'form' ) } );
        ok( !$r->{ok}, 'a form: refused' );
        like( $r->{why} // '', qr/only the Odoo page endpoint carries/, 'saying why: that door is not this one' );
        ( undef, $r ) = quiet( sub { Lazysite::Handlers::deliver( 'mine', {}, source => 'schedule', origin => 'timer' ) } );
        ok( !$r->{ok}, 'the schedule: refused' );
    }
    my ( $log, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:mine' } ) } );
    is( $v{x}, '', 'a page render: nothing' );
    like( $log, qr/runs as a person signed in to Odoo.*shared and cached/, 'and the log says it is shared and cached' );
    is( conn_calls(), $c0, 'the connection user was asked by none of them' );
};

subtest 'a session never changes what a connection binding runs as' => sub {
    my $c0 = conn_calls();
    my $r = run_b( 'shared', {}, odoo_session => $JANE, groups => ['staff'], actor => 'sam' );
    ok( $r->{ok},           'a connection binding runs' ) or diag explain $r;
    ok( conn_calls() > $c0, 'as the connection user' );
    my @recs = grep { $_->{binding} eq 'shared' } @{ Lazysite::Odoo::read_calls() };
    is( $recs[0]{actor}, 'sam', 'recorded as the account, not as a session' );
};

subtest 'a plan made by a session is that session\'s' => sub {
    my $p = run_b( 'my-add', { product => 1 }, odoo_session => $JANE );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my ( undef, $other ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', odoo_session => $TOM ) } );
    is( $other->{kind}, 'not-found', 'another person\'s session cannot confirm it' );
    ( undef, $other ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', actor => 'sam', groups => ['staff'] ) } );
    is( $other->{kind}, 'not-found', 'nor an account with no session' );
    is( scalar @{ $person_fake->all_ids('x.basket') }, 0, 'nothing was written' );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', odoo_session => $JANE ) } );
    ok( $c->{applied}, 'hers applies it' ) or diag explain $c;
    is( scalar @{ $person_fake->all_ids('x.basket') }, 1, 'in Odoo, over her session' );
    is( scalar @{ $conn_fake->all_ids('x.basket') }, 0, 'and not through the connection user' );
    my $run = do {
        open my $fh, '<', Lazysite::Odoo::plans_dir() . "/$p->{plan}/run.json" or die $!;
        local $/;
        JSON::PP::decode_json(<$fh>);
    };
    is( $run->{approval}{by}, Lazysite::Odoo::Session::session_label($JANE), 'approved by her session, by its hash' );
};

subtest 'the connection user\'s plan is not a session\'s to confirm' => sub {
    bind( $d, id => 'c-add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
        params => 'product=product', fixed => 'basket_key=c' );
    my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
    my ( undef, $p ) = quiet( sub { Lazysite::Odoo::action_odoo_run( 'c-add', { product => 2 }, %SAM ) } );
    ok( $p->{planned}, 'a plan by an account' );
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', odoo_session => $JANE ) } );
    is( $r->{kind}, 'not-found', 'a session confirms none of it' );
};

subtest 'a binding changed between its plan and the confirm does not change whose plan it is' => sub {
    bind( $d, id => 'flip', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
        params => 'product=product', fixed => 'basket_key=f' );
    my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
    my ( undef, $p ) = quiet( sub { Lazysite::Odoo::action_odoo_run( 'flip', { product => 1 }, %SAM ) } );
    ok( $p->{planned}, 'a plan by an account, on a connection binding' ) or diag explain $p;
    bind( $d, id => 'flip', operation => 'shop.add', credential => 'session', modes => 'authenticated',
        params => 'product=product', fixed => 'basket_key=f' );
    my ( undef, $r ) = quiet( sub {
            Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', actor => 'sam', groups => ['staff'], odoo_session => $JANE );
    } );
    is( $r->{kind}, 'not-found', 'the binding is now a session binding: the account\'s plan is not any session\'s' );
    is( scalar @{ $person_fake->all_ids('x.basket') }, 1, 'nothing more was written' );
};

done_testing();
