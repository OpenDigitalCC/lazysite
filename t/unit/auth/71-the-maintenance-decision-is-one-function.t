#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): WHETHER A SITE IS IN MAINTENANCE IS ONE
# FUNCTION'S ANSWER, asked by the processor, MCP, the manager and control API,
# WebDAV, the data endpoint, the form handler and `lazysite check`.
#
# The rulings it holds:
#   - per domain, with an instance switch covering all: `maintenance: on` puts
#     every host in; `alias.<host>.maintenance: on` puts that declared host in and
#     nobody else; an alias line cannot take its host out of the instance switch
#   - a value that is not on is off (an unreadable value must not close a site)
#   - the page defaults to /maintenance, may be any path on the site or an https
#     address, and a value that is neither falls back to the default
#   - Retry-After is the seconds to maintenance_until, or an hour when there is no
#     future time
#   - the maintenance page, the sign-in pages and their assets stay reachable
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Maintenance qw(status on_value page_ok until_ok exempt is_page retry_after message refusal_json);

sub st { my ( $conf, $host ) = @_; return status( conf_text => $conf, host => $host // '' ) }

# --- the switch -------------------------------------------------------------
ok( !st("site_name: T\n")->{on},     'no key: off' );
ok( !st("maintenance: off\n")->{on}, 'off' );
ok( st("maintenance: on\n")->{on},   'on' );
ok( st("maintenance: ON\n")->{on},   '...in any case' );
ok( !st("maintenance: oof\n")->{on}, 'a value that is not on is off, not an error' );
ok( !st("maintenance:\n")->{on},     'empty is off' );
is( st("maintenance: on\nmaintenance: off\n")->{on}, 0, 'the last line wins, as the processor reads the conf' );
ok( on_value('enabled') && on_value('true') && on_value('yes') && on_value('1') && !on_value('no') && !on_value(undef),
    'on_value: the words that mean on' );

# --- per domain, instance switch covers all ----------------------------------
my $multi = "alias_hosts: a.example, b.example\n";
my $s     = st( $multi . "maintenance: on\n", 'a.example' );
ok( $s->{on}, 'the instance switch covers a declared domain' );
is( $s->{scope}, 'instance', '...as the instance' );
ok( st( $multi . "maintenance: on\n", 'unknown.example' )->{on}, '...and a host nothing declares' );
ok( st( $multi . "maintenance: on\nalias.a.example.maintenance: off\n", 'a.example' )->{on},
    'an alias line cannot take its host out of the instance switch' );

my $one = $multi . "alias.a.example.maintenance: on\n";
$s = st( $one, 'a.example' );
ok( $s->{on}, 'one domain on: that domain is in maintenance' );
is( $s->{scope}, 'domain', '...as a domain' );
ok( !st( $one, 'b.example' )->{on}, '...and its sibling is not' );
ok( !st( $one, '' )->{on},          '...nor the default host' );
ok( !st( "alias.a.example.maintenance: on\n", 'a.example' )->{on},
    'an alias line counts only for a host alias_hosts declares' );
ok( st( $one, 'A.Example:8080' )->{on}, 'the host is read as the processor reads it: case and port' );
ok( !st( $one, "a.example\r\nX: y" )->{on}, 'a malformed Host selects nothing' );

# --- the page ---------------------------------------------------------------
is( st("maintenance: on\n")->{page}, '/maintenance', 'default page' );
is( st("maintenance: on\nmaintenance_page: /closed\n")->{page}, '/closed', 'a path on the site' );
is( st("maintenance: on\nmaintenance_page: https://status.example.com/down\n")->{page},
    'https://status.example.com/down', 'an https address elsewhere' );
for my $bad ( 'closed', '//evil.example/x', 'javascript:alert(1)', 'http://plain.example/', '/a/../b', "/x\r\nSet-Cookie: a=b", '/x?y=1' ) {
    my $b = $bad =~ s/\r\n/ /gr;
    ok( !page_ok($bad), "not an address we redirect to: $b" );
    is( st("maintenance: on\nmaintenance_page: $bad\n")->{page}, '/maintenance', "...so the default is used for it" )
        unless $bad =~ /\r\n/;
}
is( st( $one . "maintenance_page: /closed\nalias.a.example.maintenance_page: /closed-a\n", 'a.example' )->{page},
    '/closed-a', "a domain's own page wins" );
is( st( $one . "maintenance_page: /closed\n", 'a.example' )->{page}, '/closed', '...and it inherits the instance page otherwise' );

# --- Retry-After --------------------------------------------------------------
my $now = 1_800_000_000;    # 2027-01-15 08:00:00 UTC
my $fmt = sub { my @g = gmtime( $_[0] ); sprintf '%04d-%02d-%02d %02d:%02d', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1] };
my $future = $fmt->( $now + 5400 );
$s = st("maintenance: on\nmaintenance_until: $future\n");
is( $s->{until}, $future, 'a readable time is kept' );
cmp_ok( abs( retry_after( $s, $now ) - 5400 ), '<=', 60, 'Retry-After is the seconds to it' );
is( retry_after( st("maintenance: on\n"), $now ), 3600, 'no time: an hour' );
is( retry_after( st("maintenance: on\nmaintenance_until: 2001-01-01 00:00\n"), $now ), 3600, 'a time already past says nothing: an hour' );
is( st("maintenance: on\nmaintenance_until: soon\n")->{until}, '', 'an unreadable time is dropped, not shown' );
ok( until_ok('2026-11-01 18:30') && until_ok('2026-11-01T18:30:15Z') && !until_ok('2026-13-01 00:00') && !until_ok('tomorrow'),
    'until_ok: the two shapes, and a calendar that exists' );
like( message( st("maintenance: on\nmaintenance_until: $future\n") ), qr/until \Q$future\E \(UTC\)/, 'the message names the time' );
like( message( st("maintenance: on\n") ), qr/in maintenance\. Please try again later/, '...or says to try later' );
my $j = refusal_json( st("maintenance: on\n") );
like( $j, qr/"kind":"maintenance"/, 'the machine doors answer a JSON kind' );
like( $j, qr/"ok":false/,           '...with ok false' );
like( $j, qr/"retry_after":3600/,   '...and the seconds' );

# --- what stays reachable ----------------------------------------------------
my $m = st("maintenance: on\n");
ok( exempt( '/maintenance', $m ), 'the maintenance page' );
ok( exempt( '/maintenance/', $m ) && exempt( '/maintenance.md', $m ), '...however it is written' );
ok( is_page( '/maintenance', $m ) && !is_page( '/maintenancex', $m ) && !is_page( '/', $m ), 'and only it is "the page"' );
ok( exempt( $_, $m ), "sign-in flow: $_" ) for qw(/login /logout /forgot /claim);
ok( exempt( '/lazysite-assets/theme.css', $m ), 'theme and site assets' );
ok( exempt( '/images/logo.png', $m ) && exempt( '/x/site.css?v=2', $m ), 'a presentation asset a domain serves' );
ok( exempt( '/.well-known/security.txt', $m ) && exempt( '/robots.txt', $m ), 'well-known and robots' );
ok( exempt( '/signin', $m, '/signin' ), 'the configured sign-in address' );
ok( !exempt( '/', $m ),                 'the home page is a page' );
ok( !exempt( '/about', $m ),            'an ordinary page' );
ok( !exempt( '/manager/users', $m ), 'the manager is for those who hold the capability' );
ok( !exempt( '/report.pdf', $m ),    'a document is not a presentation asset' );
ok( exempt( '/closed', st("maintenance: on\nmaintenance_page: /closed\n") ), 'a configured local page is reachable' );
ok( !is_page( "/maintenance", st("maintenance: on\nmaintenance_page: https://x.example.com/\n") ), "an off-site page is no local page" );

done_testing;
