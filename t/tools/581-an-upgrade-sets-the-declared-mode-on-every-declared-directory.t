#!/usr/bin/perl
# SM1423 (ruling 215, widened): AN UPGRADE SETS THE DECLARED MODE ON EVERY DECLARED
# DIRECTORY.
#
# The 0.16.1 container recipe left lazysite/stats/form-events at 2755. `lazysite
# check` FAILs that ("the CGI cannot write here; not group-writable"), and the
# container's upgrade-on-start left it as it was, so the migrated site was refused.
# Ruling 215 had the upgrade set the declared mode on the account and form stores
# only. It sets it on every directory the install declares (install_dirs, the
# `dirs` of the install state - the list the check walks), mode only.
#
# A site provisioned by the real install.pl, put in that state (form-events 2755, a
# declared content directory 2755, a path the model does not declare 0755, the state
# one version back), then upgraded:
#   - form-events and the declared directory come out at their declared 2775;
#   - the undeclared directory is left alone;
#   - no owner or group moved;
#   - the check, run after, has no FAIL for a directory mode.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site slurp spit);
use PayloadStage  qw(make_stage run_install);

my $MF    = repo_manifest_guard();
my $stage = make_stage( $MF->path );

my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = run_install( $stage, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'provision' );
is( $rc, 0, 'provisioned' ) or diag $out;

my $lz = "$docroot/lazysite";
sub mode  { return ( ( stat $_[0] )[2] // 0 ) & 07777 }
sub owner { return join ':', ( stat $_[0] )[ 4, 5 ] }

make_path("$lz/stats/form-events");
my $fe = "$lz/stats/form-events";

# A declared directory under the docroot that is not the stats one.
my $state = slurp("$lz/.install-state.json");
my ($other) = grep { $_ ne $fe && index( $_, "$lz/" ) == 0 && -d $_ && $_ !~ m{/(?:auth|forms|git)\z} }
    $state =~ m{"(\Q$docroot\E/[^"]+)"\s*:\s*"2775"}g;
ok( defined $other, 'the install state declares another 2775 directory' ) or BAIL_OUT('no declared directory to test');
my $undeclared = "$docroot/not-declared-by-the-model";
make_path($undeclared);

chmod 02755, $fe, $other;
chmod 0755, $undeclared;
my %owner = map { $_ => owner($_) } ( $fe, $other, $undeclared );
{
    ( my $s = $state ) =~ s/"version"\s*:\s*"[^"]*"/"version" : "0.16.2"/;
    $s =~ s/"dirs_left"\s*:\s*\{.*?\}\s*,?//s;
    spit( "$lz/.install-state.json", $s );
}
is( sprintf( '%04o', mode($fe) ), '2755', 'form-events is 2755, as the 0.16.1 recipe left it' );

( $rc, $out ) = run_install( $stage, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade', '--force' );
is( $rc, 0, 'the upgrade succeeds' ) or diag $out;
is( sprintf( '%04o', mode($fe) ), '2775', 'form-events comes out at its declared 2775' );
is( sprintf( '%04o', mode($other) ), '2775', 'and so does another declared directory' );
is( sprintf( '%04o', mode($undeclared) ), '0755', 'a directory the model does not declare keeps its mode' );
is_deeply( { map { $_ => owner($_) } keys %owner }, \%owner, 'no owner or group moved' );
like( $out, qr/set the declared mode on \d+ path/, 'the install says it set modes' );

my $g = getgrgid( $) + 0 ) // ( $) + 0 );
{
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $cmd = join ' ', map { quotemeta } $^X, "$stage/tools/lazysite-check.pl", '--docroot', $docroot,
        '--cgibin', $cgibin, '--group', $g;
    my $chk = `$cmd 2>&1`;
    unlike( $chk, qr/\[ FAIL \] lazysite\/stats\/form-events/, 'the check has no FAIL for form-events' );
}

done_testing();
