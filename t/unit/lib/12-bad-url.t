#!/usr/bin/perl
# SM128: the bad-URL auto-blocker core (Lazysite::BadUrl) - probe detection, the
# rolling-window per-IP counter, blocking at threshold, and unblock.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";      # t/lib
use lib "$FindBin::Bin/../../../lib";   # repo lib
use Lazysite::BadUrl qw(is_bad_url is_blocked record_and_check list_blocks block unblock);

# --- detection --------------------------------------------------------------
ok( is_bad_url('/wp-login.php'),        'wp-login.php is a probe' );
ok( is_bad_url('/.env'),                '.env is a probe' );
ok( is_bad_url('/.git/config'),         '.git is a probe' );
ok( is_bad_url('/a/b/shell.php'),       'any .php is a probe (no PHP on a lazysite site)' );
ok( is_bad_url('/actuator/health'),     'actuator is a probe' );
ok( !is_bad_url('/about'),              'a normal page is not a probe' );
ok( !is_bad_url('/blog/my-post'),       'a normal nested page is not a probe' );
ok( !is_bad_url(''),                    'empty path is not a probe' );
ok(  is_bad_url('/secret-scan', ['/secret-scan']), 'operator extra pattern matches' );
ok( !is_bad_url('/legit', ['/secret-scan']),       'extra pattern does not over-match' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/cache");

# --- count then block -------------------------------------------------------
ok( !is_blocked( $d, '9.9.9.9' ), 'IP not blocked initially (no store)' );
my $blocked;
for my $i ( 1 .. 4 ) {
    $blocked = record_and_check( $d, '9.9.9.9', '/.env', threshold => 5, window => 3600 );
    is( $blocked, 0, "hit $i of 5: not yet blocked" );
}
$blocked = record_and_check( $d, '9.9.9.9', '/.env', threshold => 5, window => 3600 );
is( $blocked, 1, 'hit 5 of 5: blocked' );
ok( is_blocked( $d, '9.9.9.9' ), 'is_blocked reflects the block' );
ok( !is_blocked( $d, '8.8.8.8' ), 'a different IP is not blocked' );
is( list_blocks($d)->{'9.9.9.9'}{count}, 5, 'list_blocks records the hit count' );

# --- window: stale hits do not accumulate -----------------------------------
my $now = 1_000_000_000;
for my $i ( 1 .. 4 ) {
    record_and_check( $d, '7.7.7.7', '/.git', threshold => 5, window => 100, now => $now );
}
# 200s later, the 4 earlier hits have aged out of the 100s window.
my $b2 = record_and_check( $d, '7.7.7.7', '/.git', threshold => 5, window => 100, now => $now + 200 );
is( $b2, 0, 'hits outside the rolling window do not count toward the threshold' );

# --- unblock ----------------------------------------------------------------
ok(  unblock( $d, '9.9.9.9' ),  'unblock removes the IP' );
ok( !is_blocked( $d, '9.9.9.9' ), 'IP no longer blocked after unblock' );
ok( !unblock( $d, '9.9.9.9' ),  'unblocking an absent IP is a no-op (false)' );

# --- a hand block says WHO, and the API writes a trail ----------------------
# SM704 added blocking by hand. An automatic block is explained by the hits
# that caused it; a hand block has no such record, so the row carries the
# account that made it - the question an operator asks about a blocked address
# is "who blocked this, and when". t/unit/lib/16 checks the ACTION is
# classified as one that must audit; this checks the two halves that make the
# answer possible.
{
    my $d2 = tempdir( CLEANUP => 1 );
    make_path("$d2/lazysite/cache");
    ok( block( $d2, '5.5.5.5', by => 'manager' ), 'an address can be blocked by hand' );
    ok( is_blocked( $d2, '5.5.5.5' ), 'and it is blocked' );
    my $rows = list_blocks($d2);
    is( $rows->{'5.5.5.5'}{by}, 'manager', 'the row records WHO blocked it' )
        or diag( 'Without it the trail says an address was blocked and the '
            . 'blocklist says nothing about who, so the two cannot be joined.' );
    ok( !block( $d2, '5.5.5.5', by => 'manager' ),
        'blocking an already-blocked address is a no-op, not an error' );
    ok( !block( $d2, 'not an address', by => 'manager' ),
        'and a pattern is not an address' )
        or diag( 'This value reaches a file the request path reads on every '
            . 'hit. A pattern here is a rule nobody wrote.' );

    # The API half: the dispatch that exposes this must write the trail entry.
    my $api = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($branch) = $api =~ /elsif \( \$action eq 'bad-url-block' \) \{(.*?)\nelsif /s;
    ok( defined $branch, 'the bad-url-block branch was found' );
    like( $branch, qr/log_event\(\s*'INFO',\s*'bad-url-block'/,
        'blocking an address by hand writes an audit entry' )
        or diag( 'Its sibling bad-url-unblock audits. A block that leaves no '
            . 'trace is the half of the pair an operator most needs to '
            . 'account for - somebody is being refused the site.' );
    like( $branch, qr/user\s*=>\s*\$auth_user/,
        'and the entry names the account that did it' );
}

# --- built-in patterns stay in sync with the stats noise set ----------------
my $stats = do { open my $f, '<', "$FindBin::Bin/../../../plugins/stats.pl"; local $/; <$f> };
for my $probe (qw(wp-login xmlrpc phpmyadmin actuator autodiscover)) {
    like( $stats, qr/\Q$probe\E/, "stats noise set still mentions '$probe' (keep BadUrl in sync)" );
}

done_testing();
