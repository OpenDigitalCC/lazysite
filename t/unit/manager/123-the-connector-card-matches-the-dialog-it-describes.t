#!/usr/bin/perl
# SM621: Claude.ai's Add-custom-connector dialog gained an OAuth client section,
# and its RECOMMENDED default is one this server does not implement.
#
#   "Use Anthropic's hosted client metadata (CIMD)"  - the server fetches
#      Claude's client details from a URL Anthropic hosts. NOT SUPPORTED HERE.
#   "No client ID - register one automatically"      - RFC 7591 dynamic client
#      registration, which lazysite-oauth.pl DOES implement. This is the one.
#
# An operator who takes the recommendation never reaches the sign-in prompt, so
# the one-time connect code the manager just issued has nowhere to go - and the
# failure presents as a bad or expired code rather than a wrong radio button.
# That is why the correction belongs on the CARD, beside the code, and not only
# in the guide: the card is what the operator is looking at when it happens.
#
# The assertions RUN the builder rather than grepping the page. A source grep
# passes on a string that no longer reaches any reader - the lesson SM616's
# first test learned when a sabotage removed the branch that emitted its
# sentences and the test still passed, because the strings survived as
# concatenation fragments.
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

my ($body) = $src =~ /(box\.innerHTML =\s*\n\s*'<div class="mg-onb-card">.*?';)/s;
ok( $body, 'the connector card builder is present' )
    or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/card.js" or die $!;
print {$js} <<"JS";
function escHtml(x) { return String(x == null ? '' : x); }
var box = {};
var ue = 'partner', dom = 'example.test',
    url = 'https://example.test/cgi-bin/lazysite-mcp.pl', code = 'ABCD-1234';
$body
console.log(JSON.stringify({ html: box.innerHTML }));
JS
close $js;

my $got = eval {
    require JSON::PP;
    JSON::PP::decode_json(`\Q$node\E \Q$dir/card.js\E 2>&1`);
};
ok( $got, 'the card rendered' ) or do { done_testing(); exit };
my $html = $got->{html};

# --- the correction reaches the reader --------------------------------------
like( $html, qr/register one automatically/,
    'the card names the OAuth client option that actually works here' );
like( $html, qr/recommended default|not\s+supported/i,
    'and says the recommended default is not the one to take' );

# The point of naming it is that the FAILURE is misleading. An operator who does
# not know this reads "the code did not work" and regenerates it forever.
like( $html, qr/step 3 never appears|never appears/i,
    'and says what going wrong looks like, so a wrong radio is not read as a bad code' );

# --- transport ---------------------------------------------------------------
# The server is POST-only and answers GET with 405, so SSE cannot work. The
# default is already right, which is exactly why it is worth saying: a setting
# nobody mentions is a setting somebody changes.
like( $html, qr/Streamable HTTP/,
    'the card pins the transport that works' );

# --- the card still does its original job ------------------------------------
like( $html, qr/\QABCD-1234\E/, 'the connect code is still rendered' );
like( $html, qr{\Qhttps://example.test/cgi-bin/lazysite-mcp.pl\E},
    'and the connector URL' );

# --- the guide agrees with the card -----------------------------------------
# Two places tell an operator the same thing, and they drifted once already:
# the guide said "leave Advanced settings blank", which was true of the old
# dialog and became wrong without anyone touching it. Pin them to each other.
{
    my $guide = "$FindBin::Bin/../../../starter/docs/ai-connector-setup.md";
    my $g     = do { open my $fh, '<', $guide or die $!; local $/; <$fh> };
    like( $g, qr/register one automatically/,
        'the full guide names the same option as the card' );
    unlike( $g, qr/leave Advanced settings blank/,
        'and no longer says to leave Advanced blank - that was true of the old dialog' );
    like( $g, qr/CIMD/, 'and names CIMD, so a reader can match it to what they see' );
}

done_testing();
