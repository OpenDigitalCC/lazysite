#!/usr/bin/perl
# SM1066: EVERY PREVIEW FINDS THE PROCESSOR, wherever the cgi-bin is.
#
# lazysite found the processor two ways (SM1065). MCP preview_page looked
# beside lazysite-mcp.pl; preview_public_page and preview_domain went through
# Manager::Common::processor_path, which read LAZYSITE_PROCESSOR or else the
# docroot's ../cgi-bin. The nginx examples and the Hestia templates set
# LAZYSITE_PROCESSOR only for the processor and the manager API, never for
# lazysite-mcp.pl, so on an install whose cgi-bin is not the docroot's
# ../cgi-bin (install.pl's own example is `--cgibin /usr/lib/cgi-bin`) the
# first rendered and the other two shelled a processor that was not there.
#
# This rig is that install: the CGIs copied into <tmp>/usr/lib/cgi-bin, the
# docroot at <tmp>/site/public_html with nothing at its ../cgi-bin, the engine
# modules on @INC (PERL5LIB), and the MCP CGI run with no LAZYSITE_PROCESSOR,
# as the nginx generic /cgi-bin/ location runs it. The manager API is run as
# nginx runs it too, LAZYSITE_PROCESSOR naming lazysite-manager-api.pl in that
# cgi-bin: the control, a door that worked before and must still.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Copy     qw(copy);
use File::Basename qw(dirname);
use JSON::PP       qw(encode_json decode_json);
use IPC::Open3     qw(open3);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root env_passthrough run_child);
use ManagerSession ();

my $root = repo_root();
delete $ENV{LAZYSITE_PROCESSOR};

my $ms = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nsite_name: T\nlayout: plain\n"
        . "alias_hosts: mine.test\nalias.mine.test.content_root: sites/mine\n" );
$ms->users( 'setup-sysop', '--user', 'ada' );
my $d    = $ms->docroot;
my $tmp  = dirname( dirname($d) );    # <tmp>/site/public_html -> <tmp>
my $cgi  = "$tmp/usr/lib/cgi-bin";
my $logs = "$d/..";

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

# The cgi-bin as install.pl lays it out: each CGI at {CGIBIN}/NAME, the
# processor's parts at {CGIBIN}/lazysite-processor/, mode 0755.
make_path("$cgi/lazysite-processor");
for my $f (qw(lazysite-mcp.pl lazysite-processor.pl lazysite-manager-api.pl)) {
    copy( "$root/$f", "$cgi/$f" ) or die "copy $f: $!";
    chmod 0755, "$cgi/$f";
}
opendir my $pd, "$root/lazysite-processor" or die $!;
for my $f ( grep { /\.pm\z/ } readdir $pd ) {
    copy( "$root/lazysite-processor/$f", "$cgi/lazysite-processor/$f" ) or die "copy $f: $!";
}
closedir $pd;
$ms->{api} = "$cgi/lazysite-manager-api.pl";
my $perl5lib = join ':', grep { defined && length } "$root/lib", $ENV{PERL5LIB};

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

# One tools/call over the MCP CGI in the cgi-bin, with no LAZYSITE_PROCESSOR.
sub mcp {
    my ( $tool, $args, $scope ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PERL5LIB                     => $perl5lib,
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => 'Bearer op:lzs_tok',
        STUB_SCOPE                   => $scope // '',
    );
    open my $e, '>>', "$logs/stderr.log" or die $!;
    my $resp = run_child( [ $^X, "$cgi/lazysite-mcp.pl" ], stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, error => "JSON-RPC error: $j->{error}{message}" } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

# The manager API as the nginx examples run it: LAZYSITE_PROCESSOR names it.
sub manager {
    my (@call) = @_;
    local $ENV{LAZYSITE_PROCESSOR} = "$cgi/lazysite-manager-api.pl";
    local $ENV{PERL5LIB}           = $perl5lib;
    return $ms->call(@call);
}

subtest 'THE LAYOUT: the cgi-bin is not the docroot\'s ../cgi-bin' => sub {
    ok( !-e "$d/../cgi-bin/lazysite-processor.pl", 'nothing at the docroot\'s ../cgi-bin' );
    ok( -f "$cgi/lazysite-processor.pl",            'the processor is in the cgi-bin' );
};

my @doors = (
    [ 'MCP preview_page (worked before)',
        sub { mcp( preview_page => { path => '/about' } ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'manager preview-public, LAZYSITE_PROCESSOR set (worked before)',
        sub { manager( 'ada', 'preview-public', query => 'action=preview-public&path=/about' ) },
        sub { $_[0]{ok} && ( $_[0]{excerpt} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'MCP preview_public_page',
        sub { mcp( preview_public_page => { path => '/about' } ) },
        sub { $_[0]{ok} && ( $_[0]{excerpt} // '' ) =~ /PRIMARY-ABOUT/ },
    ],
    [ 'MCP preview_domain',
        sub { mcp( preview_domain => { host => 'mine.test' }, 'sites/mine' ) },
        sub { $_[0]{ok} && ( $_[0]{html} // '' ) =~ /MINE-HOME/ },
    ],
);

for my $door (@doors) {
    my ( $name, $call, $rendered ) = @$door;
    subtest "$name renders" => sub {
        my $r = $call->();
        ok( $rendered->($r), "$name rendered the page" ) or diag explain $r;
    };
}

done_testing();
