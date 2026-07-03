package Lazysite::Fetch;

# SM096: the guarded remote-content fetch - one place, shared by the processor's
# render path (.url pages, :::include, url: vars, oembed, remote themes/layouts)
# and the manager's "migrate to local" action. The SSRF guard (is_safe_url)
# lives here so there is exactly ONE copy of the private/loopback/link-local
# rejection logic to audit.
#
# The processor loads this lazily, only on a fetch (never on the hot cache-hit
# render), so its page-serving hot path stays module-free (ADR 0001).

use strict;
use warnings;
use URI;
use Socket         qw(inet_aton inet_ntoa);
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(fetch_url is_safe_url);

sub fetch_url {
    my ($url) = @_;

    # Only allow http/https.
    return unless defined $url && $url =~ m{\Ahttps?://};

    # H-4: SSRF guard - reject private / loopback / link-local / multicast IP
    # ranges before touching the wire.
    unless ( is_safe_url($url) ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'SSRF blocked',
            url => substr( $url, 0, 100 ) );
        return;
    }

    # P-1: load LWP::UserAgent only on first use.
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        timeout => 10,
        agent   => 'lazysite/1.0',
    );

    my $response = $ua->get($url);

    return unless $response->is_success;
    return $response->decoded_content;
}

# H-4: reject URLs that resolve to RFC1918 / loopback / link-local / multicast /
# CGNAT / IPv6-loopback / IPv6-link-local addresses. IPv4-only resolution via
# inet_aton is a deliberate choice - IPv6 private-range detection is more
# involved and we'd rather fail closed than parse partial v6 addresses wrongly.
sub is_safe_url {
    my ($url) = @_;
    my $uri   = URI->new($url);
    my $host  = $uri->host // '';
    return 0 unless length $host;

    # Syntactic IPv6 rejection for literals (e.g. http://[::1]/)
    return 0 if $host =~ /\A\[?::1\]?\z/;
    return 0 if $host =~ /\A\[?fe[89ab][0-9a-f]/i;     # link-local v6
    return 0 if $host =~ /\A\[?f[cd][0-9a-f]{2}:/i;    # unique-local v6

    my $packed = inet_aton($host);
    return 0 unless $packed;
    my $ip = inet_ntoa($packed);

    return 0 if $ip eq '0.0.0.0';
    return 0 if $ip =~ /\A127\./;                          # loopback
    return 0 if $ip =~ /\A10\./;                           # RFC1918
    return 0 if $ip =~ /\A172\.(?:1[6-9]|2\d|3[01])\./;    # RFC1918
    return 0 if $ip =~ /\A192\.168\./;                     # RFC1918
    return 0 if $ip =~ /\A169\.254\./;                     # link-local / metadata
    return 0 if $ip =~ /\A(?:22[4-9]|23\d)\./;             # multicast
    return 0 if $ip =~ /\A100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;    # CGNAT

    return 1;
}

1;
