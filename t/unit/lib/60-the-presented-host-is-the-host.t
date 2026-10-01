#!/usr/bin/perl
# SM926, RULED 2026-10-01: THE PRESENTED HOST IS THE HOST.
#
# `${SERVER_NAME}` in site_url used to expand to whatever $ENV{SERVER_NAME} held,
# which under Apache's `UseCanonicalName` default of Off is the Host header and
# under On is the configured ServerName. So the engine's own idea of what host a
# site is on was conditional on a vhost setting none of the four shipped examples
# sets - while `_request_host()`, a few thousand lines away in the same file, had
# been reading HTTP_HOST to pick an alias host's config all along.
#
# The ruling makes it a division of responsibility rather than a trust level: the
# engine uses the hostname it was given, restricting what may be presented is the
# front end's job, and a site that wants it fixed pins it.
#
# The last two subtests are the ones that would catch a careless "improvement":
# validation is HYGIENE, not trust (this value reaches filenames), and a literal
# site_url is the pin and must stay untouched.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

require Lazysite::Util;

sub with_env {
    my ( $env, $code ) = @_;
    my %clean = %ENV;
    delete @clean{qw(HTTP_HOST SERVER_NAME REQUEST_SCHEME)};
    local %ENV = ( %clean, %$env );
    return $code->();
}

subtest 'the Host header decides, not the vhost setting' => sub {
    # UseCanonicalName Off: Apache sets SERVER_NAME from the Host header, so both
    # agree and nothing is interesting. The case that matters is ON, where they
    # differ - the engine must follow the host the visitor actually asked for.
    my $got = with_env(
        {   HTTP_HOST      => 'alias.example',
            SERVER_NAME    => 'primary.example',    # UseCanonicalName On
            REQUEST_SCHEME => 'https',
        },
        sub { Lazysite::Util::interpolate_env('${REQUEST_SCHEME}://${SERVER_NAME}') }
    );
    is( $got, 'https://alias.example',
        'the presented host wins over the configured ServerName' );
};

subtest 'no Host header falls back to SERVER_NAME' => sub {
    my $got = with_env(
        { SERVER_NAME => 'primary.example', REQUEST_SCHEME => 'https' },
        sub { Lazysite::Util::interpolate_env('${REQUEST_SCHEME}://${SERVER_NAME}') }
    );
    is( $got, 'https://primary.example',
        'a request with no Host - or a CLI run - still resolves' );
};

subtest 'a Host that is not a hostname falls back rather than poisoning' => sub {
    # Validation is hygiene: this value reaches the per-host page cache's FILENAMES
    # and the URLs in notices. Anything not DNS-shaped reads as absent, and the
    # configured name stands.
    for my $bad ( '../../etc/passwd', 'has space', 'a' x 300, 'semi;colon', '' ) {
        my $got = with_env(
            {   HTTP_HOST      => $bad,
                SERVER_NAME    => 'primary.example',
                REQUEST_SCHEME => 'https',
            },
            sub { Lazysite::Util::interpolate_env('${SERVER_NAME}') }
        );
        is( $got, 'primary.example',
            "a Host of '" . ( length $bad ? substr( $bad, 0, 18 ) : '(empty)' )
                . "' is refused, and the configured name stands" );
    }
};

subtest 'the host is normalised, so one host has one spelling' => sub {
    is( with_env( { HTTP_HOST => 'Alias.Example:8443' },
            sub { Lazysite::Util::request_host() } ),
        'alias.example', 'case folded and the port stripped' );
    is( with_env( { HTTP_HOST => 'alias.example.' },
            sub { Lazysite::Util::request_host() } ),
        'alias.example', 'and the FQDN trailing dot removed' );
};

subtest 'a literal site_url is THE PIN and is left alone' => sub {
    # The ruling says a site that wants the host fixed pins it. This is how: a
    # value with no ${...} in it has nothing to expand, so the presented host
    # cannot reach it. No new config key was needed and none was added.
    my $got = with_env(
        { HTTP_HOST => 'attacker.example', SERVER_NAME => 'primary.example' },
        sub { Lazysite::Util::interpolate_env('https://pinned.example') }
    );
    is( $got, 'https://pinned.example',
        'a pinned site_url ignores the presented host entirely' );
};

subtest 'completeness agrees with interpolation, or Notify emits a relative path' => sub {
    # These two must use the same resolver. With a Host header and no SERVER_NAME,
    # interpolation succeeds - so completeness must not call it unresolvable, or
    # SM926's "no request context" branch would fire on a request that had one.
    my $complete = with_env(
        { HTTP_HOST => 'alias.example', REQUEST_SCHEME => 'https' },
        sub {
            Lazysite::Util::env_interpolation_complete(
                '${REQUEST_SCHEME}://${SERVER_NAME}');
        }
    );
    ok( $complete, 'a Host header alone is enough for the expansion to be complete' );

    my $incomplete = with_env( {},
        sub {
            Lazysite::Util::env_interpolation_complete(
                '${REQUEST_SCHEME}://${SERVER_NAME}');
        } );
    ok( !$incomplete, 'and with no request context at all it is still incomplete' );
};

done_testing();
