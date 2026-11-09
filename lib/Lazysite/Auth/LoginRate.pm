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
    require Lazysite::Manager::Extensions;
    no warnings 'once';    # SM557: required at runtime
    local $Lazysite::Manager::Extensions::DOCROOT = $docroot;
    return Lazysite::Manager::Extensions::extension_enabled('extensions/login-rate-limit.pl');
}

# Ruling 206 (item 4 of the 0.16.9 fault survey): A LIMITER THAT CANNOT COUNT
# REFUSES. Set by check_login_rate when it answered 0 because the limiter could
# not run (no DB_File, a counter that will not open), '' otherwise - so a caller
# says "sign-in is unavailable" (cannot-tell) rather than "too many attempts".
our $FAULT = '';

# The cannot-tell refusal for a check refused because the limiter is broken.
sub fault_refusal {
    return {
        ok     => 0,
        kind   => 'cannot-tell',
        store  => 'lazysite/auth/.login-rate.db',
        repair => 'lazysite check --docroot <docroot>',
        error => 'Cannot check this sign-in right now: the sign-in rate limiter cannot count '
            . "($FAULT). This is a fault on the host, not a decision about the credential. "
            . 'Every sign-in is refused until it is repaired from the command line; '
            . '`lazysite check --docroot <docroot>` names the fault.',
    };
}

# H-3: per-key login rate limit.
#   check_login_rate( $key, auth_dir => DIR, docroot => DOCROOT ) -> 1 under the cap
# 0 over the cap - or, with $FAULT set, because the limiter could not run.
sub check_login_rate {
    my ( $ip, %o ) = @_;
    $FAULT = '';
    return 1 unless $ip;
    my $AUTH_DIR      = $o{auth_dir};
    my $LOGIN_RATE_DB = "$AUTH_DIR/.login-rate.db";

    # SM798, RULED 2026-09-10 AND 2026-09-11: A SWITCHABLE EXTENSION, ON BY
    # DEFAULT. extensions/login-rate-limit.pl is the unit, and the registry says
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
    # SM798 made the two cases below loud; ruling 206 (2026-11-09) turns them
    # round. Both answered "this login is under the cap" for a limiter that
    # could not run at all - the four-states collapse (SM784): "I could not
    # check" rendered as "yes". SM798 kept that direction so that a host missing
    # a module would not lock its operator out. Ruling 206 decides the other
    # way: a broken install is a fault, the engine refuses, and the sysadmin
    # repairs it from the command line, where `lazysite check` names it. So both
    # now answer 0 with $FAULT set, and the callers refuse as cannot-tell.
    # Switched off on purpose (above) is an operator's choice and still allows.
    #
    # Logged per attempt, because these are CGI processes with nothing to
    # remember between them.
    my %db;
    unless ( eval { require DB_File; 1 } ) {
        $FAULT = 'DB_File is not installed';
        log_event( 'WARN', 'auth',
            'sign-in refused: the login rate limiter cannot count - DB_File is not '
                . 'installed (Debian: libdb-file-perl); every sign-in is refused until it is '
                . 'repaired (lazysite check --docroot names it)' );
        return 0;
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
        $FAULT = 'its counter lazysite/auth/.login-rate.db cannot be opened';
        log_event( 'WARN', 'auth',
            'sign-in refused: the login rate limiter cannot count - its counter cannot be '
                . 'opened; every sign-in is refused until it is repaired (lazysite check '
                . '--docroot names it)',
            file => $LOGIN_RATE_DB, error => $why );
        return 0;
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
