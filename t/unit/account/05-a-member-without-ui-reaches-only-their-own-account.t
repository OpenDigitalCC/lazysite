#!/usr/bin/perl
# SM1043 x SM1057: the manager API's cookie door needs `ui` (SM1057), and the
# member /account is for holds none. The actions declared `self` - the member's
# own account, acting on the caller alone - pass that gate; every other cookie
# action is still refused 403, `save` included. The exemption is the
# declaration's (Lazysite::ControlApi::Actions::self_actions), so this test
# walks the declaration rather than a list of its own.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_processor run_child);
use Lazysite::ControlApi::Actions ();

my $root       = repo_root();
my $utl        = "$root/tools/lazysite-users.pl";
my $mapi       = "$root/lazysite-manager-api.pl";
my $secret     = 'sm1043-noui-secret-' x 3;
my $PW         = 'member-first-password';
my $SID        = 'a' x 16;
my $UI_REFUSAL = qr/does not have manager access/;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# One request as the signed-in member (no group, so no `ui`). Returns
# ( status, decoded body ).
sub api {
    my ( $d, $action, $body ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => ( $post ? 'POST' : 'GET' ),
        QUERY_STRING   => "action=$action",
        CONTENT_LENGTH => length($json),
        REMOTE_ADDR    => '192.0.2.50',
        HTTP_X_REMOTE_USER => 'member', HTTP_X_REMOTE_GROUPS => '', LAZYSITE_AUTH_TRUSTED => 1,
        LAZYSITE_AUTH_SID => $SID,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf('member') ) : () ),
    );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($status) = ( $out // '' ) =~ /^Status:\s*(\d+)/m;
    my ($jb)     = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 200, eval { decode_json( $jb // '' ) } // { _raw => $out } );
}

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
}
uapi( $d, { action => 'add', username => 'member', password => $PW } );
uapi( $d, { action => 'add', username => 'sysop',  password => 'sysop-first-password' } );
uapi( $d, { action => 'group-add', username => 'sysop', group => 'sysops' } );
{
    open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
    print $rf encode_json( { sid => $SID, user => 'member', t => time() - 60, ip => '', ua => '' } ) . "\n";
    close $rf;
}

my %A    = %Lazysite::ControlApi::Actions::ACTION;
my %SELF = Lazysite::ControlApi::Actions::self_actions();
my %MUT  = Lazysite::ControlApi::Actions::mutating();
ok( scalar keys %SELF >= 5, 'the declaration names the self actions' );

# --- every self action passes the `ui` gate ----------------------------------------
my %BODY = (
    'me-password' => { current_password => $PW, new_password => 'member-second-password' },
    'me-session-revoke' => { sid => 'f' x 16 },
);
for my $a ( sort grep { $_ ne 'me-sign-out-everywhere' && $_ ne 'me-password' } keys %SELF ) {
    my ( $st, $r ) = api( $d, $a, $MUT{$a} ? ( $BODY{$a} // {} ) : undef );
    unlike( $r->{error} // '', $UI_REFUSAL, "$a: a member without ui passes the manager door" );
}
{
    my ( $st, $r ) = api( $d, 'me' );
    ok( $r->{ok}, 'me: answers the member' ) or diag explain $r;
    ( $st, $r ) = api( $d, 'me-sessions' );
    ok( $r->{ok}, 'me-sessions: answers the member' );
    ( $st, $r ) = api( $d, 'me-password', $BODY{'me-password'} );
    ok( $r->{ok}, 'me-password: the member changes their own password' ) or diag explain $r;
    ( $st, $r ) = api( $d, 'me-sign-out-everywhere', {} );
    ok( $r->{ok}, 'me-sign-out-everywhere: the member signs themselves out' );
}

# --- every other action is refused 403, save included -----------------------------
my %ANSWERED_BEFORE_THE_GATE = (
    'csrf-token' => 'minted for any signed-in caller before any gate (needed by every POST, the self actions\' too)',
);
my @refused_wrong;
for my $a ( sort grep { !$SELF{$_} && !$ANSWERED_BEFORE_THE_GATE{$_} } keys %A ) {
    my ( $st, $r ) = api( $d, $a, $MUT{$a} ? {} : undef );
    push @refused_wrong, "$a ($st " . ( $r->{error} // $r->{_raw} // '' ) . ')'
        unless $st == 403 && ( $r->{error} // '' ) =~ $UI_REFUSAL;
}
is_deeply( \@refused_wrong, [], 'every non-self action is refused 403 at the manager door for a member without ui' )
    or diag join "\n", @refused_wrong;
{
    my ( $st, $r ) = api( $d, 'save&path=index.md', { content => "---\ntitle: X\n---\nmine\n" } );
    is( $st, 403, 'save: refused 403' );
    like( $r->{error} // '', $UI_REFUSAL, 'save: by the manager door' );
    ok( !-e "$d/index.md", 'save: nothing was written' );
}

# --- /account renders for the member -------------------------------------------------
{
    my $site = site_tempdir();
    system( 'cp', '-r', "$root/starter/.", $site ) == 0 or die 'copy starter';
    make_path("$site/lazysite/cache");
    open my $cf, '>', "$site/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    my $out = run_processor( $site, '/account', HTTP_X_REMOTE_USER => 'member',
        HTTP_X_REMOTE_GROUPS => '', LAZYSITE_AUTH_TRUSTED => 1 );
    like( $out, qr/data-ls-account="password"/, '/account renders for a member without ui' );
}

done_testing;
