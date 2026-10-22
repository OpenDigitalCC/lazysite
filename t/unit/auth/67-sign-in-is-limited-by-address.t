#!/usr/bin/perl
# SM1159 (L2, OOM agent 2026-10-17: "sign-in ... can be limited to address ranges per
# site"): lazysite.conf `signin_addresses` / `signin_addresses_deny` limit where a
# sign-in may be made from. The refusal is BEFORE the password is looked at and BEFORE
# Auth::LoginRate counts the attempt ("a refused address is not a rate"), with its own
# reason in the auth log and the audit, once an hour, and a plain sentence on the login
# page. Runs the real lazysite-auth.pl behind a trusted proxy: the peer is 127.0.0.1
# and the visitor is whatever X-Forwarded-For says.
use strict;
use warnings;
use Test::More;
use DB_File;
use Fcntl qw(O_RDWR);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root env_passthrough run_child);
use ManagerSession qw(new_site);
use RateWindow     qw(stay_in_one_window);

my $root = repo_root();
my ( $IN, $OUT ) = ( '203.0.113.9', '198.51.100.9' );
my $PW = 'pw123456789-long-enough';

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }

my $s = new_site( root => $root );
my $d = $s->docroot;
$s->add_user( 'alice', $PW );
$s->users( 'address-list-set', 'office',  '--kind', 'allow', '--entry', '203.0.113.0/24' );
$s->users( 'address-list-set', 'blocked', '--kind', 'deny',  '--entry', $IN );

sub set_conf {
    my (%k) = @_;
    spit( "$d/lazysite/lazysite.conf",
        "site_name: S\nauth_redirect: /login\ntrusted_proxies: 127.0.0.1\nplugins:\n  - plugins/login-rate-limit.pl\n"
            . join( '', map { "$_: $k{$_}\n" } sort keys %k ) );
}

# One sign-in through the real CGI. %o: peer (REMOTE_ADDR), via (X-Forwarded-For).
sub login {
    my ( $user, $pass, %o ) = @_;
    my $body = "username=$user&password=$pass&next=/";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => $o{peer} // '127.0.0.1',
        ( defined $o{via} ? ( HTTP_X_FORWARDED_FOR => $o{via} ) : () ),
    );
    my $out = run_child( [ $^X, "$root/lazysite-auth.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    return $out;
}

# What the rate limiter holds for an address in this window.
sub counted {
    my ($addr) = @_;
    my %db;
    tie %db, 'DB_File', "$d/lazysite/auth/.login-rate.db", O_RDWR, 0o600 or return 0;
    my $v = $db{ "$addr:" . int( time() / 300 ) } // 0;
    untie %db;
    return $v;
}

sub audit_rows { return scalar( () = slurp("$d/lazysite/logs/audit.log") =~ /\| address-refused \| signin \|/g ) }

stay_in_one_window( 300, 10 );

subtest 'no limit set: sign-in is as before' => sub {
    set_conf();
    my $out = login( 'alice', $PW, via => $OUT );
    like( $out, qr/Set-Cookie: \S*=/, 'a right password signs in' );
    unlike( $out, qr/error=address/, 'no address refusal' );
};

subtest 'outside the allow list: refused before the password and before the rate counter' => sub {
    set_conf( signin_addresses => 'office' );
    my $before = counted($OUT);
    my $out    = login( 'alice', $PW, via => $OUT );    # the RIGHT password
    like( $out, qr{Location:[^\n]*error=address}, 'refused with its own reason' );
    unlike( $out, qr/Set-Cookie:/, 'and no session, though the password was right' );
    is( counted($OUT), $before, 'the rate limiter counted nothing: a refused address is not a rate' );
    for ( 1 .. 7 ) { login( 'alice', 'wrong', via => $OUT ) }
    unlike( login( 'alice', 'wrong', via => $OUT ), qr/error=rate/, 'however often it tries it is never rate-limited' );
    is( counted($OUT), $before, '...and still nothing counted' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/\| login \|[^\n]*\| fail \|[^\n]*address-refused/, 'the auth audit carries the reason' );
};

subtest 'inside the allow list: the password is checked as ever and counted' => sub {
    set_conf( signin_addresses => 'office' );
    my $c0  = counted($IN);
    my $bad = login( 'alice', 'wrong', via => $IN );
    like( $bad, qr{Location:[^\n]*error=1\b}, 'a wrong password is a credential failure' );
    is( counted($IN), $c0 + 1, '...and counted' );
    like( login( 'alice', $PW, via => $IN ), qr/Set-Cookie: \S*=/, 'a right one signs in' );
};

subtest 'deny wins, and a deny list alone refuses only its addresses' => sub {
    set_conf( signin_addresses => 'office', signin_addresses_deny => 'blocked' );
    like( login( 'alice', $PW, via => $IN ), qr/error=address/, 'inside the allow list and in the deny list: refused' );
    set_conf( signin_addresses_deny => 'blocked' );
    like( login( 'alice', $PW, via => $IN ),  qr/error=address/,   'a deny list alone refuses its address' );
    like( login( 'alice', $PW, via => $OUT ), qr/Set-Cookie: \S*=/, '...and admits everyone else' );
};

subtest 'behind a trusted proxy the trusted address is used; an untrusted X-Forwarded-For is ignored' => sub {
    set_conf( signin_addresses => 'office' );
    like( login( 'alice', $PW, peer => '127.0.0.1', via => $IN ), qr/Set-Cookie: \S*=/, 'the proxy vouches for an inside visitor: in' );
    like( login( 'alice', $PW, peer => '127.0.0.1', via => $OUT ), qr/error=address/, 'and for an outside one: out' );
    # The peer is a stranger outside trusted_proxies claiming to be inside.
    like( login( 'alice', $PW, peer => $OUT, via => $IN ), qr/error=address/,
        'an untrusted peer claiming an inside address through X-Forwarded-For is still outside' );
    like( login( 'alice', $PW, peer => $IN ), qr/Set-Cookie: \S*=/, 'a direct inside peer is in' );
};

subtest 'audit: one row per address per hour' => sub {
    set_conf( signin_addresses => 'office' );
    unlink "$d/lazysite/auth/.address-refused.db";
    my $n0 = audit_rows();
    login( 'alice', $PW, via => '198.51.100.77' ) for 1 .. 3;
    is( audit_rows() - $n0, 1, 'three refusals from one address in an hour write one `address-refused signin` row' );
    login( 'alice', $PW, via => '198.51.100.78' );
    is( audit_rows() - $n0, 2, 'another address writes its own' );
};

subtest 'a store that cannot be read refuses (fails closed)' => sub {
    set_conf( signin_addresses => 'office' );
    my $good = slurp("$d/lazysite/auth/address-lists.json");
    spit( "$d/lazysite/auth/address-lists.json", 'not json' );
    like( login( 'alice', $PW, via => $IN ), qr/error=address/, 'a faulted store never quietly admits' );
    spit( "$d/lazysite/auth/address-lists.json", $good );
};

subtest 'the login page says it plainly' => sub {
    my $page = slurp("$root/starter/lazysite/templates/system/login.md");
    like( $page, qr/query\.error == 'address'.*?Sign-in is not available from your address\./s, 'the sentence is on the page' );
};

subtest 'the Config keys: real lists of the right kind, cookie only, and not one that shuts the setter out' => sub {
    require Lazysite::Manager::Config;
    my $set = sub {
        my ( $k, $v ) = @_;
        return $s->call( 'alice', 'config-set', body => { key => $k, value => $v }, query => 'action=config-set' );
    };
    $s->grant( 'alice', 'g-ops', [qw(ui api manage_config)], [qw(ui api manage_config)] );
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = $IN;
    set_conf();
    my $r = $set->( 'signin_addresses', 'nope' );
    ok( !$r->{ok}, 'an unknown list is refused' );
    $r = $set->( 'signin_addresses', 'blocked' );
    ok( !$r->{ok}, 'a deny list in the allow slot is refused' );
    $r = $set->( 'signin_addresses_deny', 'blocked' );
    ok( !$r->{ok}, 'a deny list holding the setter\'s own address is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/shut your own address out of signing in/, '...saying why' );
    $r = $set->( 'signin_addresses', 'office' );
    ok( $r->{ok}, 'an allow list that holds the setter is accepted' ) or diag explain $r;
    like( slurp("$d/lazysite/lazysite.conf"), qr/^signin_addresses:\s*office$/m, '...and is in lazysite.conf' );
    $r = $set->( 'signin_addresses', '' );
    ok( $r->{ok}, 'and clears' );
};

done_testing();
