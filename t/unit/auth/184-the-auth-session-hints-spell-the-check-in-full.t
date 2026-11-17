#!/usr/bin/perl
# SM1460: THE AUTH SESSION'S HINTS SPELL THE CHECK IN FULL.
#
# Four hints in Lazysite::Auth::Session said "(lazysite check --docroot names it)" or
# "lazysite check --docroot <docroot> names it": a bare `lazysite` and a placeholder, the
# fault SM1458 fixed in the check's own advice. Each is now the command as this host runs
# it (Lazysite::Util::cli_spelling) with the site's real docroot (Util::check_command).
#
# The four: a user-settings.json that cannot be read, a revoked.json that cannot be read,
# a session_lifetime that cannot be told, and SESSION_FAULT_REPAIR (the repair field of the
# cannot-tell log line). The same helper spells the hints of Acl, Credential, LoginRate,
# Notify and Settings, held below.
#
# Sabotage (each run by hand, each fails here): restore the old bare text in
# account_disabled, session_revoked, verify_session_cookie or SESSION_FAULT_REPAIR; make
# Util::check_command return the bare `cli check`.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use Digest::SHA  qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session ();
use Lazysite::Util ();

$ENV{LAZYSITE_CLI}       = 'perl /opt/probe/lazysite-cli.pl';
$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

my $D  = site_tempdir();
my $LZ = "$D/lazysite";
make_path("$LZ/auth");

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $CMD = "perl /opt/probe/lazysite-cli.pl check --docroot $D";

sub spelled {
    my ( $text, $what ) = @_;
    unlike( $text, qr/(?<![\w\/.-])lazysite check/, "$what: not a bare `lazysite check`" );
    unlike( $text, qr/<docroot>/, "$what: no <docroot> placeholder" );
    like( $text, qr/\Q`$CMD` names it\E/, "$what: the check is spelled in full, with the real docroot" );
    return;
}

my @log;
no warnings 'once';
local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
local *Lazysite::Auth::Session::log_event = sub { push @log, [@_] };
use warnings 'once';

# 1. user-settings.json that does not decode
spit( "$LZ/auth/user-settings.json", '{not json' );
@log = ();
is( Lazysite::Auth::Session::account_disabled('pat'), 1, 'a broken user-settings.json refuses' );
spelled( join( ' ', map { $_->[2] } grep { $_->[0] eq 'WARN' } @log ), 'user-settings.json' );

# 2. revoked.json that does not decode
spit( "$LZ/auth/revoked.json", '{not json' );
@log = ();
is( Lazysite::Auth::Session::session_revoked( 'pat', time, 'sid1' ), 1, 'a broken revoked.json refuses' );
spelled( join( ' ', map { $_->[2] } grep { $_->[0] eq 'WARN' } @log ), 'revoked.json' );

# 3. session_lifetime that cannot be told
spit( "$LZ/auth/.secret", 'a' x 64 );
spit( "$LZ/lazysite.conf", "site_name: T\nsession_lifetime: soon\n" );
my $payload = 'pat|' . time . '|sid1';
my $sig     = hmac_sha256_hex( $payload, 'a' x 64 );
@log = ();
my ( $ident, $why ) = Lazysite::Auth::Session::verify_session_cookie(
    cookie => Lazysite::Auth::Session::SESSION_COOKIE_NAME() . "=$payload:$sig" );
is( $why, 'cannot-tell', 'an unreadable session_lifetime cannot tell' );
spelled( join( ' ', map { $_->[2] } grep { $_->[0] eq 'WARN' } @log ), 'session_lifetime' );

# 4. the repair field
{
    # a field value (repair=...), unquoted like the processor's own copy of it
    my $r = Lazysite::Auth::Session::SESSION_FAULT_REPAIR();
    unlike( $r, qr/<docroot>/, 'SESSION_FAULT_REPAIR: no <docroot> placeholder' );
    like( $r, qr/\A\Q$CMD\E names it; repair it from the command line\z/, 'SESSION_FAULT_REPAIR: the check in full, with the real docroot' );
}

# the helper: any path inside the tree names the docroot; an unknown place drops --docroot
is( Lazysite::Util::check_command("$LZ/auth"), $CMD, 'check_command: a path inside the engine tree' );
is( Lazysite::Util::check_command($LZ), $CMD, 'check_command: the engine tree itself' );
is( Lazysite::Util::check_command('/nonexistent/x'), 'perl /opt/probe/lazysite-cli.pl check', 'check_command: unknown place, no placeholder' );
is( Lazysite::Util::check_command(), 'perl /opt/probe/lazysite-cli.pl check', 'check_command: no argument' );

# the other modules' log hints
subtest 'the other modules spell it through the same helper' => sub {
    my $root = "$FindBin::Bin/../../..";
    for my $f (qw(Auth/Acl Auth/Credential Auth/LoginRate Auth/Settings Notify Daemon/Supervisor Daemon/Service/Scheduler)) {
        open my $fh, '<', "$root/lib/Lazysite/$f.pm" or die "$f: $!";
        my $src = do { local $/; <$fh> };
        close $fh;
        unlike( $src, qr/\(lazysite check --docroot names it\)|lazysite check --docroot <docroot> names it|\(`lazysite check` names it\)/,
            "$f: no bare check hint left in a log line" );
    }
};

done_testing;
