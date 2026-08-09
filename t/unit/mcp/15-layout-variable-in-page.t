#!/usr/bin/perl
# SM249: the theme variables work in a page body, so validate_page does NOT warn
# about them.
#
# This file used to assert the opposite. theme_assets, theme_name, theme and
# theme_css resolved in layout.tt and not in a page body, and Template Toolkit
# substitutes an undefined variable with the empty string - so
# `<img src="[% theme_assets %]/hero.jpg">` rendered as src="/hero.jpg",
# resolved against the domain root and 404'd, with no error, no warning and no
# log line. One agent used the pattern in all seven of its replacement image
# blocks and recovering it cost a handover. The warning existed because the
# alternative was silence.
#
# The engine now resolves the layout and the active theme BEFORE rendering the
# body, so the pattern works and the warning would be false. It is removed
# rather than softened: a warning describing a constraint that no longer exists
# teaches an author to hard-code /lazysite-assets/<layout>/<theme>/..., which
# then goes stale the next time the site's theme changes - in order to avoid a
# failure that cannot happen.
#
# So this file is now a guard against reintroducing it. That the variables
# actually resolve is t/unit/processor/19-d013-layout-theme.t's subject; this
# one only checks that the authoring surface has stopped saying they do not.
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
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/content" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub validate {
    my ($content) = @_;
    my $body = encode_json(
        {   jsonrpc => '2.0',
            id      => 1,
            method  => 'tools/call',
            params  => { name => 'validate_page', arguments => { content => $content } }
        }
    );
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

sub kinds {
    my ($r) = @_;
    return map { $_->{kind} // '' } @{ $r->{warnings} || [] };
}

# --- the reported case, which is now correct authoring ----------------------
{
    my $r = validate("# Page\n\n<img src=\"[% theme_assets %]/hero.jpg\">\n");
    ok( $r && $r->{ok}, 'validate_page answers' ) or diag encode_json( $r // {} );
    is( scalar( grep { $_ eq 'layout-variable-in-page' } kinds($r) ),
        0, 'theme_assets in a page body is no longer warned about' );
}

# --- and the other variables that used to be warned about -------------------
for my $v (qw(theme_css theme_name theme)) {
    my $r = validate("# Page\n\n[% $v %]\n");
    is( scalar( grep { $_ eq 'layout-variable-in-page' } kinds($r) ),
        0, "$v raises no layout-scope warning either" );
}

# --- no warning anywhere still names the retired constraint ------------------
# Removing the `kind` but leaving the explanation in some other warning's text
# would keep teaching the same wrong thing.
{
    my $r = validate("# Page\n\n<img src=\"[% theme_assets %]/hero.jpg\">\n");
    my @msgs = map { $_->{message} // '' } @{ $r->{warnings} || [] };
    is( scalar( grep {/resolves to nothing in a page body/} @msgs ),
        0, 'no warning still claims layout variables do not resolve in a body' );
}

# --- the unrelated checks are untouched --------------------------------------
# validate_page still warns about the things it should; this change removed one
# warning, not the surface.
{
    my $r = validate("# Page\n\n<nav><a href=\"/\">Home</a></nav>\n");
    ok( ( grep { $_ eq 'chrome-in-page' } kinds($r) ),
        'chrome-in-page still fires - the other checks are intact' );
}

done_testing();
