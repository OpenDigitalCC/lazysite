#!/usr/bin/perl
# P15 (WORK-PLAN-0154, ruled 2026-10-12 "Record host"): every visitor-log event
# carries the host that served it; analyse_visitors filters to one domain
# (`host`) and groups by domain (`by_host`); and a caller confined to some
# domains sees only their traffic - the SM976 rule. Before, every caller with
# `analytics` read every domain's traffic, and nothing could split it.
#
# An event's domain: a Host that is one of alias_hosts is that domain's; any
# other Host (the primary's own name, an unregistered www form) was served the
# default site and is the primary's.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(ui api mcp analytics);
my $s   = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nsite_url: https://main.test\n"
        . "alias_hosts: mine.test, other.test\n"
        . "alias.mine.test.content_root: sites/mine\nalias.mine.test.site_url: https://mine.test\n"
        . "alias.mine.test.allowed_groups: g-mcs\n"
        . "alias.other.test.content_root: sites/other\nalias.other.test.site_url: https://other.test\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/logs" );
for my $u (qw(op mcs mcu)) {
    $s->add_user($u);
    $s->grant( $u, "g-$u", ( $u eq 'op' ? [qw(ui analytics)] : [qw(mcp analytics)] ), \@ALL );
}

# One day of traffic, each request named by the domain that should own it.
my @g = gmtime;
my $log = sprintf "$d/lazysite/logs/access-%04d%02d%02d.jsonl", $g[5] + 1900, $g[4] + 1, $g[3];
my $UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
my $now = time() - 60;
{
    open my $fh, '>', $log or die $!;
    my $n = 0;
    for my $ev ( [ 'main.test', '/primary-page' ], [ 'mine.test', '/mine-page' ],
        [ 'other.test', '/other-page' ], [ 'www.mine.test', '/unregistered-host-page' ], [ '', '/no-host-page' ] )
    {
        my ( $h, $p ) = @$ev;
        for my $i ( 1 .. 2 ) {
            print {$fh} encode_json( { t => $now + $n++, p => $p, s => 200, ch => 'page', v => "v$h$i", ua => $UA,
                    ( length $h ? ( h => $h ) : () ) } ) . "\n";
        }
    }
    close $fh;
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(mcs mcu);

sub mcp {
    my ( $who, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'analyse_visitors', arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}
sub api { my ($q) = @_; return $s->call( 'op', 'analyse_visitors', query => "action=analyse_visitors&$q" ) }

sub pages_in {
    my ($r) = @_;
    my $j = encode_json($r);
    return join ',', sort grep { $j =~ /\Q$_\E/ } qw(/primary-page /mine-page /other-page
        /unregistered-host-page /no-host-page);
}
my $ALL_PAGES = '/mine-page,/no-host-page,/other-page,/primary-page,/unregistered-host-page';

subtest 'the unconfined operator reads every domain, and can ask for one' => sub {
    my $r = api('window=7');
    ok( $r->{ok}, 'the whole view answers' ) or diag explain $r;
    is( pages_in($r), $ALL_PAGES, 'with every domain\'s pages' );

    $r = api('window=7&host=mine.test');
    ok( $r->{ok}, 'host=mine.test answers' ) or diag explain $r;
    is( pages_in($r), '/mine-page', 'with mine.test\'s pages only' );
    is_deeply( $r->{hosts}, ['mine.test'], 'naming the domain it was counted for' );

    $r = api('window=7&host=(default)');
    is( pages_in($r), '/no-host-page,/primary-page,/unregistered-host-page',
        'the primary: its own name, an unregistered host and no host' );

    $r = api('window=7&by_host=1');
    my $by = $r->{by_host}{domains} || {};
    is_deeply( { map { ( $_ => $by->{$_}{requests} ) } keys %$by },
        { '(default)' => 6, 'mine.test' => 2, 'other.test' => 2 }, 'by_host groups requests by serving domain' );
    ok( length( $r->{by_host}{basis} // '' ), 'and says what it counted' );

    ok( !api('window=7&host=nowhere.test')->{ok}, 'a host the instance does not serve is refused' );
    ok( !api('day=2026-01-01&host=mine.test')->{ok}, 'a rollup selector is not split by domain: refused' );
};

subtest 'a grant confined to one domain reads only that domain' => sub {
    my $r = mcp( mcs => { window => 7 } );
    ok( $r->{ok}, 'the view answers' ) or diag explain $r;
    is( pages_in($r), '/mine-page', 'with its own domain\'s pages only' );
    unlike( encode_json($r), qr/other\.test|primary-page/, 'and nothing of another domain' );

    $r = mcp( mcs => { window => 7, host => 'other.test' } );
    ok( !$r->{ok}, 'asking for another domain is refused' );
    like( $r->{error} // '', qr/other\.test/, '...naming it' );

    ok( !mcp( mcs => { window => 7, host => '(default)' } )->{ok}, 'and the primary' );
    ok( !mcp( mcs => { index => JSON::PP::true } )->{ok}, 'the index covers every domain: refused' );
    ok( !mcp( mcs => { day => '2026-01-01' } )->{ok}, 'a day rollup: refused' );

    $r = mcp( mcs => { window => 7, by_host => JSON::PP::true } );
    is_deeply( [ sort keys %{ $r->{by_host}{domains} || {} } ], ['mine.test'], 'by_host names only its own domain' );
};

subtest 'an unscoped grant reaches the primary only (SM975), and reads only its traffic' => sub {
    my $r = mcp( mcu => { window => 7 } );
    ok( $r->{ok}, 'the view answers' ) or diag explain $r;
    is( pages_in($r), '/no-host-page,/primary-page,/unregistered-host-page', 'the primary\'s traffic only' );
};

done_testing();
