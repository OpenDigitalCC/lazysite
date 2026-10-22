#!/usr/bin/perl
# SM1064: A PREVIEW IS NO VISIT, on every door that renders one.
#
# SM1031 ruled that "a saved preview is no visit": MCP preview_page sets
# LAZYSITE_PREVIEW and the processor's first-party access log leaves such a
# render out. It left open whether the other previews record one - MCP
# preview_public_page, MCP preview_domain, and the manager's own preview,
# preview-public and domain-preview - because its probe could not run them:
# they find the processor through Lazysite::Manager::Common::processor_path,
# which reads LAZYSITE_PROCESSOR or the docroot's ../cgi-bin, and the test
# docroot has neither (MCP preview_page finds the processor beside
# lazysite-mcp.pl, which is why it alone could be measured). This rig names
# the processor in LAZYSITE_PROCESSOR, as t/integration/59 does.
#
# Each case is held to a positive control: a visitor's request in the same rig
# DOES write a line, and each preview DID render the page, so an unchanged
# line count is the preview being left out, never the log or the render
# failing.
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

my $ms = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nsite_name: T\nlayout: plain\n"
        . "alias_hosts: mine.test\nalias.mine.test.content_root: sites/mine\n" );
$ms->users( 'setup-sysop', '--user', 'ada' );
my $d    = $ms->docroot;
my $logs = "$d/..";        # beside the docroot, inside the directory the suite cleans

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
# A layout that puts the content first, so a preview's 400-character excerpt
# carries the page rather than the head of the built-in fallback.
spit( "$d/lazysite/layouts/plain/layout.tt", '<main>[% content %]</main>' );
spit( "$d/index.md",                         "---\ntitle: Home\n---\nPRIMARY-HOME\n" );
spit( "$d/404.md",                           "---\ntitle: NF\n---\nNot found.\n" );
spit( "$d/about.md",                         "---\ntitle: About\n---\nPRIMARY-ABOUT\n" );
spit( "$d/sites/mine/index.md",              "---\ntitle: Mine\n---\nMINE-HOME\n" );
spit( "$d/users-stub.pl",                    <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json( { ok => 1, settings => { mcp => 1, manage_content => 1, manage_domains => 1, dav_scopes => [ grep { length } $ENV{STUB_SCOPE} // '' ] } } );
STUB
chmod 0755, "$d/users-stub.pl";

sub visits {
    my $n = 0;
    for my $f ( glob "$d/lazysite/logs/access-*.jsonl" ) {
        open my $fh, '<', $f or next;
        $n++ while <$fh>;
        close $fh;
    }
    return $n;
}

# One tools/call over the MCP CGI, as a token whose grant names $scope (none:
# unconfined; preview_domain needs a scope that reaches the domain).
sub mcp {
    my ( $tool, $args, $scope ) = @_;
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
        STUB_SCOPE                   => $scope // '',
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

# A visitor's GET straight to the processor, as the web server runs it.
sub visit {
    my ($url) = @_;
    local %ENV = ( env_passthrough(),
        PATH            => $ENV{PATH},
        DOCUMENT_ROOT   => $d,
        REDIRECT_URL    => $url,
        REQUEST_URI     => $url,
        REQUEST_METHOD  => 'GET',
        QUERY_STRING    => '',
        HTTP_USER_AGENT => 'Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0',
        REMOTE_ADDR     => '192.0.2.10',
    );
    my $out = qx($^X \Q$root/lazysite-processor.pl\E 2>>\Q$logs/stderr.log\E);
    return $out;
}

subtest 'THE CONTROL: a visitor\'s request writes one access-log line' => sub {
    my $n   = visits();
    my $out = visit('/about');
    like( $out, qr/PRIMARY-ABOUT/, 'the page was served' );
    is( visits(), $n + 1, 'and recorded as a visit, so this rig records visits' );
};

# The door, how to call it, and what its answer must carry to show it rendered.
my @doors = (
    [ 'MCP preview_page (SM1031)',
        sub { mcp( preview_page => { path => '/about' } ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'MCP preview_public_page',
        sub { mcp( preview_public_page => { path => '/about' } ) },
        sub { $_[0]{ok} && ( $_[0]{excerpt} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'MCP preview_domain',
        sub { mcp( preview_domain => { host => 'mine.test' }, 'sites/mine' ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /MINE-HOME/ },
    ],
    [ 'manager preview',
        sub { $ms->call( 'ada', 'preview', query => 'action=preview&path=/about.md' ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'manager preview-public',
        sub { $ms->call( 'ada', 'preview-public', query => 'action=preview-public&path=/about' ) },
        sub { $_[0]{ok} && ( $_[0]{excerpt} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'manager domain-preview',
        sub { $ms->call( 'ada', 'domain-preview', query => 'action=domain-preview&host=mine.test' ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /MINE-HOME/ },
    ],
);

for my $door (@doors) {
    my ( $name, $call, $rendered ) = @$door;
    subtest "$name writes no access-log visit" => sub {
        my $n = visits();
        my $r = $call->();
        ok( $rendered->($r), "$name rendered the page" ) or diag explain $r;
        is( visits(), $n, 'and the access log is as it was' );
    };
}

subtest 'THE CONTROL, again: a visit after the previews is still recorded' => sub {
    my $n = visits();
    visit('/about');
    is( visits(), $n + 1, 'one line' );
};

done_testing();
