#!/usr/bin/perl
# SM260: a partner grant never learns the server's filesystem layout.
#
# audit_site returned the absolute docroot - "/home/<account>/web/<site>/public_html" -
# to any token or MCP client. That contradicts the position the platform states
# in .well-known/ai-partner, where analytics is "sanitised + IP-anonymised, never
# the raw log or A PATH", and it reaches further than an API response: an MCP
# client is often a conversational assistant, so the value lands in a transcript
# held by a third party. On shared hosting the account name is the more useful
# half of the disclosure.
#
# WHY A SWEEP RATHER THAN AN ASSERTION ON ONE FIELD. The leak was a one-line
# list-assignment mistake in a field nobody was watching; the next one will be
# somewhere else. So this drives the read-only partner surface and asserts that
# NO response body carries an absolute filesystem path, wherever it appears and
# however deeply nested.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../..";
my $mcp  = "$root/lazysite-mcp.pl";

# A docroot whose path is DISTINCTIVE, so a leak cannot hide in a common word.
my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/hostingacct/web/example.test/public_html";
make_path( "$d/lazysite/auth", "$d/lazysite/layouts/base/themes/blue", "$d/content" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Example\nmcp_enabled: true\nlayout: base\ntheme: blue\n";
close $cf;
open my $ix, '>', "$d/index.md" or die $!;
print {$ix} "---\ntitle: Home\nprovenance: lazysite-starter\n---\n\n# Home\n\n[gone](/missing)\n";
close $ix;
open my $pg, '>', "$d/content/thing.md" or die $!;
print {$pg} "# Thing\n\nBody.\n";
close $pg;
open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} '[% content %]';
close $lt;
open my $th, '>', "$d/lazysite/layouts/base/themes/blue/theme.json" or die $!;
print {$th} '{"name":"blue","version":"1.0.0","layouts":["base"],"config":{}}';
close $th;

# A stale .html with no .md source - the very thing audit_site's stale scan is
# for. It must be FOUND (site-relative), which also proves the scan runs at all.
open my $st, '>', "$d/orphan.html" or die $!;
print {$st} "<html><body>stale</body></html>";
close $st;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => {
    mcp => 1, manage_content => 1, manage_domains => 1,
    manage_themes => 1, manage_layouts => 1, read_submissions => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub call {
    my ( $name, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return $jb // '';
}

# The read-only surface a partner can reach without changing anything. Each is
# checked as RAW JSON, so a path nested anywhere - inside an array, a message
# string, an error - is still caught.
my @READ_ONLY = (
    [ 'audit_site',            {} ],
    [ 'whoami',                {} ],
    [ 'describe_capabilities', {} ],
    [ 'list_pages',            {} ],
    [ 'list_files',            { path => '/' } ],
    [ 'list_themes',           {} ],
    [ 'list_domains',          {} ],
    [ 'page_status',           { slug => 'index' } ],
    [ 'read_page',             { slug => 'index' } ],
    [ 'validate_page',         { slug => 'index' } ],
    [ 'search_files',          { query => 'Thing' } ],
    [ 'list_content_history',  {} ],
    [ 'list_form_handlers',    {} ],
    [ 'read_file',             { path => 'content/thing.md' } ],
);

for my $c (@READ_ONLY) {
    my ( $name, $args ) = @$c;
    my $json = call( $name, $args );

    # The docroot itself, and the account-name segment on its own. The second
    # matters independently: a partial path is still a disclosure.
    unlike( $json, qr/\Q$d\E/,          "$name does not return the docroot path" );
    unlike( $json, qr/\Q$base\E/,       "$name does not return the path above it" );
    unlike( $json, qr{hostingacct},     "$name does not name the hosting account" );

    # Any absolute path that looks like a server location rather than a site URL.
    # Site-relative values start "/" and are matched by the site namespace, so
    # this looks for the filesystem prefixes a docroot actually lives under.
    unlike( $json, qr{"/(?:home|srv|var|usr|opt|tmp|root)/}, "$name returns no filesystem path" );
}

# --- and the scan it was supposed to be doing actually runs ------------------
# The disclosure and the dead feature were the same line, so fixing one without
# the other would be half a fix.
{
    my $json = call( 'audit_site', {} );
    my $r = eval { decode_json($json) };
    my $sc = $r && $r->{result} ? $r->{result}{structuredContent} : undef;
    ok( $sc && $sc->{ok}, 'audit_site answers' ) or diag $json;

    my @stale = @{ $sc->{stale_html} // [] };
    ok( ( grep { $_ eq '/orphan.html' } @stale ),
        'the stale .html is FOUND, site-relative - the scan never ran before' )
        or diag encode_json( \@stale );
    is( scalar( grep {m{^/(?:home|srv|var|usr|opt|tmp|root)/}} @stale ), 0,
        'and no entry is a filesystem path' );
}

done_testing();
