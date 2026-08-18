package Lazysite::SecurityHeaders;

# SM352: the response header set, in one place, as data.
#
# WHAT WAS WRONG. Three headers were emitted - nosniff, X-Frame-Options and
# Referrer-Policy - and the field probe reported all three set correctly. They
# were set correctly on ONE response path. Of the four places the engine writes
# response headers, only output_page() carried the full set:
#
#   lazysite-front.pl        the front door's 404 for a denied path   nosniff only
#   lazysite-processor.pl    the same 404 under the front door        nosniff only
#   lazysite-processor.pl    _serve_content_static - every CSS,       nosniff only
#                            JS, SVG and image the processor serves
#   lazysite-processor.pl    output_page - HTML content               all three
#
# So a site's stylesheets and artwork answered without X-Frame-Options or
# Referrer-Policy, and nobody measuring the homepage would have seen it. That is
# the ordinary consequence of a header set maintained by repetition: the paths
# drift, and the drift is invisible from outside unless somebody probes the
# right URL.
#
# WHY THE MISSING ONES WERE MISSING. output_page carried this comment:
#
#   "CSP and HSTS are deliberately NOT emitted here - CSP is site-specific ...
#    and HSTS depends on whether TLS is in use; both belong in the Apache vhost
#    config."
#
# That was a considered decision and it is worth saying plainly that it has been
# overturned rather than forgotten. SM286 settled the question the other way:
# lazysite asks nothing of the front end, and "belongs in the vhost config" is
# the exact reasoning that produced SM248, SM268 H17 and SM283 - correct engine,
# front end never told. A header the engine can emit is a header the engine
# emits.
#
# WHAT THIS REACHES, stated because the first version of the claim did not
# (SM369). Every response THE ENGINE ANSWERS. On a stock proxy template the
# front end answers every static itself and never consults lazysite, so on most
# of the fleet these headers are on pages and nothing else - measured on edge
# after 0.10.13, where statics carry no security headers at all. That is the
# absence being TOTAL, which is what a front end answering everything looks
# like, rather than the short-by-two state this fixed. Routing statics through
# the engine is the SM283 template or the one-rule front door, and is the
# operator's choice rather than something the engine can ask for (SM286).
#
# PURE, LIKE Lazysite::FrontDoor. This returns a list of header lines and prints
# nothing, so the set can be asserted directly rather than by driving a server
# and reading what came back. Callers join with their own line terminator, since
# the CGI paths here are not consistent about \r\n versus \n and this module has
# no opinion about that.

use strict;
use warnings;

our @EXPORT_OK = qw(security_headers);
use Exporter 'import';

# HSTS max-age, in seconds. Deliberately SHORT (5 minutes).
#
# The value is the whole risk here: a browser that has seen this header refuses
# plain HTTP to the host for max-age seconds, and there is no way to reach a
# visitor who has already been told. Starting at five minutes means a mistake
# expires before it can be reported, and raising it later is one edit. The usual
# advice - ramp to a year once you are sure - is right, and is an operator
# decision made against a running fleet rather than a default shipped blind.
#
# includeSubDomains and preload are BOTH absent on purpose. includeSubDomains
# binds hosts this instance may not serve; preload is effectively irreversible
# and belongs to whoever owns the domain, not to the engine rendering its pages.
our $HSTS_MAX_AGE = 300;

# Capabilities denied to every page. The set is the ones the platform never
# uses, so a restrictive default costs nothing that anything is asking for:
# lazysite installs no trackers and the shipped themes touch no sensor.
#
# browsing-topics is in the list for a reason beyond tidiness. It is the Topics
# API - the browser offering the page an interest profile of its visitor - and
# "no trackers" is a codified feature of this product, not a preference. A site
# that cannot ask is a stronger statement than a site that does not.
#
# Deliberately ABSENT: autoplay, fullscreen and picture-in-picture. Those are
# things a page's own content might legitimately want, and denying them would be
# the engine overruling an author about their own video.
our @DENIED_FEATURES = qw(
    accelerometer browsing-topics camera display-capture geolocation
    gyroscope magnetometer microphone midi payment usb xr-spatial-tracking
);

sub _permissions_policy {
    return join ', ', map { "$_=()" } @DENIED_FEATURES;
}

# The header lines for one response.
#
#   https => truthy when the request arrived over TLS
#
# The caller passes it rather than this module reading %ENV, so a test can ask
# both questions without staging an environment.
#
# HSTS IS OMITTED OVER PLAIN HTTP. A browser ignores the header on an insecure
# transport anyway, so sending it always would be harmless and dishonest - the
# response would assert a policy the connection cannot carry. More usefully,
# omitting it means an instance genuinely served over HTTP is never handed a
# directive that would lock it out of its own site if TLS later went away.
#
# $ENV{HTTPS} is the test the engine ALREADY uses to decide whether a session
# cookie gets the Secure flag. Reusing it keeps one answer to "is this
# connection secure" rather than introducing a second that can disagree - and it
# asks nothing new of the front end, because a proxy that does not set it simply
# gets no HSTS, which is the safe direction to fail.
sub security_headers {
    my (%opt) = @_;
    my @h = (
        'X-Content-Type-Options: nosniff',
        'X-Frame-Options: SAMEORIGIN',
        'Referrer-Policy: strict-origin-when-cross-origin',
        'Permissions-Policy: ' . _permissions_policy(),
    );
    push @h, "Strict-Transport-Security: max-age=$HSTS_MAX_AGE" if $opt{https};
    return @h;
}

1;
