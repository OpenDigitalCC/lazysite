#!/usr/bin/perl
# plugins/login-rate-limit.pl - the login rate limiter extension (SM798).
#
# Counts sign-in attempts per address and refuses the sixth in five minutes. The
# counting lives in lazysite-auth.pl; this file is the unit: what it is, what it
# needs and what it owns.
#
# RULED 2026-09-10 AND 2026-09-11. A switchable extension, so that DB_File is
# the extension's declared dependency rather than the core's, and a deployment
# that does not want a per-address counter - one operator behind a VPN, a
# constrained device - can switch it off. ON BY DEFAULT: the registry lists what
# is on, so the installer lists this on a fresh site and adds it once to every
# site upgrading from before 0.13.13. Nobody loses rate limiting by upgrading.
#
# A CONTRACT extension: off means off. Switched off, nothing counts and no
# counter is kept - and it is visibly off, in the same words as a limiter that
# cannot run: the sign-in CGI logs "the login rate limiter is NOT in force" on
# each attempt, and `lazysite check` says it too, so a site switched off on
# purpose and a site whose limiter broke both say so, each with its reason.
use strict;
use warnings;
use JSON::PP qw(encode_json);

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'login-rate-limit',
        name        => 'Login rate limit',
        description => 'Counts sign-in attempts per address and refuses the sixth '
            . 'within five minutes, with a pause after every failure. On by default. '
            . 'Switched off, attempts are not counted and no counter is kept, and '
            . 'the log and lazysite check both say the limiter is not in force. '
            . 'Needs the DB_File Perl module (Debian: libdb-file-perl).',
        contract => 1,
        # No `storage`: that is what a site package carries, and a per-address
        # counter in the auth store is neither a directory the extension owns
        # nor anything another site should receive.
        owns => {
            deps         => ['DB_File'],
            capabilities => [],
        },
        actions => [],
    };
}

sub run {
    my (@argv) = @_;
    if ( grep { $_ eq '--describe' } @argv ) {
        print encode_json( describe() );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe' } );
    return 0;
}

1;
