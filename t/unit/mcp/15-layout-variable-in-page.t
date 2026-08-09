#!/usr/bin/perl
# SM249: using a LAYOUT variable in a page body is warned about, because the
# alternative is silence.
#
# theme_assets, theme_name, theme and theme_css resolve in layout.tt and not in a
# page body. Template Toolkit substitutes an undefined variable with the empty
# string, so `<img src="[% theme_assets %]/hero.jpg">` renders as src="/hero.jpg",
# resolves against the domain root and 404s - with no error, no warning and no
# log line. The broken result looks like a typo in the filename rather than a
# scope problem, which is what makes it expensive: one agent used the pattern in
# all seven of its replacement image blocks and recovering it cost a handover.
#
# It is a reasonable thing to write. It is the pattern the site's own layout.tt
# uses, and nothing said the scope differed. So this warns at the point the
# mistake is made and names the literal path to use instead.
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
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'validate_page', arguments => { content => $content } } } );
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

# --- the reported case ------------------------------------------------------
{
    my $r = validate("# Page\n\n<img src=\"[% theme_assets %]/hero.jpg\">\n");
    ok( $r && $r->{ok}, 'validate_page answers' ) or diag encode_json( $r // {} );
    ok( ( grep { $_ eq 'layout-variable-in-page' } kinds($r) ),
        'theme_assets in a page body is warned about' );

    my ($w) = grep { ( $_->{kind} // '' ) eq 'layout-variable-in-page' }
        @{ $r->{warnings} || [] };
    like( $w->{message}, qr/theme_assets/, 'the message names the variable used' );
    like( $w->{message}, qr{/lazysite-assets/},
        'and gives the literal path to use instead - naming the alternative, not '
            . 'just the prohibition' );
    like( $w->{message}, qr/empty string|resolves to nothing/,
        'and explains WHY it fails silently' );
}

# --- the other layout-scope variables ---------------------------------------
for my $v (qw(theme_css theme_name)) {
    my $r = validate("# Page\n\n[% $v %]\n");
    ok( ( grep { $_ eq 'layout-variable-in-page' } kinds($r) ), "$v is warned about too" );
}

# --- a page using ORDINARY variables is left alone --------------------------
# Site and page variables are legitimate in a body; warning on those would train
# the reader to ignore this.
{
    my $r = validate("# Page\n\nVersion [% latest_release %], [% site_name %].\n");
    is( scalar( grep { $_ eq 'layout-variable-in-page' } kinds($r) ), 0,
        'an ordinary TT variable raises nothing' );
}

# --- a page with no TT at all ------------------------------------------------
{
    my $r = validate("# Page\n\nJust prose.\n");
    is( scalar( grep { $_ eq 'layout-variable-in-page' } kinds($r) ), 0,
        'plain content raises nothing' );
}

# --- it is a WARNING, never a refusal ---------------------------------------
# There are legitimate reasons to write the token (documenting it, for one), and
# a platform that refused would be wrong more often than the authors it protects.
{
    my $r = validate("# Page\n\n<img src=\"[% theme_assets %]/x.jpg\">\n");
    ok( $r->{ok}, 'the page still validates - warned, not refused' );
}

done_testing();
