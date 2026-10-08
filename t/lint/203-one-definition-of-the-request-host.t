#!/usr/bin/perl
# SM926, RULED 2026-10-01: THE PRESENTED HOST IS THE HOST, and there is ONE
# definition of it.
#
# There were two. lazysite-processor.pl's `_request_host` read HTTP_HOST to choose
# which alias host's config a request got; interpolation read whatever
# $ENV{SERVER_NAME} held - which under Apache's `UseCanonicalName` default of Off
# is the Host header and under On is the configured ServerName. So a page and a
# notification could disagree about what host the site was on, conditional on a
# vhost setting none of the four shipped examples sets.
#
# ADR 0001 keeps the render path module-free, so the processor cannot call
# Lazysite::Util's and carries its own copy. That is the established trade
# (t/lint/198 does this for `_cannot_read`, 202 for the allowlist) and the cost is
# drift. This gate is the brake.
#
# WHAT MUST STAY TRUE OF BOTH, each clause being a decision:
#   1. the host comes from HTTP_HOST - the hostname PRESENTED, per the ruling
#   2. the port and a trailing dot are stripped, so one host has one spelling
#   3. a name longer than 253 bytes is refused
#   4. only a DNS-shaped name is accepted, because this value reaches FILENAMES
#      (the per-host page cache) and URLs - validation is hygiene, not trust
#   5. SERVER_NAME interpolation resolves through it, falling back to
#      $ENV{SERVER_NAME} only when no usable Host header was presented
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Lift a named sub's body out of a file by brace depth - the shape t/lint/198 uses.
sub body_of {
    my ( $file, $name ) = @_;
    open my $fh, '<', "$root/$file" or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    my ( $in, $depth, @body ) = ( 0, 0 );
    for my $l (@lines) {
        if ( !$in && $l =~ /^\s*sub \Q$name\E\b/ ) { $in = 1 }
        next unless $in;
        push @body, $l;
        $depth++ while $l =~ /\{/g;
        $depth-- while $l =~ /\}/g;
        last if $depth <= 0 && @body > 1;
    }
    return join '', @body;
}

# SM944 S13: the processor's copy is in its request part.
my %HOST = (
    'lazysite-processor/request.pm' => body_of( 'lazysite-processor/request.pm', '_request_host' ),
    'lib/Lazysite/Util.pm'          => body_of( 'lib/Lazysite/Util.pm',          'request_host' ),
);
# SM944 S14: and its _env_value is in its sources part.
my %ENVV = (
    'lazysite-processor/sources.pm' => body_of( 'lazysite-processor/sources.pm', '_env_value' ),
    'lib/Lazysite/Util.pm'          => body_of( 'lib/Lazysite/Util.pm',          '_env_value' ),
);

for my $file ( sort keys %HOST ) {
    my $b = $HOST{$file};
    ok( length $b, "$file: the request-host sub was found" ) or next;

    like( $b, qr/\$ENV\{HTTP_HOST\}/,
        "$file: clause 1 - the host comes from HTTP_HOST, the name presented" );
    like( $b, qr/s\/:\\d\+\\z\/\//,
        "$file: clause 2a - the port is stripped" );
    like( $b, qr/s\/\\\.\\z\/\//,
        "$file: clause 2b - a trailing dot is stripped" );
    like( $b, qr/length \$host > 253/,
        "$file: clause 3 - an over-long name is refused" );
    like( $b, qr/a-z0-9/,
        "$file: clause 4 - only a DNS-shaped name is accepted" );
    like( $b, qr/\blc\b/,
        "$file: and it is lowercased, so one host has one spelling" );
}

for my $file ( sort keys %ENVV ) {
    my $b = $ENVV{$file};
    ok( length $b, "$file: _env_value was found" ) or next;

    like( $b, qr/SERVER_NAME/, "$file: clause 5 - SERVER_NAME is the special case" );
    like( $b, qr/request_host\(\)/,
        "$file: clause 5 - and it resolves through the request host" );
    like( $b, qr/\|\|\s*\$ENV\{SERVER_NAME\}/,
        "$file: clause 5 - falling back to \$ENV{SERVER_NAME} when none was presented" );
}

# The two bodies must not merely both exist - they must say the same thing. Compared
# with the leading `_` and whitespace normalised away, because the processor's copy
# is named `_request_host` and the module's is exported as `request_host`.
sub norm {
    my ($b) = @_;
    $b =~ s/^\s*#.*$//mg;     # comments are allowed to differ
    $b =~ s/\bsub\s+_?request_host\b/sub request_host/;
    $b =~ s/\b_request_host\(/request_host(/g;
    $b =~ s/\s+/ /g;
    $b =~ s/\A\s+|\s+\z//g;
    return $b;
}
is( norm( $HOST{'lazysite-processor/request.pm'} ), norm( $HOST{'lib/Lazysite/Util.pm'} ),
    'the two request-host bodies are the SAME decision, line for line' )
    or diag( "  processor: " . norm( $HOST{'lazysite-processor/request.pm'} ) . "\n"
        . "  util:      " . norm( $HOST{'lib/Lazysite/Util.pm'} ) . "\n"
        . "  Two copies of one judgement. A site's alias selection and its own\n"
        . "  links would disagree about what host it is on, which is the whole of\n"
        . "  what SM926 ruled against.\n" );
is( norm( $ENVV{'lazysite-processor/sources.pm'} ), norm( $ENVV{'lib/Lazysite/Util.pm'} ),
    'and so are the two _env_value bodies' );

done_testing();
