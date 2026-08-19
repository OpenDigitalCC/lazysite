#!/usr/bin/perl

# SM293 step 5: the front door. One entry point, so a front end needs one rule.
#
# WHAT THIS IS FOR. Every shipped vhost template carries about a dozen routing
# decisions - which URLs reach the processor, which reach the manager API, which
# go through the auth wrapper, when an existing static file must be handed to
# the engine instead of served, what is denied outright. Those are lazysite's
# decisions, written in a language lazysite does not control, in a file it ships
# as a template, cannot test where it is installed, and mostly cannot see.
#
# That arrangement produced SM248, SM268 H17 and SM283. None was a coding error:
# each was a correct engine and a front end that had not been told, or had been
# told and answered first. Point a front end at this script and the decisions
# come back inside, where Lazysite::FrontDoor::route() makes them and
# t/unit/lib/21 asserts them.
#
# THE TRADE, stated plainly. With one rule, a request for an image on a site
# that protects nothing costs a process start that the web server would not have
# charged. The shipped templates therefore remain - as PERFORMANCE options whose
# absence costs speed and never correctness, which is the acceptance criterion
# SM286 set for this direction. An operator who wants the speed keeps the
# template; an operator who wants one line they can reason about uses this.
#
# CGI, not the FastCGI pool, and that is deliberate for now. Dispatch here ends
# in exec(), which is exactly right for a one-shot CGI and fatal inside a
# persistent worker's accept loop - it would replace the worker. Folding the
# front door into the pool means in-process dispatch to each surface, which is a
# larger change to the auth wrapper's design than this step should carry.
# Recorded in SM293 rather than left implicit.

use strict;
use warnings;
use Cwd            ();
use File::Basename ();

BEGIN {
    # Locate the module tree relative to this script - run-in-place, tarball
    # and package installs alike - the same bootstrap the other surfaces use.
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::FrontDoor       qw(route);
use Lazysite::SecurityHeaders ();

my $docroot = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

# The originally-requested path. REDIRECT_URL is what Apache sets when it has
# rewritten to us; REQUEST_URI is the raw request. Same order the processor
# uses, so the front door and the engine agree on what was asked for.
my $uri = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '/';

my $decision = route(
    { docroot => $docroot,
        uri    => $uri,
        method => ( $ENV{REQUEST_METHOD} // 'GET' ),
        cookie => ( $ENV{HTTP_COOKIE}    // '' ),
    }
);

# The engine's own tree, and authoring sidecars. 404 rather than 403: a 403
# confirms the path exists, and these are paths whose existence is not the
# visitor's business.
if ( $decision->{surface} eq 'denied' ) {
    print "Status: 404 Not Found\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n";
    # SM352: the front door loads modules, so it uses the authority directly.
    # The processor carries a pinned copy instead - ADR 0001.
    print "$_\r\n"
        for Lazysite::SecurityHeaders::security_headers( https => $ENV{HTTPS} );
    print "\r\n";
    print "<p>Not found</p>\n";
    exit 0;
}

my $cgibin = $ENV{LAZYSITE_CGIBIN};
unless ( defined $cgibin && length $cgibin ) {
    # The conventional layout: cgi-bin beside the docroot, which is what every
    # shipped installer produces. LAZYSITE_CGIBIN overrides it for anything else.
    $cgibin = File::Basename::dirname($docroot) . '/cgi-bin';
}

# 'static' and 'processor' both end at the processor: it already serves content
# statics (_serve_content_static), so the front door does not reimplement that
# path.
#
# SM388: THIS COMMENT USED TO NAME THREE THINGS "the engine already gets right"
# - byte ranges, conditional GETs and content types - and two of the three were
# not implemented anywhere. A justification resting on a capability that does
# not exist is worse than no justification, because it stops the next reader
# looking.
#
# What is true now:
#
#   content types     yes, %STATIC_CT
#   conditional GET   yes, weak ETag + If-None-Match (SM388)
#   byte ranges       NO. Media seeking fails wherever the engine answers a
#                     static, and a Range request gets the whole file with a
#                     200. Not fixed here; recorded so the gap is visible from
#                     the place that used to deny it.
#
# The reason for not reimplementing them at the front door is unchanged and
# still good: one implementation is easier to keep correct than two.
my $target =
    ( $decision->{surface} eq 'cgi' )
    ? "$cgibin/$decision->{target}"
    : "$cgibin/lazysite-processor.pl";

unless ( -f $target ) {
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
    print "lazysite: surface not found: $target\n";
    exit 1;
}

# The auth wrapper's contract is unchanged: it validates the session cookie,
# sets the trust headers and LAZYSITE_AUTH_TRUSTED, then execs whatever
# LAZYSITE_PROCESSOR names. Deciding WHICH requests get wrapped is what moves
# here; how wrapping works does not, so the trust design (t/lint/38) is
# untouched.
if ( $decision->{wrapped} ) {
    $ENV{LAZYSITE_PROCESSOR} = $target;
    my $wrapper = "$cgibin/lazysite-auth.pl";
    unless ( -f $wrapper ) {
        print "Status: 500 Internal Server Error\r\n";
        print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
        print "lazysite: auth wrapper not found: $wrapper\n";
        exit 1;
    }
    exec {$^X} $^X, $wrapper or die "cannot exec $wrapper: $!\n";
}

exec {$^X} $^X, $target or die "cannot exec $target: $!\n";
