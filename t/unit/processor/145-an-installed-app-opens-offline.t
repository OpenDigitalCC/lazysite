#!/usr/bin/perl
# SM1197 (inbox 2026-10-19, "An installed app cannot open without a connection"):
# the generated worker kept the shell and never a page, so an installed app
# opened with no signal showed the browser's error. Three asks, all here:
#
#   1. app_offline_pages: the listed pages are kept network-first for offline use,
#      under the rules the worker already holds, and the engine lists only pages
#      that are the same for every visitor.
#   2. app_update: wait: a new worker does not take over until the page asks.
#   3. lazysite-app.js says why a registration failed.
#
# The worker the processor generates is driven in node through
# t/lib/app-offline-harness.js, the script through t/lib/app-register-harness.js.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site run_processor);

my $root = repo_root();

sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $o, '>', $path or die "$path: $!";
    print {$o} $text;
    close $o;
}

sub site {
    my ( $conf, %o ) = @_;
    my $d = site_tempdir();
    setup_test_site($d);
    open my $fh, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $conf;
    close $fh;
    put( "$d/assets/$_", "/* $_ */\n" ) for qw(lazysite-chrome.css lazysite-chrome.js lazysite-app.js);
    my %pages = (
        'portal/index.md' => "---\ntitle: Portal\n---\nPortal.\n",
        'portal/new.md' => "---\ntitle: New\ntt_page_var:\n  cats: odoo:expense-categories\n---\nNew.\n",
        'portal/other.md'    => "---\ntitle: Other\n---\nOther.\n",
        'portal/private.md'  => "---\ntitle: P\nauth: required\n---\nP.\n",
        'portal/optional.md' => "---\ntitle: O\nauth: optional\n---\nO.\n",
        'portal/groups.md'   => "---\ntitle: G\nauth_groups: [staff]\n---\nG.\n",
        'portal/paid.md'     => "---\ntitle: Paid\npayment: required\n---\nPaid.\n",
        'portal/office.md'   => "---\ntitle: Office\naddresses: [office]\n---\nO.\n",
        'portal/me.md' => "---\ntitle: Me\ntt_page_var:\n  me: odoo-identity:\n---\nMe.\n",
        'portal/mine.md' => "---\ntitle: Mine\ntt_page_var:\n  rows: db:notes(mine)\n---\nMine.\n",
        'portal/live.md'     => "---\ntitle: Live\nnocache: true\n---\nLive.\n",
        'portal/api.md'      => "---\ntitle: Api\napi: true\n---\n{}\n",
        'portal/acl/page.md' => "---\ntitle: Acl\n---\nAcl.\n",
        'portal/open.md'     => "---\ntitle: Open\nauth: none\n---\nOpen.\n",
        'outside/index.md'   => "---\ntitle: Outside\n---\nOutside.\n",
    );
    put( "$d/$_",                      $pages{$_} ) for keys %pages;
    put( "$d/lazysite/auth/acls.json", '{"portal/acl":{"read":["@staff"]}}' );
    return $d;
}

sub worker {
    my ($d) = @_;
    my $out = run_processor( $d, '/portal/lazysite-sw.js' );
    my ( $head, $js ) = split /\r?\n\r?\n/, $out, 2;
    return ( $head // '', $js // '' );
}

sub pages_of {
    my ($js)   = @_;
    my ($list) = $js =~ /"pages":(\[[^\]]*\])/;
    return $list ? decode_json($list) : undef;
}

my $BASE = "app_name: Pocket Portal\napp_scope: /portal/\napp_start_url: /portal/\n";
my $ASK  = join ', ', qw(/portal/ /portal/new /portal/open /portal/other);

subtest 'the worker lists the pages it was asked to keep' => sub {
    my $d = site( $BASE . "app_offline_pages: $ASK\n" );
    my ( $head, $js ) = worker($d);
    like( $head, qr{Content-Type: text/javascript}i, 'a worker is generated' );
    is_deeply( pages_of($js), [qw(/portal/ /portal/new /portal/open /portal/other)],
        'the listed pages, a page with an odoo: binding among them' );

    my $none = site($BASE);
    is_deeply( pages_of( ( worker($none) )[1] ), [], 'no setting, no pages' );

    # The cache name changes with the list, so a page taken off the list stops
    # being served from a copy kept earlier.
    # (Within one site: two sites differ in the shell files' times as well.)
    my ($c1)      = $js               =~ /"cache":"([^"]+)"/;
    my ($c1again) = ( worker($d) )[1] =~ /"cache":"([^"]+)"/;
    is( $c1again, $c1, 'the name is stable while nothing changes' );
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "app_offline_pages: /portal/\n";    # the later line wins
    close $cf;
    my ($c2) = ( worker($d) )[1] =~ /"cache":"([^"]+)"/;
    isnt( $c2, $c1, 'a different page list is a different cache' );
};

subtest 'the engine lists only what is the same for every visitor' => sub {
    my %refuse = (
        'a page that needs sign-in'                        => '/portal/private',
        'a page that may differ when signed in'            => '/portal/optional',
        'a page limited to a group'                        => '/portal/groups',
        'a paid page'                                      => '/portal/paid',
        'a page limited by address'                        => '/portal/office',
        'a page showing who the viewer is (odoo-identity)' => '/portal/me',
        'a page binding the viewer\'s own rows'            => '/portal/mine',
        'a page rendered fresh each time'                  => '/portal/live',
        'a data page (api: true)'                          => '/portal/api',
        'a page under an ACL read rule'                    => '/portal/acl/page',
        'a page outside the scope'                         => '/outside/',
        'a page that does not exist'                       => '/portal/missing',
        'the Odoo endpoint'                                => '/cgi-bin/lazysite-odoo.pl',
        'an endpoint under the scope'                      => '/portal/lazysite-auth.pl',
        'the engine tree'                                  => '/lazysite/cache/x',
        'a path with ..'                                   => '/portal/../private',
        'a path with a query'                              => '/portal/new?x=1',
    );
    for my $why ( sort keys %refuse ) {
        my $d = site( $BASE . "app_offline_pages: /portal/, $refuse{$why}\n" );
        is_deeply( pages_of( ( worker($d) )[1] ), ['/portal/'], "not listed: $why" );
    }

    # a site where everything is gated by default: only a page that says auth: none
    my $d = site( $BASE . "auth_default: required\napp_offline_pages: /portal/, /portal/open\n" );
    is_deeply( pages_of( ( worker($d) )[1] ), ['/portal/open'], 'auth_default: required keeps back every page that does not say auth: none' );

    # the manager path is the site's own
    my $m = site( $BASE . "manager_path: /portal/admin\napp_offline_pages: /portal/, /portal/admin/x\n" );
    put( "$m/portal/admin/x.md", "---\ntitle: X\n---\nX.\n" );
    is_deeply( pages_of( ( worker($m) )[1] ), ['/portal/'], 'the manager path configured for this site is never listed' );
};

subtest 'app_update: now is today, wait is declared, anything else turns the app off' => sub {
    my $d = site( $BASE . "app_offline_pages: /portal/\n" );
    my ( undef, $js ) = worker($d);
    like( $js, qr/"update":"now"/, 'the default is the behaviour SM1155 shipped' );
    my $w = site( $BASE . "app_update: wait\n" );
    like( ( worker($w) )[1], qr/"update":"wait"/, 'app_update: wait is in the worker' );
    my $bad = site( $BASE . "app_update: sometime\n" );
    like( ( worker($bad) )[0], qr/\b404\b/, 'a value that is neither turns the app off, not into a guess' );

    my $pg = run_processor( $w, '/portal/' );
    like( $pg, qr{data-ls-app-update="wait"}, 'a page in the scope tells lazysite-app.js to offer the update' );
    unlike( run_processor( $d, '/portal/' ), qr{data-ls-app-update}, 'and says nothing in the default mode' );
};

my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
SKIP: {
    skip 'node is not installed', 3 unless length $node && -x $node;

    my $d = site( $BASE . "app_offline_pages: /portal/, /portal/new\n" );
    my $dw = site( $BASE . "app_offline_pages: /portal/, /portal/new\napp_update: wait\n" );
    my ( undef, $js )  = worker($d);
    my ( undef, $jsw ) = worker($dw);
    ( my $forced = $js ) =~ s/"pages":\[[^\]]*\]/"pages":["\/cgi-bin\/lazysite-odoo.pl","\/cgi-bin\/anything","\/manager\/","\/lazysite\/x","\/login","\/lazysite-dav.pl\/portal\/"]/;
    my $tmp = site_tempdir();
    put( "$tmp/now.js",    $js );
    put( "$tmp/wait.js",   $jsw );
    put( "$tmp/forced.js", $forced );
    my $res = `$node "$root/t/lib/app-offline-harness.js" "$tmp/now.js" "$tmp/wait.js" "$tmp/forced.js" 2>&1`;
    my $f = eval { decode_json($res) };
    ok( $f && !$f->{error}, 'the worker harness ran' ) or BAIL_OUT("harness: $res");

    subtest 'a listed page is network first, and the last good copy opens offline' => sub {
        is_deeply( $f->{pages}, [ '/portal/', '/portal/new' ], 'the worker names the pages' );
        ok( $f->{online}{answered}, 'a listed page is answered by the worker' );
        is( $f->{online}{body}, 'home1', 'with what the network sent' );
        is_deeply( $f->{online}{held}, ['/portal/'], 'and a copy is kept' );
        ok( $f->{offline}{answered} && !$f->{offline}{rejected}, 'offline it is answered' );
        like( $f->{offline}{body}, qr/\Ahome\d+\z/, 'from the kept copy, not the network' );
        ok( $f->{offline_with_query}{answered}, 'the launch URL with a query opens the kept page too' );
        ok( !$f->{offline_unlisted}{answered}, 'a page that is not listed is left to the browser' );
        is_deeply( $f->{kept_once_listed_only}, ['/portal/'], 'and nothing else was ever kept' );
    };

    subtest 'what is kept is the page as an anonymous visitor gets it' => sub {
        is( $f->{credentials}{shown_online}, 'page for alice, signed in', 'a signed-in user is shown what the network sent them' );
        is( $f->{credentials}{shown_offline}, 'anonymous page', 'but the copy kept came from a request sent without credentials' );
        ok( scalar( grep { $_ eq 'omit' } @{ $f->{credentials}{fetched} } ), 'the keeping request omits credentials' );
    };

    subtest 'never kept: no-store, private, Set-Cookie, a redirect, a gated answer' => sub {
        my $k = $f->{kept};
        is_deeply( $k->{ok}, ['/portal/new'], 'a plain 200 is kept' );
        is_deeply( $k->{$_}, [],              "not kept: $_" )
            for qw(no_store private private_caps set_cookie vary_star redirected_to_login not_200 partial opaque);
        is_deeply( $f->{flip}{before}, ['/portal/'], 'a public page is kept' );
        is_deeply( $f->{flip}{after}, [], 'and once it answers no-store the copy is deleted' );
        is_deeply( $f->{survives_outage}, ['/portal/'], 'a refresh that fails because the network is down leaves the good copy' );
    };

    subtest 'the endpoint, /cgi-bin/, the manager, lazysite/, sign-in, non-GET and other origins are never touched' => sub {
        ok( !$f->{answered}{$_}, "not answered: $_" ) for sort keys %{ $f->{answered} };
        is( $f->{fetched_when_refused}, 0, 'nothing fetched on their behalf' );
        is_deeply( $f->{held_when_refused}, [], 'or kept' );
        is_deeply( $f->{forced_pages}, [ '/cgi-bin/lazysite-odoo.pl', '/cgi-bin/anything', '/manager/', '/lazysite/x', '/login', '/lazysite-dav.pl/portal/' ],
            'a worker whose list is edited by hand to name them' );
        ok( !$f->{forced_answered}{$_}, "still not answered: $_" ) for sort keys %{ $f->{forced_answered} };
        is( $f->{forced_fetched}, 0, 'and nothing fetched' );
        is_deeply( $f->{forced_held}, [], 'or kept' );
    };

    subtest 'install keeps the listed pages that may be kept, fetched without credentials' => sub {
        is_deeply( $f->{install}{held_pages}, ['/portal/'], 'the page that says no-store is not kept' );
        ok( ( !grep { $_->{credentials} ne 'omit' } @{ $f->{install}{page_fetches} } ) && @{ $f->{install}{page_fetches} },
            'every page fetch at install omits credentials' );
    };

    subtest 'the update takes over at once by default, and waits for the page when asked' => sub {
        is( $f->{update_now},                     'now',  'default' );
        is( $f->{update_wait},                    'wait', 'declared' );
        is( $f->{update_now_flow}{after_install}, 1, 'now: skipWaiting at install, as SM1155 shipped' );
        is( $f->{update_wait_flow}{after_install}, 0, 'wait: no skipWaiting at install' );
        ok( $f->{update_wait_flow}{has_message_listener}, 'and the worker listens for the page' );
        is( $f->{update_wait_flow}{after_other_messages}, 0, 'another message does not release it' );
        is( $f->{update_wait_flow}{after_object}, 1, 'a {type: "skip-waiting"} message releases it' );
        is( $f->{update_wait_flow}{after_string}, 2, 'so does the string' );
        is( $f->{update_wait_flow}{claim}, 1, 'activation still claims the open pages' );
    };

    my $reg = `$node "$root/t/lib/app-register-harness.js" "$root/starter/assets/lazysite-app.js" 2>&1`;
    my $r = eval { decode_json($reg) };
    ok( $r && !$r->{error}, 'the registration harness ran' ) or BAIL_OUT("register harness: $reg");

    subtest 'lazysite-app.js says why a registration failed' => sub {
        like( join( ' ', @{ $r->{rejected_404} } ), qr/404/, 'a 404 is named' );
        like( join( ' ', @{ $r->{rejected_404} } ), qr{/portal/lazysite-sw\.js}, 'with the worker address it asked for' );
        like( join( ' ', @{ $r->{rejected_script} } ), qr/script/i, 'a script error is named' );
        like( join( ' ', @{ $r->{rejected_security} } ), qr/https|secure/i, 'an insecure origin is named' );
        like( join( ' ', @{ $r->{insecure} } ), qr/secure context.*https.*localhost|https.*localhost.*secure context/i,
            'a browser without service workers on an insecure origin says it needs https or localhost' );
        is( scalar @{ $r->{no_support} }, 1, 'a browser without support says so' );
        is_deeply( $r->{ok}{warn}, [], 'a registration that works is silent' );
        is_deeply( $r->{ok}{registered}, [ [ '/portal/lazysite-sw.js', '/portal/' ] ], 'and registers the worker for the scope' );
        like( $_, qr/\Alazysite-app/, 'every message starts by saying where it came from' ) for map { @{ $r->{$_} } } qw(rejected_404 insecure);
    };

    subtest 'lazysite-app.js offers the update, and applies it only when the page asks' => sub {
        is_deeply( $r->{waiting_at_load}{events}, ['lazysite-app-update'], 'a worker already waiting is offered' );
        is( $r->{waiting_at_load}{reloads}, 0, 'nothing reloads by itself' );
        is( $r->{waiting_at_load}{posted_before}, 0, 'and nothing is posted before the page asks' );
        ok( $r->{has_apply}, 'the event carries an apply()' );
        is_deeply( $r->{after_apply}{posted}, [ { type => 'skip-waiting' } ], 'apply() posts skip-waiting to the waiting worker' );
        is( $r->{after_apply}{reloads_before_swap}, 0, 'and does not reload until the worker has taken over' );
        is( $r->{after_swap}{reloads}, 1, 'then the page reloads once' );
        is( $r->{unasked_swap_reloads}, 0, 'a swap this page did not ask for does not reload it' );
        is_deeply( $r->{found_later}, ['lazysite-app-update'], 'a worker found while the page is open is offered' );
        is_deeply( $r->{first_install}, [], 'the first install has nothing to offer' );
        is_deeply( $r->{now_mode_events}, [], 'in the default mode the page is never asked' );
    };
}

done_testing();
