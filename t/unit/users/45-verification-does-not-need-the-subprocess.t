#!/usr/bin/perl
# SM685: a credential check is a READ, and it stopped paying for an interpreter.
#
# Every authenticated request used to spawn perl and compile the whole of
# tools/lazysite-users.pl to answer one question. On the bench host that compile
# was ~47ms of a ~62ms verification - three quarters of it - so the cost was the
# SIZE OF THE SCRIPT, not the work, and it grew every time anybody added a line
# anywhere in the tool. Verification now lives in Lazysite::Auth::Verify and the
# three callers use it directly.
#
# WHAT THIS TEST DOES NOT PROVE, said plainly because the first draft of it
# claimed otherwise: it cannot show that the port was faithful to the code it
# replaced. The tool DELEGATES to the module now, so both paths here share one
# implementation - breaking that implementation breaks both sides equally and
# they go on agreeing. Drafted as an equivalence proof, it passed with a
# deliberately corrupted value, which is how the flaw was found.
#
# The port was proven separately, against the pre-refactor implementation
# recovered from git: all 49 settings keys identical. That check is a one-off by
# nature - the old code drifts out of reach - so it lives in the filing rather
# than here.
#
# WHAT IT DOES GUARD, which is worth keeping: that verification works at all
# through the module (a refusal is cheap and fast, and a fast wrong answer is
# exactly what a broken store would look like on the bench); that the first-use
# mark is consumed once; that the refusals behave; and that the CLI surface
# still answers identically - so if someone later re-implements verification in
# the tool instead of delegating, the two diverge and this fails.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";
plan skip_all => "no $script" unless -f $script;

require Lazysite::Auth::Verify;
require Lazysite::Auth::Settings;

sub docroot {
    my $d = site_tempdir();    # lint 118: not a bare tempdir
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "manager_groups: sysops\n";
    close $cf;
    return $d;
}

sub api {
    my ( $d, $req ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print $i encode_json($req);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return ( eval { decode_json($out) } ) || {};
}

sub cli {
    my ( $d, @a ) = @_;
    return system( $^X, $script, '--docroot', $d, @a ) == 0;
}

my $d = docroot();
ok( cli( $d, 'add',       'boss',  'bosspw' ),   'a site with a human account' );
ok( cli( $d, 'group-add', 'boss',  'sysops' ),   'who is a sysop' );
ok( cli( $d, 'add',       'agent', 'agentpw' ),  'and a second account' );
ok( cli( $d, 'group-add', 'agent', 'agent-ai' ), 'holding real capabilities' );

my $t     = api( $d, { action => 'token', username => 'agent' } );
my $token = $t->{token};
ok( $token && $token =~ /^lzs_/, 'which holds a machine credential' )
    or BAIL_OUT('no token minted; the rest of this test would be vacuous');

no warnings 'once';    # the module declares it; this only sets it
local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";

# --- the two paths, against the one store -----------------------------------
# The MODULE goes first and the CLI second, so that if the module were somehow
# reading nothing the CLI's answer could not paper over it.
my $mod = Lazysite::Auth::Verify::verify_credential( $d, 'agent', $token );
my $cli = api( $d, { action => 'verify-credential', username => 'agent', secret => $token } );

ok( $mod->{ok}, 'the module verifies a good credential' );
ok( $cli->{ok}, 'and so does the subprocess' );
is( $mod->{username}, 'agent', 'the module names the account it verified' );

# first_use is EXPECTED to differ: the first call consumes the mark. That is not
# a discrepancy, it is the feature, and asserting it here stops a later reader
# treating the difference as a bug and "fixing" the two into agreement.
is( $mod->{first_use}, 1, 'the first verification is the credential first use' );
is( $cli->{first_use}, 0, 'and the second is not - the mark was consumed' );

# --- the settings map, key by key -------------------------------------------
my ( $ms, $cs ) = ( $mod->{settings} || {}, $cli->{settings} || {} );
is_deeply( [ sort keys %$ms ], [ sort keys %$cs ],
    'both paths report the SAME SET of settings keys' );

# A capability that resolves and then reports as absent is SEC-2026-07 (F3) and
# SM666. Compare the values too, not only the names.
# Compared through canonical JSON rather than string equality: three of these
# values are ARRAY REFS (groups, dav_scopes, scope_ceiling) and stringifying a
# ref compares its ADDRESS, so a naive eq reports every run as a difference and
# a deep one as agreement. Encoding also normalises the two boolean flavours -
# the module's JSON::PP::true and the subprocess's decoded JSON::PP::Boolean.
my $j      = JSON::PP->new->canonical;
my @differ = grep {
    $j->encode( { v => $ms->{$_} } ) ne $j->encode( { v => $cs->{$_} } )
} sort keys %$cs;
is_deeply( \@differ, [], 'and the same VALUE for every one of them' )
    or diag("differ: @differ");

# --- and the refusals agree too ---------------------------------------------
for my $case ( [ 'agent', 'lzs_wrong', 'a wrong secret' ],
    [ 'nosuch', $token, 'an account that does not exist' ],
    [ 'agent',  '',     'an empty secret' ] )
{
    my ( $u, $s, $why ) = @$case;
    my $m = Lazysite::Auth::Verify::verify_credential( $d, $u, $s );
    my $c = api( $d, { action => 'verify-credential', username => $u, secret => $s } );
    ok( !$m->{ok}, "the module refuses $why" );
    is( !!$m->{ok}, !!$c->{ok}, "and both paths refuse $why alike" );
}

# --- and it does not start one either -----------------------------------------
# THE RULE THAT KEEPS THIS SAFE: the credential module verifies, it never
# spawns. An earlier draft honoured LAZYSITE_USERS_TOOL inside the module, so a
# deployment could nominate a users tool and have it asked. Sound for the CGIs -
# and a fork bomb, because this module is ALSO loaded inside that tool: the
# child inherits the variable that named it, reads it, and spawns the tool
# again. Each hop is a fresh interpreter, so it does not blow a stack, it eats
# the host. It did, under the full suite, from t/unit/manager/112 and 114 and
# t/integration/18, which point the variable at the real tool.
#
# The delegation now lives in the three callers, which is the only place that
# can decide it without being able to ask itself. This asserts the module stays
# out of it - by SHAPE, so any new way of starting a process is caught too.
subtest 'the credential module starts no processes' => sub {
    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Auth/Verify.pm" or die $!;
        local $/;
        <$fh>;
    };
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    unlike( $code, qr/\bopen2\b|\bsystem\s*\(|\bexec\s*\(|\bqx\b|`|\bfork\b/,
        'no process is started anywhere in the module' );
    unlike( $code, qr/LAZYSITE_USERS_TOOL/,
        'and it does not read the variable that names the tool it lives inside' );
};

done_testing();
