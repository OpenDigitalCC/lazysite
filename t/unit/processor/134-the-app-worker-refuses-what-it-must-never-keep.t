#!/usr/bin/perl
# SM1155 (L1's constraints, non-negotiable): the generated service worker never
# touches the Odoo endpoint, the manager, the auth endpoints or any page, never
# stores a response that says no-store or private (and drops a copy it kept
# before), and updates itself on a deploy.
#
# The worker the processor generates is driven in node through
# t/lib/app-worker-harness.js with stand-ins for the cache, fetch and the
# events, as t/unit/odoo/31 drives the Odoo helper. The source is also held to
# the things a reviewer would read for: no cookie, no token, no sync, no push.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site run_processor);

my $root = repo_root();
my $d    = site_tempdir();
setup_test_site($d);
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "app_name: Pocket Portal\n";
close $cf;

my $out = run_processor( $d, '/lazysite-sw.js' );
my ( $head, $js ) = split /\r?\n\r?\n/, $out, 2;
like( $head, qr{Content-Type: text/javascript}i, 'the worker is generated' ) or BAIL_OUT('no worker');
my $file = "$d/sw.js";
open my $o, '>', $file or die $!;
print {$o} $js;
close $o;

subtest 'the source holds no cookie, token, sync or push, and no hand-written config' => sub {
    ( my $code = $js ) =~ s{/\*.*?\*/}{}gs;
    for my $bad (qw(document.cookie Set-Cookie 'cookie' "cookie" localStorage indexedDB sync periodicSync PushManager showNotification importScripts XMLHttpRequest)) {
        ok( index( $code, $bad ) < 0, "no $bad" );
    }
    unlike( $code, qr{\beval\b}, 'no eval' );
    unlike( $code, qr/\bcsrf|visitor_token|authorization/i, 'no token or credential is named' );
    unlike( $js, qr/__CONFIG__/, 'the config is filled in' );
};

my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
SKIP: {
    skip 'node is not installed', 6 unless length $node && -x $node;

    my $err = `$node --check "$file" 2>&1`;
    is( $?, 0, 'it parses' ) or diag $err;

    my $res = `$node "$root/t/lib/app-worker-harness.js" "$file" 2>&1`;
    my $f   = eval { decode_json($res) };
    ok( $f && !$f->{error}, 'the behaviour harness ran' ) or BAIL_OUT("harness: $res");

    subtest 'the routing table refuses the Odoo endpoint, the manager, the auth endpoints and every page' => sub {
        my $a = $f->{answered};
        for my $k ( sort keys %{$a} ) { ok( !$a->{$k}, "not answered: $k" ) }
        is( $f->{fetched_when_refused}, 0, 'and nothing was fetched on their behalf' );
        is_deeply( $f->{held_when_refused}, [], 'or kept' );
        ok( $f->{answers}{$_}, "answers a $_" ) for qw(script style image);
    };

    subtest 'a response that says no-store or private is never stored' => sub {
        is_deeply(
            $f->{kept},
            [ '/assets/ok.js', '/assets/pub.js', '/i/ok.png' ],
            'only whole 200s with no no-store or private: not a 404, a 206, an opaque one, Vary: *, or either directive'
        );
        is_deeply( $f->{flip}{before}, ['/assets/flip.js'], 'a public file is kept' );
        is( $f->{flip}{second_body}, 'public', 'served from the device while it is revalidated' );
        is_deeply( $f->{flip}{after_second}, [], 'and once it answers no-store, the copy is deleted' );
        is( $f->{flip}{third_body}, 'secret', 'so the next request goes to the server' );
    };

    subtest 'scripts and styles are stale-while-revalidate, images cache-first' => sub {
        is_deeply( [ @{ $f->{swr} }{qw(first second third)} ], [ 'v1', 'v1', 'v2' ], 'the stored copy answers and the next is the revalidated one' );
        is_deeply( $f->{image}{bodies}, [ ('png1') x 3 ], 'an image is fetched once' );
        is( $f->{image}{fetches}, 1, 'and never again' );
    };

    subtest 'install precaches the shell; activate drops only older worker caches' => sub {
        ok( $f->{install}{fetched_shell}, 'every shell file was fetched' );
        is( $f->{install}{skip_waiting}, 1, 'and the worker takes over at once' );
        my @held = @{ $f->{install}{held} };
        is( scalar(@held), scalar( @{ $f->{install}{shell} } ) - 1, 'the shell file that said no-store was not kept' );
        is_deeply( $f->{activate}{caches}, [ $f->{activate}{current}, 'someone-elses-cache' ], 'older lazysite-app caches go, others stay' );
        is( $f->{activate}{claim}, 1, 'open pages are claimed' );
    };
}

done_testing();
