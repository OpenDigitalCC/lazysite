#!/usr/bin/perl
# P23 (WORK-PLAN-0154, ruled 2026-10-12): a nav entry whose address can run
# script is refused at write, on every surface that writes a navigation - the
# control API's nav-save, MCP set_nav, a WebDAV PUT of a nav file, and a nav
# file saved through the file editor (MCP write_file) - and nothing is
# written. The rule is the render's `| url_safe` (SM970): no scheme, or http,
# https, mailto, tel. `lazysite validate` and `lazysite check` name such an
# entry in a file written before.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);
use TestHelper     qw(repo_root setup_dav_site);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui mcp manage_content manage_nav);
my $s   = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nnav_file: menu/nav.conf\n" );
my $d = $s->docroot;
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; return scalar <$fh> }

$s->add_user('op');
$s->grant( 'op', 'g-op', \@ALL, \@ALL );
# SM1057: the manager's door needs `ui`, which a group granting mcp/api may not
# also grant (SM127) - so the cookie calls below are a manager-UI account's.
$s->add_user('ed');
$s->grant( 'ed', 'g-ed', [qw(ui manage_content manage_nav)], [qw(ui manage_content manage_nav)] );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my $tok = uapi( { action => 'token', username => 'op' } )->{token} // '';
ok( length $tok, 'the MCP caller has a token' );

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer op:$tok";
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/lazysite-mcp.pl" );
    print {$i} $body;
    close $i;
    my $resp = do { local $/; <$o> };
    waitpid $pid, 0;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, error => "JSON-RPC error: $j->{error}{message}" } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

my $nav  = "$d/menu/nav.conf";
my $GOOD = "Home | /\nAbout | /about\n";
make_path("$d/menu");

my @BAD = (
    [ 'javascript:', [ { label => 'Home', url => '/' }, { label => 'X', url => 'javascript:alert(1)' } ] ],
    [ 'data: in a child', [ { label => 'Home', url => '/', children => [ { label => 'C', url => 'data:text/html,x' } ] } ] ],
    [ 'an entity-spelt scheme', [ { label => 'E', url => 'jav&#x61;script:alert(1)' } ] ],
);

for my $case (@BAD) {
    my ( $what, $items ) = @$case;
    subtest "API nav-save and MCP set_nav refuse $what" => sub {
        spit( $nav, $GOOD );
        my $r = $s->call( 'ed', 'nav-save', body => { items => $items } );
        ok( !$r->{ok}, 'API: refused' ) or diag explain $r;
        is( $r->{kind}, 'nav-unsafe-url', 'API: as an unsafe nav address' );
        like( $r->{error} // '', qr/scheme can run script/, 'API: saying why' );
        is( slurp($nav), $GOOD, 'API: the nav file is unchanged' );

        $r = mcp( set_nav => { items => $items } );
        ok( !$r->{ok}, 'MCP: refused' ) or diag explain $r;
        is( $r->{kind},  'nav-unsafe-url', 'MCP: as an unsafe nav address' );
        is( slurp($nav), $GOOD,            'MCP: the nav file is unchanged' );
    };
}

subtest 'a safe nav saves on both surfaces (the control)' => sub {
    my $items = [ { label => 'Home', url => '/' }, { label => 'Mail', url => 'mailto:a@example.com' },
        { label => 'Away', url => 'https://example.com/' }, { label => 'Heading', url => '' } ];
    my $r = $s->call( 'ed', 'nav-save', body => { items => $items } );
    ok( $r->{ok}, 'API: saved' ) or diag explain $r;
    like( slurp($nav), qr/^Mail \| mailto:a\@example\.com$/m, 'API: written' );
    ok( mcp( set_nav => { items => $items } )->{ok}, 'MCP: saved' );
};

subtest 'a nav file saved through the file editor is held to the rule' => sub {
    spit( $nav, $GOOD );
    my $r = mcp( write_file => { path => '/menu/nav.conf', content => "Home | /\nX | javascript:alert(1)\n" } );
    ok( !$r->{ok}, 'MCP write_file of the nav file: refused' ) or diag explain $r;
    is( $r->{kind},  'nav-unsafe-url', '...as an unsafe nav address' );
    is( slurp($nav), $GOOD,            '...and the nav file is unchanged' );
    ok( mcp( write_file => { path => '/menu/other.conf', content => "X | javascript:alert(1)\n" } )->{ok},
        'a file that is not a navigation is content, and saves' );
};

subtest 'WebDAV: a PUT of a nav file is held to the rule' => sub {
    my $site = setup_dav_site();
    my $dr   = $site->{docroot};
    my $put  = sub {
        my ( $path, $body ) = @_;
        my $bf = tempdir( CLEANUP => 1 ) . '/body';
        spit( $bf, $body );
        local %ENV = %ENV;
        $ENV{DOCUMENT_ROOT}      = $dr;
        $ENV{SCRIPT_NAME}        = '/dav';
        $ENV{REMOTE_ADDR}        = '127.0.0.1';
        $ENV{HTTP_AUTHORIZATION} = $site->{auth};
        $ENV{REQUEST_METHOD}     = 'PUT';
        $ENV{PATH_INFO}          = $path;
        $ENV{CONTENT_LENGTH}     = length $body;
        my $out = qx(sh -c \Q$^X \Q$root/lazysite-dav.pl\E < \Q$bf\E 2>/dev/null\E);
        my ($status) = $out =~ /Status:\s*(\d+)/;
        return ( $status, $out );
    };
    spit( "$dr/lazysite/nav.conf", $GOOD );
    my ( $st, $out ) = $put->( '/lazysite/nav.conf', "Home | /\nX | vbscript:msgbox(1)\n" );
    is( $st, 422, 'an unsafe nav is refused with 422' );
    like( $out, qr/scheme can run script/, 'saying why' );
    is( slurp("$dr/lazysite/nav.conf"), $GOOD, 'and the nav file is unchanged' );
    ok( !glob("$dr/lazysite/nav.conf.tmp.*"), 'leaving no temporary file' );
    ($st) = $put->( '/lazysite/nav.conf', "Home | /\nAbout | /about\nMail | mailto:x\@example.com\n" );
    ok( $st == 204 || $st == 201, "a safe nav is written ($st)" );
};

subtest 'validate and check name an entry written before' => sub {
    spit( $nav, "Home | /\nX | javascript:alert(1)\n" );
    my $v = qx(\Q$^X\E \Q$root/tools/lazysite-validate.pl\E \Q$nav\E 2>&1);
    is( $? >> 8, 1, 'lazysite validate exits 1 on the nav file' );
    like( $v, qr/nav\.conf:2: ISSUE: nav-unsafe-url: nav entry 'X' links to a javascript: address/,
        '...naming the line, the entry and the scheme' );
    spit( $nav, $GOOD );
    qx(\Q$^X\E \Q$root/tools/lazysite-validate.pl\E \Q$nav\E 2>&1);
    is( $? >> 8, 0, 'and exits 0 on a safe one' );

    spit( $nav, "Home | /\nX | javascript:alert(1)\n" );
    my $c = qx(\Q$^X\E \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1);
    like( $c, qr{1 nav entry link to an unsafe scheme, rendered as #: menu/nav\.conf:2 'X' \(javascript:\)},
        'lazysite check names it' );
    spit( $nav, $GOOD );
    $c = qx(\Q$^X\E \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1);
    like( $c, qr/every nav entry links to a path or a web address/, 'and says so when there is none' );
};

done_testing();
