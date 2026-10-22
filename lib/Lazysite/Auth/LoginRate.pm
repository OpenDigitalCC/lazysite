package Lazysite::Auth::LoginRate;

# H-3: the sign-in rate limiter - per key (a visitor's address, or an account),
# five attempts in five minutes.
#
# SM1043: MOVED HERE FROM lazysite-auth.pl, UNCHANGED, so that a second door can
# count against the SAME limiter rather than a copy of it. The member's own
# account page (SM1034) asks for the current password and a 2FA code inside a
# signed-in session, through the control API, and the ruling was that those
# checks "count against the sign-in rate limiter": a session stolen from a
# member must not become an unthrottled way to guess the password behind it.
# One counter file, one window, one cap; two callers. lazysite-auth.pl's
# check_login_rate is a one-line delegation now.
#
# Context is passed in (auth_dir, docroot), because the two callers are
# different scripts and neither's globals reach the other.

use strict;
use warnings;
use Fcntl          qw(O_CREAT O_RDWR);
use File::Path     qw(make_path);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(check_login_rate);

our $LOGIN_MAX    = 5;      # attempts per window
our $LOGIN_WINDOW = 300;    # seconds (5 minutes)

# SM798: is the login rate limit extension on? Asked of the one reader of the
# registry, so the sign-in CGI, the manager's listing and lazysite check agree.
sub _rate_limit_switched_on {
    my ($docroot) = @_;
    require Lazysite::Manager::Plugins;
    no warnings 'once';    # SM557: required at runtime
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;
    return Lazysite::Manager::Plugins::plugin_enabled('plugins/login-rate-limit.pl');
}

# H-3: per-key login rate limit. Fails open if DB_File tie fails so a
# broken rate-limit store cannot lock out all logins.
#   check_login_rate( $key, auth_dir => DIR, docroot => DOCROOT ) -> 1 under the cap
sub check_login_rate {
    my ( $ip, %o ) = @_;
    return 1 unless $ip;
    my $AUTH_DIR      = $o{auth_dir};
    my $LOGIN_RATE_DB = "$AUTH_DIR/.login-rate.db";

    # SM798, RULED 2026-09-10 AND 2026-09-11: A SWITCHABLE EXTENSION, ON BY
    # DEFAULT. plugins/login-rate-limit.pl is the unit, and the registry says
    # whether it is on - the installer lists it on every site, so this is off
    # only where an operator switched it off. Off means nothing is counted and no
    # counter is kept, and it says so in the same words as the two cases below:
    # a site switched off on purpose and a site whose limiter broke must never
    # look alike, and neither may look like a site that is counting.
    unless ( _rate_limit_switched_on( $o{docroot} ) ) {
        log_event( 'WARN', 'auth',
            'the login rate limiter is NOT in force: the login rate limit extension '
                . 'is switched off, so attempts are not counted and every login is allowed' );
        return 1;    # switched off, and said so
    }
    make_path($AUTH_DIR) unless -d $AUTH_DIR;

    # SM022: do not capture the tie return value. A lexical holding
    # a reference to the tied object triggers "untie attempted
    # while inner references still exist" on the untie below.
    # SM798: IT STILL FAILS OPEN, AND IT NO LONGER DOES SO IN SILENCE.
    #
    # Both returns below answer "this login is under the cap" for a limiter
    # that could not run at all - which is the four-states collapse (SM784):
    # "I could not check" rendered as "yes". A site whose DB_File is missing or
    # whose counter cannot be opened has NO login rate limiting, and until now
    # nothing anywhere said so; the surface that reports on the site's health
    # reported nothing, because nothing had been told.
    #
    # THE DIRECTION IS DELIBERATELY UNCHANGED. Failing closed here would refuse
    # every login on a host missing an optional module - locking an operator
    # out of their own site to enforce a rate limit is a worse failure than not
    # enforcing it. So the answer stays "allow", and the LOG carries what was
    # actually established, which is the release manager's own formulation of
    # the rule: reveal less if you must, record the real state.
    #
    # Logged per attempt rather than once, because these are CGI processes with
    # nothing to remember between them - and a run of these lines is itself the
    # signal that the limiter has been inert for a while.
    my %db;
    unless ( eval { require DB_File; 1 } ) {
        log_event( 'WARN', 'auth',
            'the login rate limiter is NOT in force: DB_File is not installed, '
                . 'so attempts cannot be counted and every login is allowed '
                . '(Debian: libdb-file-perl)' );
        return 1;    # fail open, loudly
    }
    # SM1240: THE COUNTER IS CREATED 0660, IN THE AUTH DIRECTORY'S GROUP.
    #
    # It was created 0600. Whoever made it was then the only identity that could
    # open it, and four processes count against it - the sign-in CGI, the
    # manager's account page, the Odoo sign-in (a CGI or the runtime) - which do
    # not all run as one unix user. The 0.16.0 rollout found it 0600, owned by the
    # site user in group www-data, on two production sites: the CGI could not open
    # it, so every attempt was allowed, and only `lazysite check` said so. A 0600
    # file handed to the site user by an ownership pass is the same state.
    #
    # So the mode is 0660, under a umask that clears only what 0660 does not carry
    # (the caller's umask is the runtime's 077 or a shell's 022 as often as the
    # CGI's 0002, and any of them narrowed 0660 to something the group cannot
    # open). The group is the auth directory's: a setgid directory gives it
    # already, and otherwise it is set here - best effort, since a process can
    # only hand a file to a group it is in. A counter this process owns that has
    # lost group access is given it back, as the audit log does (Audit.pm).
    my $is_new = !-e $LOGIN_RATE_DB;
    if ( !$is_new ) {
        my @s = stat $LOGIN_RATE_DB;
        chmod 0660, $LOGIN_RATE_DB
            if @s && $s[4] == $> && ( $s[2] & 0060 ) != 0060;
    }
    my $um = umask( 0777 & ~0660 );
    eval {
        tie %db, 'DB_File', $LOGIN_RATE_DB, O_CREAT | O_RDWR, 0o660;
    };
    umask $um;
    if ( $is_new && tied %db ) {
        my $dgid = ( stat $AUTH_DIR )[5];
        my $fgid = ( stat $LOGIN_RATE_DB )[5];
        chown -1, $dgid, $LOGIN_RATE_DB
            if defined $dgid && defined $fgid && $dgid != $fgid;
    }
    if ( $@ || !tied %db ) {
        my $why = $@ || "$!";
        $why =~ s/\s+\z//;
        log_event( 'WARN', 'auth',
            'the login rate limiter is NOT in force: its counter could not be '
                . 'opened, so attempts cannot be counted and every login is allowed',
            file => $LOGIN_RATE_DB, error => $why );
        return 1;    # fail open, loudly
    }

    my $window = int( time() / $LOGIN_WINDOW );
    my $key    = "$ip:$window";
    my $count  = ( $db{$key} // 0 ) + 1;
    $db{$key} = $count;

    # Opportunistic cleanup of stale windows
    for my $k ( keys %db ) {
        delete $db{$k} if $k =~ /:(\d+)\z/ && $1 < $window - 1;
    }
    untie %db;

    return $count <= $LOGIN_MAX;
}

1;
