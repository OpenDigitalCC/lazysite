#!/usr/bin/perl
# SM1203 (release manager, 2026-10-20: "do the visitor-log follow-up in 0.15.13"):
# SM1197's worker re-fetches each page in app_offline_pages behind every view of
# it, and at install. That second request reached the engine like a page view and
# was recorded as one, in the browser's own User-Agent, so each such page counted
# twice in the visitor numbers.
#
# The worker's keeping fetch now sends `X-Lazysite-App: keep`. The recorder
# (lazysite-processor/access-log.pm) puts a request carrying it on its own
# channel, `app`, as it puts a registry fetch on `registry`: recorded, not
# dropped, and not a page. It changes nothing else - the rendered page, the
# cached copy and the status are the same with the header and without it.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor setup_test_site site_tempdir);

my $UA = 'Mozilla/5.0 (X11; Linux) TestBrowser';

sub site {
    my $d = site_tempdir();
    setup_test_site($d);
    open my $o, '>', "$d/portal.md" or die $!;
    print {$o} "---\ntitle: Portal\n---\nPORTAL-BODY\n";
    close $o;
    return $d;
}

sub log_lines {
    my ($d) = @_;
    my @l;
    for my $f ( glob "$d/lazysite/logs/access-*.jsonl" ) {
        open my $fh, '<', $f or next;
        push @l, map { eval { decode_json($_) } || () } <$fh>;
        close $fh;
    }
    return @l;
}

sub visit {
    my ( $d, $uri, %env ) = @_;
    return run_processor( $d, $uri, REMOTE_ADDR => '198.51.100.7', HTTP_USER_AGENT => $UA, %env );
}

my $d = site();
my $plain = visit( $d, '/portal' );
like( $plain, qr/PORTAL-BODY/, 'the page renders' );
my @l = log_lines($d);
is( scalar @l, 1, 'a visit leaves one line' );
is( $l[0]{ch}, 'page', 'on the page channel, which the visitor analysis counts as a visit' );
like( $l[0]{ua}, qr/TestBrowser/, 'under the browser User-Agent that classifies it unattributed' );

# the worker's keeping fetch: the same page, the same browser, the header
my $e = site();
my $kept = visit( $e, '/portal', HTTP_X_LAZYSITE_APP => 'keep' );
my @k = log_lines($e);
is( scalar @k, 1, 'the keeping fetch is recorded, not dropped' );
is( $k[0]{ch}, 'app', 'on its own channel, so it is not counted as a visit' );
is( $k[0]{s},  200,   'with its status' );
is( $k[0]{p},  '/portal', 'and its path' );

# and it changes nothing about the response
my $again = visit( $e, '/portal' );    # the cached copy the keeping fetch made
my $fresh = visit( $d, '/portal' );    # served from the copy a plain visit made
for ( $plain, $kept, $again, $fresh ) { s/^Date:.*\r?\n//mg }
is( $kept,  $plain, 'the response to the keeping fetch is the response to a visit, head and body' );
is( $again, $plain, 'the copy it cached answers a visit with the same page' );
@k = log_lines($e);
is_deeply( [ map { $_->{ch} } @k ], [ 'app', 'page' ], 'and that visit, after it, is counted as one' );
ok( $k[1]{c}, 'served from the cache the keeping fetch filled: the key does not vary on the header' );

# only the value `keep`, and only a page: nothing else is moved
my $o = site();
visit( $o, '/portal', HTTP_X_LAZYSITE_APP => 'something-else' );
visit( $o, '/portal', HTTP_X_LAZYSITE_APP => '' );
is_deeply( [ map { $_->{ch} } log_lines($o) ], [ 'page', 'page' ], 'any other value is an ordinary visit' );

my $m = site();
visit( $m, '/portal', HTTP_X_LAZYSITE_APP => 'keep', LAZYSITE_PREVIEW => 1 );
is( scalar( log_lines($m) ), 0, 'a preview is still no visit, with or without the header' );

done_testing();
