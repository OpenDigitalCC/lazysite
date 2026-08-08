#!/usr/bin/perl
# Behaviour coverage for the tools 0.10.3 adds to the MCP surface: upload_file
# (SM240), the domain trio (SM238), the page-body warnings (SM243) and the
# starter-page report (SM244).
#
# WHY THIS EXISTS. Those four went in with tests that read the SOURCE - asserting
# a warning string is present, a tool is declared, a parameter exists. Those are
# real checks and they stay, but they execute none of the code, so the release
# added a large amount of branching to lazysite-mcp.pl and no coverage for it:
# the gate's branch floor for that file went under and failed the release. Shape
# tests cannot catch a tool that is declared correctly and does the wrong thing.
#
# So this drives the tools through the real JSON-RPC entry point, over a real
# docroot, and asserts what changed ON DISK or came back in the response.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use MIME::Base64 qw(encode_base64);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $base = tempdir( CLEANUP => 1 );

# SM257: the docroot sits UNDER the temp dir rather than being it, because the
# processor is resolved at $DOCROOT/../cgi-bin/ - so a preview can only render if
# there is somewhere above the docroot to put it. With the docroot as the temp
# dir itself, that path escapes into /tmp and the render can never succeed.
# Before SM257 that did not show up, because a failed render reported ok:1.
my $d = "$base/site";
make_path( "$base/cgi-bin", "$d/lazysite/auth",
    "$d/lazysite/layouts/base/themes/blue",
    "$d/lazysite/layouts/alt/themes/red", "$d/sites/clienta", "$d/content" );
symlink "$root/lazysite-processor.pl", "$base/cgi-bin/lazysite-processor.pl"
    or die "cannot link the processor: $!";

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\nmcp_enabled: true\nlayout: base\ntheme: blue\n"
    . "alias_hosts: shop.clienta.com\n"
    . "alias.shop.clienta.com.content_root: sites/clienta\n"
    . "alias.shop.clienta.com.layout: base\n";
close $cf;

for my $f ( [ "$d/index.md", "# Home\n" ], [ "$d/sites/clienta/index.md", "# Client A\n" ] ) {
    open my $fh, '>', $f->[0] or die $!;
    print {$fh} $f->[1];
    close $fh;
}
open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} '[% content %]';
close $lt;
open my $lt2, '>', "$d/lazysite/layouts/alt/layout.tt" or die $!;
print {$lt2} '[% content %]';
close $lt2;
for my $t ( [ 'base', 'blue' ], [ 'alt', 'red' ] ) {
    open my $th, '>', "$d/lazysite/layouts/$t->[0]/themes/$t->[1]/theme.json" or die $!;
    print {$th} qq({"name":"$t->[1]","version":"1.0.0","layouts":["$t->[0]"],"config":{}});
    close $th;
}

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my $u  = $r->{username} // '';
my %caps = ( mcp => 1, manage_content => 1, manage_domains => 1,
             manage_themes => 1, manage_layouts => 1 );
delete $caps{manage_domains} if $u =~ /nodom/;
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $extra{auth} if defined $extra{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub call {
    return mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $_[0], arguments => $_[1] || {} } }, auth => $_[2] );
}
sub sc { my $r = shift; return $r && $r->{result} ? $r->{result}{structuredContent} : undef }
sub slurp {
    my $p = shift;
    open my $fh, '<:raw', $p or return undef;
    my $c = do { local $/; <$fh> };
    close $fh;
    return $c;
}

my $ok    = 'Bearer agent:lzs_tok';
my $nodom = 'Bearer nodomagent:lzs_tok';

# =========================================================================
# SM240: upload_file
# =========================================================================
#
# A one-pixel GIF: real binary, with bytes outside the printable range and an
# embedded NUL, so a text path would visibly corrupt it.
my $GIF = pack 'H*',
    '47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b';

{
    my $r = sc( call( 'upload_file',
        { path => 'assets/pixel.gif', content_base64 => encode_base64( $GIF, '' ) }, $ok ) );
    ok( $r && $r->{ok}, 'upload_file writes a binary file' ) or diag encode_json( $r // {} );
    is( slurp("$d/assets/pixel.gif"), $GIF,
        'and the bytes on disk are byte-identical - the whole point of the tool' );
}

# Whitespace in the payload is normal in JSON transport and must not break it.
{
    my $b64 = encode_base64( $GIF, "\n" );
    my $r = sc( call( 'upload_file',
        { path => 'assets/wrapped.gif', content_base64 => $b64 }, $ok ) );
    ok( $r && $r->{ok}, 'upload_file accepts newline-wrapped base64' );
    is( slurp("$d/assets/wrapped.gif"), $GIF, 'and still decodes exactly' );
}

# The refusal branches. Each must refuse rather than write something wrong.
{
    my $bad = sc( call( 'upload_file',
        { path => 'assets/bad.gif', content_base64 => 'not base64 !!!' }, $ok ) );
    ok( $bad && !$bad->{ok}, 'upload_file refuses payload outside the base64 alphabet' );
    is( $bad->{kind}, 'bad-encoding', 'reported as bad-encoding' );
    ok( !-e "$d/assets/bad.gif", 'and nothing was written' );

    my $exe = sc( call( 'upload_file',
        { path => 'evil.cgi', content_base64 => encode_base64( $GIF, '' ) }, $ok ) );
    ok( $exe && !$exe->{ok}, 'upload_file refuses an executable extension' );
    ok( !-e "$d/evil.cgi", 'and nothing was written' );

    my $engine = sc( call( 'upload_file',
        { path => 'lazysite/lazysite.conf', content_base64 => encode_base64( 'x', '' ) }, $ok ) );
    ok( $engine && !$engine->{ok}, 'upload_file refuses an engine-owned path' );
}

# =========================================================================
# SM238: the domain trio
# =========================================================================
{
    my $r = sc( call( 'list_domains', {}, $ok ) );
    ok( $r && $r->{ok}, 'list_domains answers' ) or diag encode_json( $r // {} );
    my @hosts = map { $_->{host} // '' } @{ $r->{domains} // [] };
    ok( ( grep { $_ eq 'shop.clienta.com' } @hosts ),
        'and includes the registered domain' );

    # A capability refusal comes back as a JSON-RPC error with NO
    # structuredContent, so it must be judged on the raw response - reading it
    # through sc() alone turns a correct refusal into undef.
    my $raw    = call( 'list_domains', {}, $nodom );
    my $denied = sc($raw);
    ok( !$denied || !$denied->{ok}, 'list_domains needs manage_domains' )
        or diag encode_json( $raw // {} );
}

{
    my $r = sc( call( 'domain_set',
        { host => 'shop.clienta.com', key => 'site_name', value => 'Client A' }, $ok ) );
    ok( $r && $r->{ok}, 'domain_set writes a presentation key' ) or diag encode_json( $r // {} );
    like( slurp("$d/lazysite/lazysite.conf"),
        qr/^alias\.shop\.clienta\.com\.site_name: Client A$/m,
        'and the conf carries it' );

    # content_root is refused BY THIS TOOL specifically - repointing a live
    # domain is a migration, and the refusal names where that lives.
    my $cr = sc( call( 'domain_set',
        { host => 'shop.clienta.com', key => 'content_root', value => 'sites/other' }, $ok ) );
    ok( $cr && !$cr->{ok}, 'domain_set refuses content_root' );
    like( $cr->{error}, qr/site_apply/, 'and names the tool that does take a snapshot' );

    my $unknown = sc( call( 'domain_set',
        { host => 'nope.example', key => 'site_name', value => 'X' }, $ok ) );
    ok( $unknown && !$unknown->{ok}, 'domain_set refuses an unregistered host' );
}

{
    my $r = sc( call( 'preview_domain', { host => 'shop.clienta.com' }, $ok ) );
    ok( $r && $r->{ok}, 'preview_domain renders' ) or diag encode_json( $r // {} );
    is( $r->{host}, 'shop.clienta.com', 'the result names the host it rendered' );
    # SM257: THIS is the assertion the tool exists to support, and before SM257
    # it could not be made - a render producing nothing came back as ok:1 with an
    # empty body, so the test could neither pass nor fail meaningfully.
    like( $r->{html} // '', qr/Client A/,
        "and renders THAT domain's content root, not the primary's" );

    my $unknown = sc( call( 'preview_domain', { host => 'nope.example' }, $ok ) );
    ok( $unknown && !$unknown->{ok}, 'preview_domain refuses an unregistered host' );
}

# The host parameter is the SM238 safety mechanism: without it these are
# instance-wide. Both branches must work and must not bleed into each other.
{
    my $scoped = sc( call( 'activate_layout',
        { layout => 'alt', host => 'shop.clienta.com' }, $ok ) );
    ok( $scoped && $scoped->{ok}, 'activate_layout with host binds one domain' )
        or diag encode_json( $scoped // {} );
    my $conf = slurp("$d/lazysite/lazysite.conf");
    like( $conf, qr/^alias\.shop\.clienta\.com\.layout: alt$/m, 'the domain moved' );
    like( $conf, qr/^layout: base$/m,
        'and the INSTANCE-WIDE layout is untouched - the case that used to restyle every site' );
}

# =========================================================================
# SM243: the page-body warnings reach the write path
# =========================================================================
#
# Every one of these WRITES - they are warnings, not refusals. Assert both:
# the warning came back, and the page still landed.
{
    my %CASES = (
        'document-in-page' => "<!DOCTYPE html>\n<html><body>hi</body></html>\n",
        'style-block-in-page' => "# T\n\n<style>body{color:red}</style>\n",
        'chrome-in-page'      => "# T\n\n<nav><a href=\"/\">Home</a></nav>\n",
    );
    for my $kind ( sort keys %CASES ) {
        ( my $slug = $kind ) =~ s/[^a-z]+/-/g;
        my $r = sc( call( 'write_file',
            { path => "content/$slug.md", content => $CASES{$kind} }, $ok ) );
        ok( $r && $r->{ok}, "write_file still writes despite '$kind'" )
            or diag encode_json( $r // {} );
        ok( -e "$d/content/$slug.md", "and $slug.md is on disk - warned, not refused" );
        my @kinds = map { $_->{kind} // '' } @{ $r->{warnings} // [] };
        ok( ( grep { $_ eq $kind } @kinds ), "and '$kind' was reported" )
            or diag "warnings: @kinds";
    }

    # An ordinary page must come back clean, or the warnings are noise.
    my $clean = sc( call( 'write_file',
        { path => 'content/plain.md', content => "# Title\n\nA paragraph.\n" }, $ok ) );
    ok( $clean && $clean->{ok}, 'an ordinary page writes' );
    my @w = grep { ( $_->{kind} // '' ) =~ /in-page/ } @{ $clean->{warnings} || [] };
    is( scalar @w, 0, 'and raises none of the body warnings' )
        or diag encode_json( $clean->{warnings} );
}

# =========================================================================
# SM244: audit_site reports the starter pages
# =========================================================================
{
    # The marker is `provenance: lazysite-starter` in the page front matter,
    # and pages are enumerated from the content root - so it has to be a real
    # page, not a file parked in a directory of its own.
    open my $sp, '>', "$d/welcome.md" or die $!;
    print {$sp} "---\ntitle: Welcome\nprovenance: lazysite-starter\n---\n\nHello.\n";
    close $sp;

    my $r = sc( call( 'audit_site', {}, $ok ) );
    ok( $r && $r->{ok}, 'audit_site answers' ) or diag encode_json( $r // {} );
    ok( exists $r->{starter_pages}, 'and reports starter_pages as its own category' );
    ok( exists $r->{starter_in_sitemap},
        'plus the sitemap count - the ratio is what makes an untouched scaffold obvious' );
    my @paths = map { ref $_ ? ( $_->{page} // $_->{slug} // '' ) : $_ }
        @{ $r->{starter_pages} || [] };
    ok( ( grep {m{welcome}} @paths ),
        'the marked page is listed by reading the provenance marker' )
        or diag encode_json( $r->{starter_pages} // [] );
}

# =========================================================================
# SM243: a rename offers the alias its retired URL needs
# =========================================================================
{
    # The page carries front matter DELIBERATELY. add_alias only extends an
    # existing `---` block: a page without one gets no alias written, while the
    # result still reports ok:1 with alias_suggested set. That is SM256, found
    # by this test when its first fixture page had no front matter. Testing the
    # supported path here rather than pinning the gap as intended behaviour.
    my $mk = sc( call( 'write_file',
        { path    => 'content/old-name.md',
            content => "---\ntitle: Old\n---\n\nBody.\n" }, $ok ) );
    ok( $mk && $mk->{ok}, 'a page to rename' );

    my $r = sc( call( 'rename_page',
        { old => 'content/old-name.md', new => 'content/new-name.md' }, $ok ) );
    ok( $r && $r->{ok}, 'rename_page renames' ) or diag encode_json( $r // {} );
    ok( $r->{alias_suggested}, 'and REPORTS the alias the retired URL needs' );
    unlike( slurp("$d/content/new-name.md") // '', qr/aliases:/,
        'but does not write it unasked - that would edit an unpublished page silently' );

    my $r2 = sc( call( 'rename_page',
        { old => 'content/new-name.md', new => 'content/final-name.md',
            add_alias => JSON::PP::true() }, $ok ) );
    ok( $r2 && $r2->{ok}, 'rename_page with add_alias renames' ) or diag encode_json( $r2 // {} );
    like( slurp("$d/content/final-name.md") // '', qr/aliases:/,
        'and writes the alias when asked' );
    ok( $r2->{alias_added}, 'and SAYS it wrote it' );
}

# --- SM256: a page with NO front matter still gets its alias -----------------
# Front matter is optional in lazysite. This branch used to do nothing at all and
# still return ok:1 with alias_suggested set, which reads as "added" - so the
# retired URL 404s and the caller has been told the opposite. An old
# hand-written page is if anything the MOST likely to have no front matter and
# the most likely to have a published URL worth keeping.
{
    my $mk = sc( call( 'write_file',
        { path => 'content/bare.md', content => "# Bare\n\nNo front matter here.\n" }, $ok ) );
    ok( $mk && $mk->{ok}, 'a page with no front matter' );

    my $r = sc( call( 'rename_page',
        { old => 'content/bare.md', new => 'content/bare-moved.md',
            add_alias => JSON::PP::true() }, $ok ) );
    ok( $r && $r->{ok}, 'rename_page renames it' ) or diag encode_json( $r // {} );
    ok( $r->{alias_added}, 'and reports the alias as ADDED' );

    my $c = slurp("$d/content/bare-moved.md") // '';
    like( $c, qr/\A---\s*\naliases:\n  - \/content\/bare\n---\s*\n/,
        'a front-matter block was created carrying the alias' );
    like( $c, qr/# Bare/,        'and the body survived' );
    like( $c, qr/No front matter here/, 'intact' );
}

# --- SM256: an alias already present is success, not failure ----------------
# Renaming back and forth must not report a problem the second time. This is the
# case that shared a signal with "could not add it" before.
{
    my $there = sc( call( 'rename_page',
        { old => 'content/bare-moved.md', new => 'content/bare-again.md',
            add_alias => JSON::PP::true() }, $ok ) );
    ok( $there && $there->{ok}, 'a second rename works' );
    ok( $there->{alias_added}, 'the NEW old-url is added' );

    # Now rename back: the alias for this path is already listed.
    my $back = sc( call( 'rename_page',
        { old => 'content/bare-again.md', new => 'content/bare-moved.md',
            add_alias => JSON::PP::true() }, $ok ) );
    ok( $back && $back->{ok}, 'renaming back works' );
    my $c = slurp("$d/content/bare-moved.md") // '';
    my @dupes = $c =~ m{- /content/bare-again}g;
    is( scalar @dupes, 1, 'and the alias is not duplicated' );
}

done_testing();
