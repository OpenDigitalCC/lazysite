#!/usr/bin/perl
# SM790. The connector module's stated model is that the risk of an outbound
# call is not what the remote does, it is who can cause the call. That is right
# about the TRIGGER and silent about the RESPONSE - and the response is not the
# operator's choice.
#
# Three LWP defaults were doing the deciding: GET is redirectable, custom
# headers are NOT stripped across a redirect, and there is no size cap. So a
# remote that was legitimately configured and later compromised could send the
# call to a link-local metadata address WITH THE OPERATOR'S CREDENTIAL
# ATTACHED, and could return a body of any size at all.
#
# SM579 phase 2 is why this is urgent rather than tidy: scheduled invocation
# now makes that call unattended, in the long-lived daemon, with nobody
# watching what comes back.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub src {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or die "$f: $!";
    local $/;
    return <$fh>;
}
my $conn = src('lib/Lazysite/Manager/Connectors.pm');
my $form = src('plugins/form-handler.pl');

# The reference this is measured against, so the test says WHICH bounds rather
# than "some bounds": Fetch was hardened for exactly this under SEC-2026-07 H6.
my $fetch = src('lib/Lazysite/Fetch.pm');

subtest 'the reference carries the bounds this is copying' => sub {
    like( $fetch, qr/max_redirect\s*=>\s*0/, 'Fetch disables automatic redirects' );
    like( $fetch, qr/max_size\s*=>/,         'and caps the body' );
};

subtest 'the connector user agent is bounded' => sub {
    my ($ua) = $conn =~ /(my \$ua = LWP::UserAgent->new\(.*?\);)/s;
    ok( $ua, 'the agent construction was found' ) or return;
    like( $ua, qr/max_redirect\s*=>\s*0/,
        'it does not follow a redirect - which closes the credential leak '
            . 'outright rather than by remembering to strip a header' );
    like( $ua, qr/max_size\s*=>\s*\$ANSWER_CAP/,
        'and caps the body at the same number the stored answer is capped at' );
};

subtest 'a redirect is a failed call, named as one' => sub {
    like( $conn, qr/\$res->is_redirect/, 'the redirect case is handled explicitly' );
    my ($blk) = $conn =~ /(if \( \$res->is_redirect \).*?\n    \})/s;
    ok( $blk, 'the redirect branch was found' ) or return;
    like( $blk, qr/_refused/, 'it is recorded as a refusal, not a success' );
    like( $blk, qr/credential would travel with it/,
        'and says WHY it is not followed, so "reconfigure it" is the remedy '
            . 'rather than "follow it for me"' );
};

# The change that would have been wrong, asserted as absent so nobody adds it
# back without meeting the argument.
subtest 'the CONFIGURED url is not run through the SSRF guard' => sub {
    my ($call) = $conn =~ /(sub call \{.*?\n\})/s;
    ok( $call, 'call() was found' ) or return;
    unlike( $call, qr/is_safe_url\(\s*\$c->\{url\}/,
        'the connector URL is the operator\'s choice, made in the reserved '
            . 'tree, and http:// to loopback is allowed BY DESIGN - the field '
            . 'echo test depends on it' );
    like( $conn, qr/carve-out/,
        'and the reason is written down where the check would have gone' );
};

subtest 'the webhook path gets the same two bounds' => sub {
    my ($ua) = $form =~ /(my \$ua = LWP::UserAgent->new\(.*?\);)/s;
    ok( $ua, 'the webhook agent was found' ) or return;
    like( $ua, qr/max_redirect\s*=>\s*0/,
        'the other egress a public form can drive does not follow a redirect '
            . 'either - it would send the visitor\'s own fields to a host the '
            . 'operator never configured' );
    like( $ua, qr/max_size\s*=>/, 'and its body is capped' );
};

done_testing;
