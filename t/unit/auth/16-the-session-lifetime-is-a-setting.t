#!/usr/bin/perl
# SM614 (part one): the session lifetime is a SETTING, read from one place.
#
# It was a constant in Lazysite::Auth::Session and a SECOND constant in
# Lazysite::Manager::Sessions, with a comment on the second asking that the two
# be kept in step - a request, not a mechanism. The operator found it by asking
# whether the cookie lifetime could be extended at all. It can now.
#
# WHAT IS NOT HERE, and why: SLIDING expiry. That needs a last-seen time that
# moves while `ts` stays put - `ts` is the issue time and session_revoked
# compares it against not_before, so overwriting it would silently defeat "sign
# out everywhere". A moving value must therefore live in the cookie, and the
# auth wrapper EXECS the processor, so it cannot add a Set-Cookie to a response
# it no longer owns. Crossing that boundary is SM297's subject. Building a
# private crossing for this one purpose would be inventing the thing SM297
# exists to delete - so the sliding half waits for it, and this half is a
# strict subset of the final state rather than a detour.
#
# THE GROUNDWORK THAT MAKES IT CHEAP LATER is tested here: the reader already
# accepts the five-field cookie the sliding writer will produce. Readers before
# writers means no flag day - every instance running this build will accept the
# new cookie before anything issues one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
require Lazysite::Auth::Session;

sub site {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} ( $conf // '' );
    close $fh;
    return "$d/lazysite";
}
sub lifetime_for {
    my ($conf) = @_;
    local $Lazysite::Auth::Session::LAZYSITE_DIR   = site($conf);
    local %Lazysite::Auth::Session::LIFETIME_CACHE = ();
    return Lazysite::Auth::Session::session_lifetime();
}

# --- 1. the default is what it has always been ------------------------------
# An instance that sets nothing must behave exactly as before, or this change
# would silently sign people out on upgrade.
is( lifetime_for(''), 86400,
    'with nothing configured the lifetime is the 24 hours it always was' );

# --- 2. an operator can set it ----------------------------------------------
is( lifetime_for("session_lifetime: 604800\n"), 604800,
    'a configured lifetime is honoured - the operator question that started this' );
is( lifetime_for("site_title: x\nsession_lifetime: 3600\nmanager: enabled\n"), 3600,
    'found among other keys' );

# --- 3. nonsense is not honoured --------------------------------------------
# A zero is not "never expires", it is a typo - and a session store that
# honoured it would hand out an immortal cookie for a missing digit.
is( lifetime_for("session_lifetime: 0\n"), 86400, 'zero falls back to the default' );
is( lifetime_for("session_lifetime: 10\n"), 86400,
    'and so does an implausibly short one' );
is( lifetime_for("session_lifetime: 99999999999\n"), 86400,
    'and an implausibly long one - the ceiling is a year' );
is( lifetime_for("session_lifetime: abc\n"), 86400, 'and a non-number' );

# --- 4. there is ONE source ---------------------------------------------------
{
    my $mgr = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Sessions.pm" or die $!;
        local $/; <$fh>;
    };
    unlike( $mgr, qr/my \$COOKIE_MAX = 86400/,
        'the duplicate constant is gone from Manager::Sessions' );
    like( $mgr, qr/session_lifetime\(/,
        'and it asks the one source instead' );

    # BEHAVIOURALLY, not by grep. Checking only that it CALLS the function let a
    # sabotage drop the directory argument and pass - and a call with no
    # directory reads whichever site the module's global happens to point at,
    # which on a multi-site tool run is somebody else's answer.
    require Lazysite::Manager::Sessions;
    local %Lazysite::Auth::Session::LIFETIME_CACHE   = ();
    local $Lazysite::Auth::Session::LAZYSITE_DIR     = site("session_lifetime: 999999\n");
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = site("session_lifetime: 3600\n");
    is( Lazysite::Manager::Sessions::_cookie_max(), 3600,
        'Manager::Sessions gets ITS OWN site\'s lifetime, not whichever site '
            . 'the module global was last pointed at' );

    my $wrapper = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-auth.pl" or die $!;
        local $/; <$fh>;
    };
    like( $wrapper, qr/\$COOKIE_MAX = Lazysite::Auth::Session::session_lifetime\(\)/,
        'the cookie Max-Age follows the same number - a browser discarding a '
            . 'cookie the server would still honour is the same defect from '
            . 'the other side' );
}

# --- 5. the cache does not answer for the wrong site ------------------------
# Manager::Sessions localises $LAZYSITE_DIR to ask on another site's behalf. A
# single-scalar cache would have answered for whichever site asked first -
# right in every test, wrong on a multi-site instance.
{
    local %Lazysite::Auth::Session::LIFETIME_CACHE = ();
    my $a  = site("session_lifetime: 3600\n");
    my $b  = site("session_lifetime: 7200\n");
    my $ra = do { local $Lazysite::Auth::Session::LAZYSITE_DIR = $a;
        Lazysite::Auth::Session::session_lifetime() };
    my $rb = do { local $Lazysite::Auth::Session::LAZYSITE_DIR = $b;
        Lazysite::Auth::Session::session_lifetime() };
    is( $ra, 3600, 'the first site gets its own value' );
    is( $rb, 7200, 'and the second gets ITS own, not the first cached answer' );
}

# --- 6. the reader already understands the sliding cookie -------------------
# The groundwork. Nothing issues five fields yet; the day something does, every
# instance running this build already accepts it.
{
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Auth/Session.pm" or die $!;
        local $/; <$fh>;
    };
    like( $src, qr/\@f == 5/,
        'the reader accepts a five-field cookie - readers before writers, so '
            . 'switching on sliding needs no flag day' );
    like( $src, qr/\$seen = \$ts unless defined \$seen/,
        'and a cookie with no last-seen time is its own last-seen time, so a '
            . 'four-field cookie expires exactly when it always did' );
}

done_testing();
