package main;

# lazysite-processor/oembed.pm - the processor's oEmbed converter, and two
# general text helpers filed beside it.
#
# HOLDS   convert_oembed($text): each `::: oembed` block with its URL becomes the
#         provider's embed HTML, or a plain link when it cannot be fetched;
#         fetch_oembed, find_oembed_endpoint, _oembed_providers (the known
#         endpoints; autodiscovery for the rest). And uri_encode($str) and
#         strip_tt_directives($val), general helpers many areas call.
# OWNS    which oEmbed endpoint a URL is sent to, and what of the reply is kept.
# CALLS   fetch_url, log_event (lazysite-processor.pl); decode_json (JSON::PP,
#         imported into main by the script before its parts load).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S3). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

# --- oEmbed ---

# Known provider endpoints - matched by URL pattern.
# Falls back to autodiscovery for unlisted providers.
#
# A SUB, not a file-scoped `my`. This file runs its main body near the top and
# defines its subs below it, so a `my %OEMBED_PROVIDERS = (...)` written here
# was still EMPTY when a request was served: the known-provider loop in
# find_oembed_endpoint iterated zero times and EVERY oEmbed fell through to
# autodiscovery. It kept working - the large providers do advertise the link
# tag - which is why nothing surfaced it, but the endpoint was then taken from
# the remote page instead of from this list, leaving the "restrict to trusted
# hosts" mitigation named below inert.
#
# THIRD instance of this trap: SM285 shipped it as `my @PROBE_EXT` (a security
# probe that passed by testing nothing) and SM293 as `my %REGISTRY_CT` (every
# registry 404'd). t/lint/39 fails on it now - and found THIS one on its first
# run, in code that had been shipped for months.
sub _oembed_providers {
    return (
        qr{youtube\.com/watch|youtu\.be/} => 'https://www.youtube.com/oembed',
        qr{vimeo\.com/}                   => 'https://vimeo.com/api/oembed.json',
        qr{/videos/watch/|/videos/embed/} => undef,    # PeerTube - autodiscover
        qr{twitter\.com/|x\.com/}         => 'https://publish.twitter.com/oembed',
        qr{soundcloud\.com/}              => 'https://soundcloud.com/oembed',
    );
}

sub convert_oembed {
    my ($text) = @_;

    $text =~ s{
        ^:::[ \t]+oembed[ \t]*\n          # opening ::: oembed
        [ \t]*(https?://[^\n]+?)[ \t]*\n  # URL
        ^:::[ \t]*\n                      # closing :::
    }{
        my $url  = $1;
        my $html = fetch_oembed($url);
        $html
            ? qq(<div class="oembed">\n$html\n</div>\n)
            : qq(<div class="oembed oembed--failed">\n)
              . qq(<p><a href="$url">$url</a></p>\n)
              . qq(</div>\n);
    }gsmxe;

    return $text;
}

sub fetch_oembed {
    my ($url) = @_;

    my $endpoint = find_oembed_endpoint($url);
    unless ($endpoint) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed no endpoint", url => $url );
        return;
    }

    my $oembed_url = $endpoint . '?url=' . uri_encode($url) . '&format=json';
    my $raw        = fetch_url($oembed_url);
    unless ($raw) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed fetch failed", url => $oembed_url );
        return;
    }

    # Parse JSON safely using JSON::PP (S3)
    # Note: JSON::PP gives correct string values but the html field content
    # itself is still trusted as-is. A compromised or malicious provider
    # could return arbitrary HTML. Restrict _oembed_providers() to trusted
    # hosts if this is a concern in your deployment.
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data || !defined $data->{html} ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed parse failed", url => $oembed_url, error => $@ );
        return;
    }

    return $data->{html};
}

sub find_oembed_endpoint {
    my ($url) = @_;

    # Check known providers first
    my %providers = _oembed_providers();
    for my $pattern ( keys %providers ) {
        if ( $url =~ $pattern ) {
            my $ep = $providers{$pattern};
            return $ep if $ep;
            last;    # Pattern matched but no endpoint - fall through to autodiscovery
        }
    }

    # Autodiscovery - fetch the page and look for oEmbed link tag
    my $page = fetch_url($url);
    return unless $page;

    if ( $page =~ m{<link[^>]+type=["']application/json\+oembed["'][^>]+href=["']([^"']+)["']}ix
        || $page =~ m{<link[^>]+href=["']([^"']+)["'][^>]+type=["']application/json\+oembed["']}ix )
    {
        return $1;
    }

    return;
}

sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

sub strip_tt_directives {
    my ($val) = @_;
    # Strip [% and %] as separate sequences rather than matched pairs.
    # This handles nested attempts like [% [% ... %] %] more robustly
    # than a non-recursive paired match.
    $val =~ s/\[%//g;
    $val =~ s/%\]//g;
    return $val;
}

1;
