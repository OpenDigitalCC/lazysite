#!/usr/bin/perl
# SM724: a user has a start page.
#
# The ruling (2026-09-05): the fallback is the manager with the user's own
# account sheet open; the user, or a user manager, may set it; a domain target
# is a chosen page on that domain. What this holds, at the module and through
# the users tool:
#   - the stored form is two kinds, parsed as two kinds
#   - the choices for an account are computed from THAT account's grants and
#     confinement, never the operator's
#   - a start page the account cannot reach is refused at set time BY REASON
#   - a domain target must be a domain this instance serves (a hostname is not
#     a path, and the login's path guard would have refused it - correctly)
#   - at sign-in: unset -> the fallback; set and reachable -> the page; set but
#     no longer reachable -> the fallback WITH the reason, not a 403
#   - the tool lets an account set its OWN start page and nobody else's
#     without manage_users
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root grant_caps revoke_caps site_tempdir);
use Lazysite::Manager::StartPage qw(parse_start_page validate_start_page start_page_choices resolve_start_page fallback_landing);

my $root = repo_root();
my $utl  = "$root/tools/lazysite-users.pl";
my $d    = site_tempdir();    # SM754: one level down, so sibling writes go with it
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/sites/shop", "$d/sites/blog" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} <<'CONF';
site_name: Main
site_url: https://main.example
manager: enabled
plugins:
  - stats.pl
alias_hosts: shop.example, blog.example
alias.shop.example.content_root: sites/shop
alias.shop.example.allowed_groups: role-shopper
alias.blog.example.content_root: sites/blog
CONF
close $cf;
$Lazysite::Manager::StartPage::DOCROOT = $d;

sub users_api {
    my ($payload) = @_;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $utl, '--api', '--docroot', $d );
    print {$in} encode_json($payload);
    close $in;
    my $raw = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return decode_json($raw);
}
users_api( { action => 'add', username => $_, password => 'pw' } ) for qw(admin editor shopper);
grant_caps( $d, 'admin',  qw(ui manage_users manage_content manage_domains audit) );
grant_caps( $d, 'editor', qw(ui manage_content) );
grant_caps( $d, 'shopper', qw(ui manage_content) ); # confined to shop.example by allowed_groups

subtest 'the stored form is two kinds' => sub {
    is_deeply( parse_start_page('manager:files'), { kind => 'manager', page => 'files' }, 'a manager page' );
    is_deeply( parse_start_page('domain:shop.example|/catalogue'), { kind => 'domain', host => 'shop.example', path => '/catalogue' }, 'a page on a domain' );
    is_deeply( parse_start_page('domain:shop.example|'), { kind => 'domain', host => 'shop.example', path => q{/} }, 'an empty path is the root' );
    ok( !defined parse_start_page('https://evil.example/'), 'a bare URL is not a start page' );
    ok( !defined parse_start_page(q{/manager/files}), 'nor a bare path - the kind is stored, not inferred' );
};

subtest 'choices come from the TARGET account\'s grants and confinement' => sub {
    my $a  = start_page_choices('admin');
    my %ap = map { $_->{value} => 1 } @{ $a->{pages} };
    ok( $ap{'manager:files'} && $ap{'manager:domains'} && $ap{'manager:audit'}, 'admin: files, domains, audit' );
    ok( $ap{'manager:stats'}, 'stats: the plugin is enabled' );
    ok( !$ap{'manager:data'}, 'data: the plugin is not enabled, so not offered' );
    is( scalar @{ $a->{domains} }, 3, 'admin is unbound: every domain, primary included' );

    my $e  = start_page_choices('editor');
    my %ep = map { $_->{value} => 1 } @{ $e->{pages} };
    ok( $ep{'manager:files'},    'editor: files' );
    ok( !$ep{'manager:domains'}, 'editor: not domains - no manage_domains' );
    ok( !$ep{'manager:audit'},   'editor: not audit' );

    my $s = start_page_choices('shopper');
    is_deeply( [ map { $_->{host} } @{ $s->{domains} } ], ['shop.example'],
        'a confined account is offered only the domain its confinement reaches' );
};

subtest 'a start page the account cannot reach is refused, by reason' => sub {
    ok( !defined validate_start_page( 'editor', 'manager:files' ), 'editor may choose files' );
    like( validate_start_page( 'editor', 'manager:domains' ), qr/cannot reach the manager page 'domains'.*manage_domains/, 'domains: refused, naming the capability' );
    like( validate_start_page( 'editor', 'manager:data' ), qr/data\.pl plugin enabled/, 'data: refused, naming the plugin' );
    like( validate_start_page( 'editor', 'manager:edit' ), qr/not a manager page a start page may name/, 'edit takes a path and is not a start page' );
    like( validate_start_page( 'editor', 'domain:evil.example|/' ), qr/not a domain this instance serves/, 'a foreign host is refused by name - not by character class' );
    like( validate_start_page( 'shopper', 'domain:blog.example|/' ), qr/outside the account's confinement/, 'a confined account is refused a domain outside its scope' );
    ok( !defined validate_start_page( 'shopper', 'domain:shop.example|/catalogue' ), 'and allowed its own' );
    like( validate_start_page( 'admin', 'domain:shop.example|../etc' ), qr/not a page path/, 'a traversal path is refused' );
    like( validate_start_page( 'admin', 'domain:shop.example|//x' ), qr/not a page path/, 'a protocol-relative path is refused' );
    like( validate_start_page( 'admin', 'nonsense' ), qr/a start page is 'manager:<page>' or 'domain:<host>\|<path>'/, 'garbage is refused with the grammar' );
    ok( !defined validate_start_page( 'admin', '' ), 'empty clears and is fine' );
};

subtest 'at sign-in: unset, set, and set-but-unreachable' => sub {
    is( resolve_start_page('editor')->{url}, fallback_landing(), 'unset: the fallback' );
    is( fallback_landing(), '/manager/?account=1', 'which is the manager with the account sheet open' );

    my $r = users_api( { action => 'settings-set', username => 'editor', key => 'start_page', value => 'manager:files', actor => 'editor' } );
    ok( $r->{ok}, 'editor sets their own start page through the tool' ) or diag explain $r;
    is( resolve_start_page('editor')->{url}, '/manager/files', 'set and reachable: the page' );

    $r = users_api( { action => 'settings-set', username => 'admin', key => 'start_page', value => 'domain:shop.example|/catalogue', actor => 'admin' } );
    ok( $r->{ok}, 'admin chooses a page on another host' ) or diag explain $r;
    is( resolve_start_page('admin')->{url}, 'https://shop.example/catalogue', 'an absolute URL to a host this instance serves' );
    $r = users_api( { action => 'settings-set', username => 'admin', key => 'start_page', value => 'domain:(default)|/about', actor => 'admin' } );
    ok( $r->{ok}, 'or a page on the primary' ) or diag explain $r;
    is( resolve_start_page('admin')->{url}, '/about', 'which is a relative path - same host' );

    # grants change after the choice: editor loses manage_content
    revoke_caps( $d, 'editor', 'manage_content' );
    my $u = resolve_start_page('editor');
    is( $u->{url}, '/manager/?account=1&start=unreachable', 'set but no longer reachable: the fallback, flagged' );
    like( $u->{unreachable}, qr/manage_content/, 'with the reason, which is the capability now missing' );
    grant_caps( $d, 'editor', qw(ui manage_content) );
};

subtest 'the tool: your own, or with manage_users' => sub {
    my $r = users_api( { action => 'settings-set', username => 'shopper', key => 'start_page', value => 'manager:files', actor => 'editor' } );
    ok( !$r->{ok}, 'editor may not set shopper\'s start page' );
    like( $r->{error}, qr/manage_users/, 'and is told which capability that needs' );
    $r = users_api( { action => 'settings-set', username => 'shopper', key => 'start_page', value => 'manager:files', actor => 'admin' } );
    ok( $r->{ok}, 'admin (manage_users) may' ) or diag explain $r;
    $r = users_api( { action => 'settings-set', username => 'editor', key => 'display_name', value => 'X', actor => 'editor' } );
    ok( !$r->{ok}, 'the self-service exemption is for start_page ONLY - display_name is still a manage_users act' );
    $r = users_api( { action => 'settings-set', username => 'editor', key => 'start_page', value => 'manager:domains', actor => 'editor' } );
    ok( !$r->{ok}, 'a self-set of an unreachable page is refused too' );
    like( $r->{error}, qr/start_page refused/, 'as a start_page refusal' );
};

done_testing();
