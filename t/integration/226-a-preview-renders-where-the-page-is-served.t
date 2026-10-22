#!/usr/bin/perl
# SM1065: A PREVIEW RENDERS A PAGE WHERE ITS SITE SERVES IT.
#
# SM441 made the previews render a domain's page under the Host of the domain
# that owns it, and left the URL at the page's DOCROOT path. Under that Host the
# processor resolves the URL against the domain's own content root, so
# /sites/mine/index asked under mine.test looked for sites/mine/sites/mine/index
# and answered 404 - the preview reported a published page as one no visitor
# sees. SM1031 (c) fixed that in MCP preview_page; SM1064 found it still in
# preview_public (MCP preview_public_page and the manager's preview-public), and
# the manager's own preview has it too.
#
# The other half of SM1031 (c) is the primary's page asked while the request
# carries a domain's Host (the manager opened on that domain's own name): the
# Host was inherited, so the page was resolved against the domain's content
# root and the domain's page of the same name came back in its place.
#
# Every case is discriminating: sites/mine/about.md and about.md both exist with
# different markers, so a render resolved against the wrong root names itself.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root env_passthrough run_child);
use ManagerSession ();

my $root = repo_root();
$ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";
delete $ENV{HTTP_HOST};

my $ms = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nsite_name: T\nlayout: plain\n"
        . "alias_hosts: mine.test\nalias.mine.test.content_root: sites/mine\n" );
$ms->users( 'setup-sysop', '--user', 'ada' );
my $d    = $ms->docroot;
my $logs = "$d/..";

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
# Content first, so preview_public's 400-character excerpt carries the page.
spit( "$d/lazysite/layouts/plain/layout.tt", '<main>[% content %]</main>' );
spit( "$d/index.md",                         "---\ntitle: Home\n---\nPRIMARY-HOME\n" );
spit( "$d/404.md",                           "---\ntitle: NF\n---\nNot found.\n" );
spit( "$d/about.md",                         "---\ntitle: About\n---\nPRIMARY-ABOUT\n" );
spit( "$d/sites/mine/index.md",              "---\ntitle: Mine\n---\nMINE-HOME\n" );
spit( "$d/sites/mine/about.md",              "---\ntitle: Mine about\n---\nMINE-ABOUT\n" );
spit( "$d/users-stub.pl",                    <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json( { ok => 1, settings => { mcp => 1, manage_content => 1, manage_domains => 1, dav_scopes => [] } } );
STUB
chmod 0755, "$d/users-stub.pl";

# One tools/call over the MCP CGI, as an unconfined token, under $host if given.
sub mcp {
    my ( $tool, $args, $host ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        LAZYSITE_PROCESSOR           => $ENV{LAZYSITE_PROCESSOR},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer op:lzs_tok',
        ( defined $host ? ( HTTP_HOST => $host ) : () ),
    );
    open my $e, '>>', "$logs/stderr.log" or die $!;
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, error => "JSON-RPC error: $j->{error}{message}" } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

# A manager request, under $host if given (the manager opened on that name).
sub mgr {
    my ( $action, $query, $host ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    return $ms->call( 'ada', $action, query => $query );
}

sub pp_mgr { my ( $p, $h ) = @_; mgr( 'preview-public', "action=preview-public&path=$p", $h ) }
sub pv_mgr { my ( $p, $h ) = @_; mgr( 'preview',        "action=preview&path=$p",        $h ) }

subtest 'THE CONTROL: domain_preview renders the domain at / under its Host' => sub {
    my $r = mgr( 'domain-preview', 'action=domain-preview&host=mine.test' );
    ok( $r->{ok}, 'it rendered' ) or diag explain $r;
    like( $r->{html} // '', qr/MINE-HOME/, 'the domain\'s own home page, so the rig routes by Host' );
};

subtest 'preview-public: a domain\'s page, by its docroot path, is the page' => sub {
    for my $p ( '/sites/mine/index', '/sites/mine/', '/sites/mine' ) {
        my $r = pp_mgr($p);
        is( $r->{status}, 200, "$p answers 200" ) or diag explain $r;
        like( $r->{excerpt} // '', qr/MINE-HOME/, "$p renders the domain's home page" );
        is( $r->{verdict},          'visible',   'and reports it visible' );
        is( $r->{rendered_as_host}, 'mine.test', 'under the owning domain\'s Host' );
        is( $r->{path},             $p,          'and names the path it was asked about' );
    }
    my $a = pp_mgr('/sites/mine/about');
    like( $a->{excerpt} // '', qr/MINE-ABOUT/, 'a page below the domain\'s home too' )
        or diag explain $a;
};

subtest 'MCP preview_public_page: the same page through the connector' => sub {
    my $r = mcp( preview_public_page => { path => '/sites/mine/about' } );
    is( $r->{status}, 200, 'answers 200' ) or diag explain $r;
    like( $r->{excerpt} // '', qr/MINE-ABOUT/, 'renders the domain\'s page' );
    is( $r->{rendered_as_host}, 'mine.test', 'under the owning domain\'s Host' );
};

subtest 'the manager\'s preview: a domain\'s page is the page' => sub {
    my $r = pv_mgr('/sites/mine/about.md');
    ok( $r->{ok}, 'it rendered' ) or diag explain $r;
    like( $r->{html} // '', qr/MINE-ABOUT/, 'the domain\'s page, not its 404' );
    my $i = pv_mgr('/sites/mine/index.md');
    like( $i->{html} // '', qr/MINE-HOME/, 'and the domain\'s home page' ) or diag explain $i;
};

subtest 'the primary\'s page asked under a domain\'s Host is the primary\'s page' => sub {
    my $r = pp_mgr( '/about', 'mine.test' );
    like( $r->{excerpt} // '', qr/PRIMARY-ABOUT/, 'preview-public renders the primary\'s page' )
        or diag explain $r;
    unlike( $r->{excerpt} // '', qr/MINE-ABOUT/, 'not the domain\'s page of the same name' );
    is( $r->{rendered_as_host}, '(default)', 'and names the default site as where it rendered' );

    my $m = mcp( preview_public_page => { path => '/about' }, 'mine.test' );
    like( $m->{excerpt} // '', qr/PRIMARY-ABOUT/, 'preview_public_page too' ) or diag explain $m;

    my $v = pv_mgr( '/about.md', 'mine.test' );
    like( $v->{html} // '', qr/PRIMARY-ABOUT/, 'and the manager\'s preview' ) or diag explain $v;
};

subtest 'MCP preview_page, whose fix this shares, still agrees' => sub {
    my $r = mcp( preview_page => { path => '/sites/mine/about' } );
    like( $r->{html} // '', qr/MINE-ABOUT/, 'a domain\'s page' ) or diag explain $r;
    is( $r->{rendered_as_host}, 'mine.test', 'under its Host' );
    my $p = mcp( preview_page => { path => '/about' }, 'mine.test' );
    like( $p->{html} // '', qr/PRIMARY-ABOUT/, 'and the primary\'s page under a domain\'s Host' )
        or diag explain $p;
};

done_testing();
