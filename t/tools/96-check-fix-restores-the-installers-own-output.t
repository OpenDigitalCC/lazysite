#!/usr/bin/perl
# SM933 A5 / R16: --fix MAY CORRECT WHAT THE INSTALLER ITSELF LEFT.
#
# SM274 holds --fix to the group-write bit on a declared directory, because the
# install state recorded only the DECLARED mode and so could not tell drift from
# a sysop's deliberate choice. The cost was R3's question: a fresh install whose
# own output came out wrong could not reach a clean report, because --fix would
# not set the bits the installer had failed to set.
#
# The install state now records the mode the installer actually LEFT on each
# directory it created (`dirs_left`). A directory still at exactly that mode is
# the installer's own output, untouched since, and --fix brings it to the
# declared mode. One whose mode has moved since is somebody's choice and keeps
# SM274's rule.
#
# THE FAULT IS REPRODUCED, NOT ASSERTED. How the installer leaves the wrong mode
# in the field: chmod by an account outside the directory's group silently drops
# setgid. That needs a second group to reproduce for real, so the install below
# runs with chmod overridden to drop setgid on docs/ only - the same outcome by
# the same call, and the recorded mode has to come from what is on disk for the
# test to see it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard);

my $FIXTURE_GROUP = getgrgid( $) + 0 ) // ( $) + 0 );

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
my $CHECK   = "$ROOT/tools/lazysite-check.pl";

plan skip_all => 'install.pl not found'        unless -f $INSTALL;
plan skip_all => 'lazysite-check.pl not found' unless -f $CHECK;

my $MF_GUARD = repo_manifest_guard();

my $base = tempdir( 'lazysite-fixleft-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# chmod that drops setgid on any path ending /docs, as an account outside the
# directory's group would see happen.
my $shim = "$base/shim";
make_path($shim);
{
    open my $fh, '>', "$shim/DropSetgidOnDocs.pm" or die $!;
    print {$fh} <<'PM';
package DropSetgidOnDocs;
BEGIN {
    *CORE::GLOBAL::chmod = sub {
        my ( $m, @p ) = @_;
        $m &= ~02000 if grep { m{/docs\z} } @p;
        return CORE::chmod( $m, @p );
    };
}
1;
PM
    close $fh;
}

# $pre is the perl switches that load the chmod shim, or ''. A scalar, quoted by
# the caller: lint 40 forbids a list interpolated into a shell string.
sub provision {
    my ( $docroot, $pre ) = @_;
    $pre //= '';
    my $cgibin = "$docroot/../cgi-bin";
    make_path( $docroot, $cgibin );
    my $out = `$^X $pre \Q$INSTALL\E --mode provision --docroot \Q$docroot\E --cgibin \Q$cgibin\E --serving-group \Q$FIXTURE_GROUP\E 2>&1`;
    return ( $? >> 8, $out );
}
sub state_of {
    open my $fh, '<', "$_[0]/lazysite/.install-state.json" or die $!;
    my $j = JSON::PP::decode_json( do { local $/; <$fh> } );
    close $fh;
    return $j;
}
sub mode_of { ( stat $_[0] )[2] & 07777 }
sub check   { my ( $d, $flag ) = @_; $flag //= ''; return scalar `$^X \Q$CHECK\E --docroot \Q$d\E $flag 2>&1` }

# ---------------------------------------------------------------------------
my $site = "$base/a/site";
my ( $rc, $out ) = provision( $site, "-I\Q$shim\E -MDropSetgidOnDocs" );
diag($out) if $rc && $rc != 4;    # 4: not serviceable, which is the point here
ok( -d "$site/docs", 'the install made docs/' ) or BAIL_OUT($out);

subtest 'the state records the mode the installer LEFT, not the one it declared' => sub {
    my $st = state_of($site);
    is( $st->{dirs}{"$site/docs"}, '2775', 'the model declares 2775' );
    is( $st->{dirs_left}{"$site/docs"}, '0775', 'and records 0775, which is what is there' )
        or diag( 'A record of the declared mode would say nothing the dirs map does '
            . 'not, and could not tell the installer\'s output from a change.' );
    is( mode_of("$site/docs"), 0775, 'the disk agrees' );
    my @off = grep { sprintf( '%04o', mode_of($_) ) ne $st->{dirs_left}{$_} }
        keys %{ $st->{dirs_left} };
    is_deeply( \@off, [], 'every recorded directory matches its disk mode' );
};

subtest 'check names it as the installer\'s output, and --fix sets the declared mode' => sub {
    my $r = check($site);
    like( $r, qr/docs is 0775, as the installer left it; the model declares 2775/,
        'named as the installer\'s own result' );
    check( $site, '--fix' );
    is( mode_of("$site/docs"), 02775, 'setgid restored - SM274 alone would have left it' );
    unlike( check($site), qr/docs is \d+/, 'and the next check is clean on it' );
};

subtest 'a directory changed after the install stays the sysop\'s' => sub {
    my ($victim) = grep { -d "$site/$_" } qw(manager lazysite/templates);
    plan skip_all => 'no second declared directory' unless $victim;
    chmod 02770, "$site/$victim";
    like( check($site), qr/\Q$victim\E is 2770, the model declares 2775 - reported only/,
        'reported under the old rule' );
    check( $site, '--fix' );
    is( mode_of("$site/$victim"), 02770, 'and --fix left it alone' );
    chmod 02775, "$site/$victim";
};

subtest 'a later run keeps the record for what an earlier run created' => sub {
    chmod 0775, "$site/docs";    # back to what the first run left
    my $out = `$^X \Q$INSTALL\E --mode reinstall --docroot \Q$site\E --cgibin \Q$site/../cgi-bin\E --serving-group \Q$FIXTURE_GROUP\E 2>&1`;
    like( $out, qr/Install summary/, 'the reinstall ran' ) or diag($out);
    is( state_of($site)->{dirs_left}{"$site/docs"}, '0775',
        'docs/ is still recorded as the first run left it' )
        or diag( 'Without the carry-forward the record would last until the first '
            . 'upgrade, and --fix would go back to declining.' );
};

subtest 'a directory that was there before the install is never claimed' => sub {
    my $pre = "$base/b/site";
    make_path("$pre/docs");
    chmod 0755, "$pre/docs";
    provision($pre);
    ok( !exists state_of($pre)->{dirs_left}{"$pre/docs"},
        'not recorded - the installer did not make it' );
    check( $pre, '--fix' );
    is( mode_of("$pre/docs"), 0775,
        'so --fix adds group write (SM274) and does NOT set setgid' );
};

done_testing();
