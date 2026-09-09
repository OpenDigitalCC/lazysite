#!/usr/bin/perl
# SM798: the empty-password enumeration oracle, closed by ruling 2026-09-09.
#
# From a non-loopback address an absent user and a wrong password both answered
# `302 ?error=1`, while an account that EXISTS with an empty password answered
# `403` through reject_no_password(). So the one response that differed named an
# account that exists *and* is in the state the engine most discourages - which
# is an oracle for exactly the configuration you would least like enumerated.
#
# The 403 was not an accident: it told an operator why their passwordless
# account could not sign in remotely, and closing this costs that message. The
# release manager ruled that an unauthenticated caller must not be able to tell
# one refusal from another whatever it costs the diagnosis, and that the
# operator reaches the log for it instead.
#
# THIS TEST IS ABOUT INDISTINGUISHABILITY, so it does not check the passwordless
# response against a hand-written expectation - a wrong expectation would pass
# while the oracle stayed open. It runs all three refusals through one code path
# and requires the passwordless one to be BYTE-IDENTICAL to the other two.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";
plan skip_all => "no $auth" unless -f $auth;

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

# POST /login from a REMOTE address (the oracle only ever existed off-loopback).
sub login {
    my (%o) = @_;
    my $body = "username=$o{username}&password=" . ( $o{password} // '' ) . "&next=/";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $o{docroot},
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => $o{addr} // '203.0.113.9',
        HTTPS          => '',
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    my $e   = do { local $/; <$err> };
    waitpid $pid, 0;
    return $out // '';
}

my $d = site_tempdir();
mkdir "$d/lazysite";
mkdir "$d/lazysite/auth";
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;
users_api( $d, { action => 'add', username => 'admin',  password => 'pw' } );
users_api( $d, { action => 'add', username => 'hasapw', password => 'realpw' } );

# An empty-password account is a users line with no hash. The tool will not mint
# one, and it should not - this is the state the engine discourages, written
# here directly because that is how a site arrives in it.
open my $uf, '>>', "$d/lazysite/auth/users" or die $!;
print {$uf} "nopw:\n";
close $uf;

my $absent = login( docroot => $d, username => 'ghost',  password => 'anything' );
my $wrong  = login( docroot => $d, username => 'hasapw', password => 'notit' );
my $empty  = login( docroot => $d, username => 'nopw',   password => '' );

# --- the two refusals that were always alike ---------------------------------
like( $absent, qr/\?error=1/, 'an absent account is refused with ?error=1' )
    or BAIL_OUT('the baseline refusal changed; the comparison below would be vacuous');
is( $wrong, $absent, 'a wrong password is refused identically to an absent account' );

# --- and the one that was not ------------------------------------------------
is( $empty, $absent,
    'a passwordless account is refused identically to an account that does not exist' );

unlike( $empty, qr/\b403\b/, 'it does not answer 403 where the others answer 302' );
unlike( $empty, qr/nopw|not configured|unavailable/i,
    'and says nothing about the account having no password' );

# --- the explanation is not lost, it moved -----------------------------------
# The operator's diagnosis is what closing the oracle cost, so this asserts it
# is still recorded where an operator can reach it and a caller cannot.
my $audit = do {
    my $f = "$d/lazysite/logs/audit.log";
    open my $fh, '<', $f or diag("no audit log at $f") && return '';
    local $/;
    <$fh>;
};
like( $audit, qr/no-password-remote/,
    'the audit trail still records WHY the passwordless account was refused' );

done_testing();
