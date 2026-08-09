#!/usr/bin/perl
# SM223 (detector): audit_site reports the static files a protected site is
# serving to anyone who knows the path.
#
# An operator who sets auth_default: required has expressed "this site is
# closed", and the platform accepts the expression - but a .html, .pdf or image
# with no page source is never evaluated against it. On Apache the [L] rewrite
# means the processor never runs; on the engine's own path check_auth sits inside
# a source-file test, so a source-less file skips it by a second, independent
# route. The operator watches every page bounce to the login form, reasonably
# concludes the site is closed, and is still publishing private assets. Nothing
# in the manager, the configuration or the logs contradicts them.
#
# The gap was found in a partner review where a named executive's account of
# their own working life was about to be published as static HTML on the strength
# of a site-wide auth default.
#
# CLOSING it is a behavioural change on upgrade with four open decisions. This is
# the detector, which has none: it needs no reload, breaks nothing, and is what
# tells an operator their configuration and their content disagree.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";

sub build_site {
    my ($auth_default) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/private", "$d/assets" );

    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nmcp_enabled: true\n"
        . ( length $auth_default ? "auth_default: $auth_default\n" : '' );
    close $cf;

    # A normal page: has a source, so it is gated normally and is NOT a finding.
    open my $pg, '>', "$d/index.md" or die $!;
    print {$pg} "---\ntitle: Home\n---\n\nHello.\n";
    close $pg;
    open my $pc, '>', "$d/index.html" or die $!;
    print {$pc} "<html><body>Hello</body></html>";
    close $pc;

    # The reported shape: a single-file browser application with no page source.
    open my $app, '>', "$d/private/participant.html" or die $!;
    print {$app} "<html><body>PRIVATE</body></html>";
    close $app;

    # And a document that is the same exposure in a different wrapper.
    open my $pdf, '>', "$d/private/brief.pdf" or die $!;
    print {$pdf} "%PDF-1.4 fake";
    close $pdf;

    return $d;
}

sub audit {
    my ($d) = @_;
    my $stub = "$d/users-stub.pl";
    open my $sf, '>', $stub or die $!;
    print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
    close $sf;
    chmod 0755, $stub;

    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'audit_site', arguments => {} } } );
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
    my $r = eval { decode_json( $jb // '' ) };
    return $r && $r->{result} ? $r->{result}{structuredContent} : undef;
}

# --- a protected site: the exposure is reported -----------------------------
{
    my $d = build_site('required');
    my $r = audit($d);
    ok( $r && $r->{ok}, 'audit_site answers' ) or diag encode_json( $r // {} );
    is( $r->{site_auth_default}, 'required', 'the site-wide setting is reported' );

    my @u = @{ $r->{unprotected_static_files} || [] };
    ok( ( grep { $_ eq '/private/participant.html' } @u ),
        'a source-less .html on a protected site is reported' )
        or diag encode_json( \@u );
    ok( ( grep { $_ eq '/private/brief.pdf' } @u ),
        'and a PDF - the same exposure in a different wrapper' );
    ok( !( grep { $_ eq '/index.html' } @u ),
        'a rendered page is NOT reported - it has a source and is gated normally' );
}

# --- auth_default: optional is protective too -------------------------------
{
    my $d = build_site('optional');
    my $r = audit($d);
    ok( scalar @{ $r->{unprotected_static_files} || [] },
        'optional counts as protective - it still expresses an access intention' );
}

# --- an OPEN site reports nothing -------------------------------------------
# On a public site these are simply the site's assets. A finding that fires
# everywhere trains its reader to ignore it.
{
    my $d = build_site('');
    my $r = audit($d);
    is( $r->{site_auth_default}, '', 'no auth_default is reported as empty' );
    is_deeply( $r->{unprotected_static_files}, [],
        'an open site reports nothing - this is not noise on every site' );
}

{
    my $d = build_site('none');
    my $r = audit($d);
    is_deeply( $r->{unprotected_static_files}, [],
        'auth_default: none reports nothing either' );
}

# --- the engine tree is never a finding -------------------------------------
{
    my $d = build_site('required');
    my $r = audit($d);
    my @u = @{ $r->{unprotected_static_files} || [] };
    is( scalar( grep {m{^/lazysite}} @u ), 0,
        'lazysite/ and lazysite-assets/ are excluded - they are not content' );
}

done_testing();
