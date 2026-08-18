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

our @EXPORT_OK = qw(security_headers content_security_policy inline_script_hashes);
use Exporter 'import';
use Digest::SHA  qw(sha256);
use MIME::Base64 qw(encode_base64);

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

# THE POLICY, AND WHY EACH LOOSE DIRECTIVE IS LOOSE.
#
# The engine emits no inline script or style of its own any more (SM352 steps
# 1-4), but it is not the only thing on the page. MEASURED against the shipped
# catalogue: 22 of 23 layouts inline a <script>, and 8 distinct script bodies
# account for all of them - one appearing 42 times. So `script-src 'self'` alone
# would take down every site running a shipped layout, which is all of them.
#
# The answer is to HASH what is actually in the response rather than to loosen
# the directive. That covers the catalogue, the manager's head script and
# anything a future layout adds, without the engine knowing what any of them
# are, and without 'unsafe-inline' - which would permit injected script as
# readily as authored script and is the one thing a CSP is for.
#
# STRICT WHERE INJECTION HAPPENS, PERMISSIVE WHERE AUTHOR CONTENT LIVES. That
# split is deliberate and is the whole design:
#
#   script-src   hashed. The actual XSS vector.
#   object-src   'none'. Nothing legitimate uses <object> here.
#   base-uri     'self'. A rewritten <base> silently redirects every relative
#                URL on the page, including form posts.
#   form-action  'self'. Stops an injection posting credentials elsewhere.
#   frame-ancestors  'self'. The CSP form of the X-Frame-Options beside it.
#
#   style-src    'unsafe-inline' - for now. Two catalogue layouts inline a
#                <style>, and a hash cannot cover a style="" ATTRIBUTE, which
#                author content produces. Hashing the blocks while attributes
#                still break is a policy that fails for the author rather than
#                the attacker. Recorded as the next target rather than dressed
#                up; a stylesheet cannot exfiltrate a session the way script can.
#   img/media    https: allowed. An author referencing an image on another host
#   frame-src    is doing something ordinary, and 17 production sites were not
#                going to be told their photographs are a security incident.
#                Plain http: is still refused, so mixed content stays blocked.
#
# font-src excludes remote entirely: this project bundles its fonts and has a
# standing rule against CDNs, so a remote font request is a defect by
# definition rather than an author choice.
our @CSP_SITE = (
    q{default-src 'self'},
    q{base-uri 'self'},
    q{object-src 'none'},
    q{form-action 'self'},
    q{frame-ancestors 'self'},
    q{style-src 'self' 'unsafe-inline'},
    q{img-src 'self' data: https:},
    q{media-src 'self' https:},
    q{frame-src 'self' https:},
    q{font-src 'self' data:},
    q{connect-src 'self'},
);

# Every inline <script> body in a response, as CSP source expressions.
#
# A <script src=...> is NOT hashed - it is covered by 'self' - and matching one
# would produce a hash of an empty body that permits every empty script on the
# page, which is the sort of thing that looks like it is working.
#
# The bytes hashed must be EXACTLY what the browser parses between the tags:
# no trimming, no normalising. A hash computed over a tidied copy matches
# nothing, and fails in the least helpful way available - silently, in the
# browser, on a page that renders blank.
sub inline_script_hashes {
    my ($html) = @_;
    return () unless defined $html && length $html;

    my @hashes;
    my %seen;
    while ( $html =~ m{<script\b([^>]*)>(.*?)</script\s*>}gis ) {
        my ( $attrs, $body ) = ( $1, $2 );
        next if $attrs =~ /\bsrc\s*=/i;
        my $b64 = encode_base64( sha256($body), '' );
        next if $seen{$b64}++;
        push @hashes, "'sha256-$b64'";
    }
    return @hashes;
}

# The policy for one response. Hashes are appended to script-src; with none,
# script-src is 'self' alone.
sub content_security_policy {
    my (%opt)  = @_;
    my @hashes = @{ $opt{script_hashes} || [] };
    my $script = join ' ', q{script-src 'self'}, @hashes;
    return join '; ', @CSP_SITE, $script;
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

    # ENFORCING, not report-only. A report-only header with nowhere to report is
    # inert, and building somewhere to report to would have meant standing up an
    # unauthenticated cross-origin write endpoint to discover something
    # t/lint/56 already answers completely rather than representatively.
    #
    # Only on HTML. A stylesheet or an image has no script to govern, and a CSP
    # on a static asset is a header nothing reads.
    if ( $opt{html} ) {
        push @h,
            'Content-Security-Policy: '
            . content_security_policy( script_hashes => $opt{script_hashes} );
    }
    return @h;
}

1;
