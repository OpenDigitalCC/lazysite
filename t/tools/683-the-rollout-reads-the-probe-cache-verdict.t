#!/usr/bin/perl
# SM1453: the ACL probe's cache verdict is a verdict, and the rollout counts it.
#
# THE 0.17.0 ROLLOUT said "probe: 19 clean, 0 exposed, 13 could not run", and on
# eleven of the thirteen the probe HAD run and answered: nothing reaches past the
# gate, and the files still served are held by the front end's cache (SM331,
# SM368, SM377). `lazysite probe` matched two of the check's three verdicts, so
# the third fell to "not confirmed" and the rollout told the operator to go
# looking for a cause that did not exist.
#
# THE VERDICT'S TEXT IS TAKEN FROM lazysite-check.pl, not retyped here: the
# check's own WARN is read out of its source and built the way it builds it, so
# a change to the check's wording that the CLI does not follow fails this test
# instead of turning every cache verdict back into "could not run".
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $UPD  = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $T    = Cwd::realpath( site_tempdir() );

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

# --- the check's cache verdict, built from the check's source -----------------
my $check_src = slurp("$root/tools/lazysite-check.pl");
my ($expr) = $check_src =~ /if \( \$late_verdict eq 'cache' \) \{\s*report\( 'WARN',\s*(.+?),\s*'no action: the front end clears/s;
ok( $expr, 'the check\'s cache WARN was found in lazysite-check.pl' ) or do { done_testing; exit };
my $verdict = do {
    my ( $l, $g ) = ( '.png, .pdf, .txt served', '.dat refused' );
    my $v = eval $expr;    ## no critic
    die "the check's cache WARN did not evaluate: $@" unless defined $v;
    $v;
};
like( $verdict, qr/a file the engine refuses is still being served to anonymous visitors/,
    'and it is the verdict SM1453 names' );

# --- the CLI against a payload whose check prints exactly that ----------------
my $pay = "$T/payload";
make_path("$pay/tools");
spit( "$pay/install.pl", "# stand-in\n" );
spit( "$pay/VERSION",    "0.0.0\n" );
copy( "$root/tools/lazysite-cli.pl", "$pay/tools/lazysite-cli.pl" ) or die "copy: $!";
spit( "$pay/tools/lazysite-check.pl", "print \"  [ warn ] \" . q{$verdict} . \"\\n\\n1 ok, 1 warning(s), 0 failure(s)\\n\"; exit 0;\n" );
my $CLI = "$pay/tools/lazysite-cli.pl";

my $doc = "$T/res.example/public_html";
make_path("$doc/lazysite/auth");
spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
my $reg = "$T/registry";
make_path($reg);
spit( "$reg/res.example", "docroot=$doc\n" );

sub cli_probe {
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    local $ENV{PERL5LIB}              = "$root/lib";
    my $out = qx($^X \Q$CLI\E probe --domain res.example 2>&1);
    return ( $? >> 8, $out );
}

SKIP: {
    skip 'running as root - the probe declines', 3 if $> == 0;
    my ( $rc, $out ) = cli_probe();

    like( $out, qr/^  res\.example: cache residue, clears itself/m,
        'the probe says what it found: cache residue, a verdict' )
        or diag $out;
    unlike( $out, qr/NOT CONFIRMED|SERVED ANONYMOUSLY/, 'not "could not run", and not an exposure' )
        or diag $out;
    is( $rc, 0, 'exit 0: it measured, nothing is exposed (exposure stays exit 1 only, SM912)' )
        or diag $out;
}

# --- the rollout reads it ----------------------------------------------------
my $u = slurp($UPD);
my %fn;
for my $n (qw(collect_findings probe_site)) {
    ( $fn{$n} ) = $u =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}
my ($noise) = $u =~ /^(NOISE_RE='[^\n]+')$/m;

SKIP: {
    skip 'running as root - the probe declines', 3 if $> == 0;
    spit( "$T/f", '' );
    spit( "$T/p.sh", "set -u\nVERBOSE=0\nLZS='$CLI'\nFINDINGS_FILE='$T/f'\n"
            . "export LAZYSITE_REGISTRY_DIR='$reg' PERL5LIB='$root/lib'\n$noise\n"
            . "$fn{collect_findings}$fn{probe_site}PROBE_TOOL_FAILED=''\nprobe_site res.example\n"
            . "echo \"VERDICT=\$PROBE_VERDICT RESIDUE=\$PROBE_RESIDUE\"\n" );
    my $shown = qx(bash '$T/p.sh' 2>&1);
    like( $shown, qr/VERDICT=ok RESIDUE=1/, 'the rollout counts it clean, and knows it was residue' )
        or diag $shown;
    unlike( slurp("$T/f"), qr/probe could not run/, 'and files no "could not run" finding for it' )
        or diag slurp("$T/f");
}

like( $u, qr/%d clean%s, %d exposed, %d could not run%s/, 'the summary has room to say how many of the clean were residue' );
like( $u, qr/%d cache residue, clears itself/, 'in the CLI\'s own words' );
like( slurp("$root/tools/lazysite-cli.pl"), qr/cache residue, clears itself/,
    'the marker the rollout reads is the one the CLI prints' );

done_testing();
