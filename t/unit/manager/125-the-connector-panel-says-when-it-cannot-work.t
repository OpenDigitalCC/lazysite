#!/usr/bin/perl
# SM622: the connector panel checks the services its flow runs on, and says so
# BEFORE the operator commits to a code.
#
# What it did instead: mint a connect code, start a 30-minute countdown, and
# poll for a connection that could not happen - because mcp_enabled or
# oauth_enabled is off, which is the DEFAULT (the 0.9.0 killswitches). Nothing
# on the panel mentioned either. The operator sees a code that did not work,
# with a Regenerate button beside it, so the code gets blamed and re-minted, and
# none of them will ever be asked for.
#
# The warning renders ABOVE the steps, not beside the code: this is the thing to
# do first, and a warning found under the code is a warning found after the code
# has already been tried.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $page = "$FindBin::Bin/../../../starter/manager/users.md";
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# The whole render, from the prereq check through the card, so the warning is
# observed in the HTML a reader gets rather than as a string in the file.
my ($blk) = $src =~ /(\/\/ SM622:.*?box\.innerHTML =\s*\n.*?';)/s;
ok( $blk, 'the panel builder with its prereq check is present' )
    or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
sub render {
    my ($prereqs) = @_;
    open my $js, '>', "$dir/card.js" or die $!;
    print {$js} <<"JS";
function escHtml(x) { return String(x == null ? '' : x); }
var box = { style: {} }, ue='p', dom='example.test',
    url='https://example.test/cgi-bin/lazysite-mcp.pl', code='ABCD-1234';
var d = { prereqs: $prereqs };
$blk
console.log(JSON.stringify({ html: box.innerHTML }));
JS
    close $js;
    require JSON::PP;
    return JSON::PP::decode_json(`\Q$node\E \Q$dir/card.js\E 2>&1`);
}

# --- both services off ------------------------------------------------------
{
    my $r = render('{ web: { ready: false, missing: ["mcp_enabled","oauth_enabled"] } }');
    ok( $r, 'rendered with both services off' ) or do { done_testing(); exit };
    like( $r->{html}, qr/will not connect yet/i, 'the panel says it cannot work yet' );
    like( $r->{html}, qr/MCP connector/, 'naming the MCP service in words, not the conf key' );
    like( $r->{html}, qr/OAuth authorization server/, 'and the OAuth one' );
    like( $r->{html}, qr/Config &rarr; Services|Config &rarr; Services/,
        'and where to turn them on' );

    # The reason this is worth saying at all: without it the CODE gets blamed.
    like( $r->{html}, qr/never asked for|never reaches/,
        'and explains that the code will never be asked for' );

    # Order matters. A warning after the code is read after the code is used.
    cmp_ok( index( $r->{html}, 'will not connect yet' ), '<',
        index( $r->{html}, 'ABCD-1234' ),
        'the warning comes BEFORE the connect code' );
}

# --- one service off: the sentence still reads --------------------------------
# Singular/plural is not cosmetic here; "which are switched off" about one
# service reads as a bug and undermines the warning.
{
    my $r = render('{ web: { ready: false, missing: ["oauth_enabled"] } }');
    like( $r->{html}, qr/OAuth authorization server, which is switched off/,
        'one missing service reads in the singular' );
    unlike( $r->{html}, qr/which are switched off/, 'and not the plural' );
}

# --- ready: no warning at all -------------------------------------------------
{
    my $r = render('{ web: { ready: true, missing: [] } }');
    unlike( $r->{html}, qr/will not connect yet/i,
        'a ready site gets no warning' );
    like( $r->{html}, qr/ABCD-1234/, 'and still gets its connect code' );
}

# --- an older server that sends no prereqs at all -----------------------------
# The panel is served from the site tree and the API from the engine, and they
# can be different versions mid-upgrade. Absent must mean silent, never a
# warning invented from missing data.
{
    my $r = render('undefined');
    unlike( $r->{html}, qr/will not connect yet/i,
        'no prereq data means no warning, rather than a warning from nothing' );
    like( $r->{html}, qr/ABCD-1234/, 'and the panel still works' );
}

done_testing();
