#!/usr/bin/perl
# SM250: audit_site reports a theme whose content is invisible until a script
# runs.
#
# A scroll-reveal pattern - `.rv { opacity: 0 }` plus a script adding `.in` -
# leaves content invisible to a visitor with JavaScript blocked, to most
# crawlers, and to anything extracting text. It degrades badly on its own terms,
# before anyone breaks it.
#
# It earns a MECHANICAL check because the failure is silent, total below the
# fold, and survives the obvious verification: an agent removed the page script
# while moving chrome into a layout and left every section of a live site
# permanently invisible. The hero sat outside the pattern, so four successive
# visual checks looked fine.
#
# The reduced-motion rule is the trap, not the remedy. It reaches only visitors
# who asked for reduced motion, and reading it as a neutraliser is what caused
# the incident - so it must NOT count as a fallback.
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

sub site_with {
    my (%themes) = @_;    # name => css
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nmcp_enabled: true\nlayout: base\n";
    close $cf;
    open my $ix, '>', "$d/index.md" or die $!;
    print {$ix} "# Home\n";
    close $ix;
    for my $t ( sort keys %themes ) {
        make_path("$d/lazysite/layouts/base/themes/$t/assets");
        open my $tj, '>', "$d/lazysite/layouts/base/themes/$t/theme.json" or die $!;
        print {$tj} qq({"name":"$t","version":"1.0.0","layouts":["base"],"config":{}});
        close $tj;
        open my $cs, '>', "$d/lazysite/layouts/base/themes/$t/assets/main.css" or die $!;
        print {$cs} $themes{$t};
        close $cs;
    }
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

sub themes_flagged {
    my ($r) = @_;
    return map { $_->{theme} } @{ $r->{hidden_by_script} || [] };
}

# --- the reported pattern is reported ---------------------------------------
{
    my $d = site_with( reveal => <<'CSS' );
.rv    { opacity: 0; transform: translateY(22px); }
.rv.in { opacity: 1; transform: none; }
CSS
    my $r = audit($d);
    ok( $r && $r->{ok}, 'audit_site answers' ) or diag encode_json( $r // {} );
    ok( ( grep { $_ eq 'base/reveal' } themes_flagged($r) ),
        'a theme hiding content by default is reported' )
        or diag encode_json( $r->{hidden_by_script} // [] );
}

# --- prefers-reduced-motion is NOT a fallback -------------------------------
# The specific thing that misled a careful reader. If this stopped counting as a
# finding, the guard would miss the exact case it was built for.
{
    my $d = site_with( reveal => <<'CSS' );
.rv    { opacity: 0; }
.rv.in { opacity: 1; }
@media (prefers-reduced-motion: reduce) { .rv { opacity: 1; } }
CSS
    my $r = audit($d);
    ok( ( grep { $_ eq 'base/reveal' } themes_flagged($r) ),
        'a reduced-motion rule does not excuse it - it reaches only visitors who '
            . 'asked for reduced motion' );
}

# --- a real no-JS fallback IS accepted --------------------------------------
# The pattern is legitimate with one, so flagging it would be the false positive
# that trains an operator to ignore this.
{
    my $d = site_with( reveal => <<'CSS' );
.rv    { opacity: 0; }
.rv.in { opacity: 1; }
.no-js .rv { opacity: 1; }
CSS
    my $r = audit($d);
    is( scalar( grep { $_ eq 'base/reveal' } themes_flagged($r) ), 0,
        'a .no-js fallback is accepted' );
}

# --- an ordinary theme is untouched -----------------------------------------
{
    my $d = site_with( plain => "body { color: #222; }\n.card { opacity: 1; }\n" );
    my $r = audit($d);
    is_deeply( $r->{hidden_by_script}, [],
        'a theme that hides nothing raises nothing' );
}

# --- opacity: 0.5 is not opacity: 0 -----------------------------------------
# A decimal must not be read as the zero case, or every faded element is a
# finding.
{
    my $d = site_with( faded => ".muted { opacity: 0.55; }\n" );
    my $r = audit($d);
    is_deeply( $r->{hidden_by_script}, [],
        'a fractional opacity is not the hidden-by-default pattern' );
}

# --- visibility: hidden counts too ------------------------------------------
{
    my $d = site_with( vis => ".rv { visibility: hidden; }\n.rv.in { visibility: visible; }\n" );
    my $r = audit($d);
    ok( ( grep { $_ eq 'base/vis' } themes_flagged($r) ),
        'visibility:hidden is the same failure in a different property' );
}

done_testing();
