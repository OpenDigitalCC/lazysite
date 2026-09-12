#!/usr/bin/perl
# SM855: read_form_submissions reads the store THIS form is bound to.
#
# The tool took a form name and built `lazysite/forms/submissions/<form>.jsonl`.
# A form bound to a file handler that names its own `path:` therefore had its
# submissions read from a file that was not its store - and the answer was
# `ok: true, total: 0`, an empty SUCCESS naming the wrong file, while the control
# API's form-list reported `has_store: true, row_count: 1` for the same form.
# The site agent met it in the 1313E pass with the row sitting in the real store
# and WebDAV returning it.
#
# This is the shape SM768 named: a reader that turns "I am looking in the wrong
# place" into "there is nothing here". The engine knew where the store was - one
# reader did not ask.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $mcp = repo_root() . '/lazysite-mcp.pl';
my $d   = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/forms/submissions", "$d/data/enquiries" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/lazysite.conf", "site_name: X\nmcp_enabled: true\n" );

# Two handlers: one keeping its store where it likes, one on the default.
spit( "$d/lazysite/forms/handlers.conf", <<'CONF' );
handlers:
  - id: enquiries
    type: file
    name: Enquiries
    path: data/enquiries
  - id: local-storage
    type: file
    name: Local storage
CONF

# `moved` is bound to the handler with its own path; `plain` to the default one.
spit( "$d/lazysite/forms/moved.conf",  "targets:\n  - handler: enquiries\n" );
spit( "$d/lazysite/forms/plain.conf",  "targets:\n  - handler: local-storage\n" );
spit( "$d/data/enquiries/moved.jsonl", qq({"_id":"a1","email":"MOVED-STORE-ROW"}\n) );
spit( "$d/lazysite/forms/submissions/plain.jsonl", qq({"_id":"b1","email":"DEFAULT-STORE-ROW"}\n) );

# A reader: read_submissions and nothing else it needs here.
my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok=>1, settings=>{ mcp=>1, read_submissions=>1 } });
STUB
chmod 0755, $stub;

sub mcp_call {
    my ( $tool, %args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => {%args} } } );
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
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $d2   = eval { decode_json( $jb // '' ) } || {};
    return eval { decode_json( $d2->{result}{content}[0]{text} // '' ) } || {};
}

subtest 'the default store still reads - the control' => sub {
    my $r = mcp_call( 'read_form_submissions', form => 'plain' );
    ok( $r->{ok}, 'it answers ok' ) or diag explain $r;
    is( $r->{total}, 1, 'one row' );
    like( encode_json( $r->{rows} // [] ), qr/DEFAULT-STORE-ROW/, 'and it is the row' );
};

subtest 'a store at the handler\'s own path reads too' => sub {
    my $r = mcp_call( 'read_form_submissions', form => 'moved' );
    is( $r->{total}, 1, 'the row in the handler\'s own store is found' )
        or diag( 'An empty success here is the defect: the tool looked in the '
            . 'default directory and reported what it found there - nothing.' );
    like( encode_json( $r->{rows} // [] ), qr/MOVED-STORE-ROW/, 'and it is that row' );
    unlike( encode_json($r), qr/forms\/submissions\/moved\.jsonl/,
        'and it does not name a file that is not the store' );
};

subtest 'the two surfaces agree about where the store is' => sub {
    # form-list is what reported has_store: true while MCP said total: 0, so the
    # disagreement is the thing to assert gone.
    require Lazysite::Manager::Plugins;
    require Lazysite::Handlers;
    local $Lazysite::Manager::Common::DOCROOT = $d;
    local $Lazysite::Handlers::DOCROOT        = $d;
    is( Lazysite::Handlers::form_store_file('moved'), "$d/data/enquiries/moved.jsonl",
        'the resolver answers the handler\'s own path' );
    is( Lazysite::Handlers::form_store_file('plain'),
        "$d/lazysite/forms/submissions/plain.jsonl",
        'and the default where no path is named' );
};

done_testing();
