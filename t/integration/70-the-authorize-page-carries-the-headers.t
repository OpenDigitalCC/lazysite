#!/usr/bin/perl
# SM429: the OAuth consent page carries the security header set - measured on
# the REAL page, as the filing asked, "rather than asserting the string
# appears in the source".
#
# Following that advice found more than the missing COOP: lazysite-oauth.pl
# hand-prints every response and predates SM352's consolidation, so the
# consent page - the surface where a human authorises a connector to act as
# a partner - answered with NO security headers at all. Nobody measuring the
# homepage would ever see it, which is SM352's founding observation on a
# fifth response path.
#
# The rig uses the script's own front door end to end: RFC 7591 dynamic
# registration mints the client, then a GET authorize with PKCE params
# reaches the consent page exactly as a connector would.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(repo_root env_passthrough);
use Lazysite::SecurityHeaders ();

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\noauth_enabled: true\n";
close $cf;

sub oauth {
    my ( $method, $qs, $body ) = @_;
    my $bf = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} ( $body // '' );
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => $method,
        QUERY_STRING   => $qs,
        CONTENT_LENGTH => length( $body // '' ),
        CONTENT_TYPE   => 'application/json',
        REMOTE_ADDR    => '127.0.0.1',
    );
    return qx($^X \Q$root/lazysite-oauth.pl\E < \Q$bf\E 2>/dev/null);
}

# Step 1: the script's own registration endpoint mints the client.
my $reg = oauth( 'POST', 'action=register',
    encode_json( { client_name => 'Header probe',
            redirect_uris => ['https://probe.example/cb'] } ) );
my ($rj) = $reg =~ /\r?\n\r?\n(.*)/s;
my $client = eval { decode_json($rj) } || {};
ok( $client->{client_id}, 'client registered through the front door' )
    or do { diag($reg); done_testing(); exit };

# Step 2: the consent page, reached as a connector reaches it.
my $qs = join '&',
    'action=authorize',
    "client_id=$client->{client_id}",
    'redirect_uri=https%3A%2F%2Fprobe.example%2Fcb',
    'response_type=code',
    'code_challenge_method=S256',
    'code_challenge=abcabcabcabcabcabcabcabcabcabcabcabcabcabca';
my $page = oauth( 'GET', $qs );

subtest 'the consent page is the consent page' => sub {
    like( $page, qr/Status: 200/,          'served' );
    like( $page, qr/Authorise connection/, 'and is the consent page, not an error' );
};

subtest 'AND IT CARRIES THE FULL HTML HEADER SET' => sub {
    for my $name ( map { (/^([^:]+):/)[0] }
        Lazysite::SecurityHeaders::security_headers( https => 0, html => 1 ) )
    {
        like( $page, qr/^\Q$name\E:\s*\S/mi, "carries $name" )
            or diag( 'An authorisation surface without the set is SM352\'s '
                . 'founding observation on a fifth response path.' );
    }
    like( $page, qr/^Cross-Origin-Opener-Policy:\s*same-origin-allow-popups\s*$/mi,
        'COOP at the popup-preserving value - this page IS the popup flow' );
};

done_testing();
