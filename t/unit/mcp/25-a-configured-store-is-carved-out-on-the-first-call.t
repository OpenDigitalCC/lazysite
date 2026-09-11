#!/usr/bin/perl
# SM851: a submission store at a handler's own `path:` is carved out on MCP too.
#
# SM268 H1 made every file handler's configured path a submission store, so the
# read gate asks for read_submissions there as it does for the default
# lazysite/forms/submissions. The gate learns those paths by reading
# handlers.conf through Lazysite::Manager::Plugins - whose DOCROOT the MCP sets
# in setup_context, which ran AFTER the carve-out pass. Under CGI every request
# is its process's first, so the pass read no handlers.conf, knew only the
# default store, and an mcp + manage_content partner read a configured store
# through read_file. It came to light as a log line: SM842 made the unreadable
# handlers.conf say so, where the old parser had failed silently.
#
# Driven as a real CGI request, one process per call, because that is the
# condition: a test that reused a process would pass on the second call.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $mcp = repo_root() . '/lazysite-mcp.pl';
my $d   = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/forms/submissions", "$d/data/inbox" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/lazysite.conf", "site_name: X\nmcp_enabled: true\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: inbox\n    type: file\n    name: Inbox\n    path: data/inbox\n" );
spit( "$d/data/inbox/contact.jsonl", qq({"email":"CONFIGURED-STORE-SECRET"}\n) );
spit( "$d/lazysite/forms/submissions/contact.jsonl", qq({"email":"DEFAULT-STORE-SECRET"}\n) );
spit( "$d/about.md", "---\ntitle: About\n---\nPUBLIC-PAGE\n" );

# A content partner: reads and writes pages, holds nothing over submissions.
my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok=>1, settings=>{ mcp=>1, manage_content=>1 } });
STUB
chmod 0755, $stub;

sub read_file_as_partner {
    my ($path) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'read_file', arguments => { path => $path } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $resp // '';
}

like( read_file_as_partner('/about.md'), qr/PUBLIC-PAGE/,
    'the canary: this partner can read a page, so a refusal below is about the store' );

my $default = read_file_as_partner('/lazysite/forms/submissions/contact.jsonl');
unlike( $default, qr/DEFAULT-STORE-SECRET/, 'the default store is refused' );
like( $default, qr/read_submissions/, '... naming the capability it needs' );

my $configured = read_file_as_partner('/data/inbox/contact.jsonl');
unlike( $configured, qr/CONFIGURED-STORE-SECRET/,
    'a store at a handler\'s own path is refused as well, on the first call of the process' );
like( $configured, qr/read_submissions/, '... naming the same capability' );

done_testing();
