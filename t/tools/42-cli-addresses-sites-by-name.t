#!/usr/bin/perl
# SM321: address a site by the one token the operator holds - its name.
#
# WHAT THE OPERATOR HIT. After a rollout reported a site as not confirmed, the
# documented repair was:
#
#   sudo perl -I/tmp/lazysite-0.10.10/lib /tmp/lazysite-0.10.10/tools/lazysite-check.pl \
#        --docroot /home/<user>/web/<domain>/public_html \
#        --cgibin  /home/<user>/web/<domain>/cgi-bin --fix
#
# Four things they must supply that the system already knows - the unpack path,
# the library path, the site user, and the docroot layout - to name one thing it
# does not: the domain. Their words: "this fix command is fragile and needs me to
# know users and domains ... automate the fixes, with operator decision at the
# right point, not operator orchestration."
#
# TWO SEPARATE FAULTS MADE IT THAT SHAPE.
#
# 1. `lazysite check` and `lazysite acl` were pure pass-throughs, so they never
#    saw the registry - which has carried docroot and cgibin per site all along,
#    and which `upgrade --all` and `migrate-engine-tree --all` already read.
#
# 2. run_tool exec'd the child WITHOUT -I. The tools `require Lazysite::Paths`
#    with no `use lib` of their own, so they depend on @INC, and neither the
#    payload's lib/ nor an unpacked tarball's is in it. `lazysite check` failed
#    with "Can't locate Lazysite/Paths.pm in @INC" - so the documented command
#    did not work even when typed correctly.
#
# Resolution happens in the CLI, not in each tool: a tool that grew its own
# discovery would be a second copy of the registry reader, which is the shape
# SM318 and SM304 were both filed about.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";
ok( -f $cli, 'the CLI is present' );

# Two registered sites, as the deb layout provides them.
my $reg  = tempdir( CLEANUP => 1 );
my $base = tempdir( CLEANUP => 1 );
my %site;
for my $n (qw(alpha.example beta.example)) {
    my $doc = "$base/$n/public_html";
    my $cgi = "$base/$n/cgi-bin";
    make_path("$doc/lazysite/themes");
    make_path($cgi);
    open my $c, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print $c "site_name: $n\n";
    close $c;
    open my $r, '>', "$reg/$n" or die $!;
    print $r "docroot=$doc\ncgibin=$cgi\n";
    close $r;
    $site{$n} = $doc;
}

sub cli {
    my (@args) = @_;
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    my $cmd = join ' ', map { "'$_'" } ( $^X, $cli, @args );
    return scalar qx($cmd 2>&1);
}

subtest 'a site is addressed by name, and the docroot is derived' => sub {
    my $out = cli( 'check', '--domain', 'alpha.example' );

    like( $out, qr/\Q$site{'alpha.example'}\E/,
        'the tool ran against the docroot the registry holds' )
        or diag("Output was:\n$out");
    unlike( $out, qr/\Q$site{'beta.example'}\E/,
        'and only that one' );
};

subtest 'the library path is passed to the child' => sub {
    # The fault that made the documented command fail even when typed correctly.
    my $out = cli( 'check', '--domain', 'alpha.example' );
    unlike( $out, qr/Can't locate Lazysite/,
        'the child finds the engine modules' )
        or diag( "run_tool must pass -I <payload>/lib. payload_root() has always\n"
            . "known where lib/ is; it simply never told the child." );
    like( $out, qr/lazysite-check/, 'and the tool actually ran' );
};

subtest '--all visits every registered site and aggregates' => sub {
    my $out = cli( 'check', '--all' );
    like( $out, qr/^== alpha\.example$/m, 'the first site is named' );
    like( $out, qr/^== beta\.example$/m,  'and the second' );
    like( $out, qr/\d+ ok, \d+ with findings/,
        'with one aggregate line, not a wall to scroll' );
};

subtest 'an unknown name is refused, and says what exists' => sub {
    # An operator who mistypes a domain should not have to go and read the
    # registry to find out what they meant.
    my $out = cli( 'check', '--domain', 'nope' );
    like( $out, qr/no registered site named 'nope'/, 'it is refused' );
    like( $out, qr/alpha\.example.*beta\.example/s,
        'and the known names are listed' );
};

subtest '--all and --domain together are refused' => sub {
    my $out = cli( 'check', '--all', '--domain', 'alpha.example' );
    like( $out, qr/mutually exclusive/,
        'the ambiguity is refused rather than resolved silently' );
};

subtest 'the per-site tools are unchanged and still take --docroot' => sub {
    # Deliberate: resolution lives in the CLI so the tools stay per-site. A tool
    # that grew its own discovery would be a second registry reader.
    my $out = cli( 'check', '--docroot', $site{'alpha.example'} );
    like( $out, qr/lazysite-check/,
        'a direct --docroot invocation still works' )
        or diag( 'The addressing must be additive - existing scripts and '
            . 'runbooks pass --docroot and must keep working.' );
};

subtest 'the exit status is the WORST outcome, not the last' => sub {
    # A fleet command returning the final site's status reports success whenever
    # the last site happens to be healthy - the class of defect this project
    # keeps filing.
    my $src = do { open my $fh, '<', $cli or die $!; local $/; <$fh> };
    like( $src, qr/\$worst = \$rc if \$rc > \$worst/,
        'the worst status is kept' );
    like( $src, qr/exit \$worst/, 'and returned' );
    like( $src, qr/not the last/, 'with the reasoning recorded' );
};

subtest 'it falls back to the host\'s own site list (SM329)' => sub {
    # THE ADDRESSING SHIPPED IN 0.10.11 DID NOT REACH THE DEPLOYMENT IT WAS BUILT
    # FOR. The registry is written by `provision`, which the deb path runs and
    # the Hestia TARBALL path never does - install.pl says so outright: "lazysite
    # has no central site registry - the host knows the sites". So --domain
    # worked on a deb install and was useless on the shape the complaint came
    # from, where the operator was still typing full docroots.
    #
    # lazysite-hestia-list.sh already discovers every site authoritatively. Two
    # discovery mechanisms existed, and the CLI consulted the empty one.
    my $src = do { open my $fh, '<', $cli or die $!; local $/; <$fh> };

    like( $src, qr/sub _discover_hestia_sites/,
        'the CLI can consult the Hestia site list' );
    like( $src, qr/\$sites = _discover_hestia_sites\(\) unless \@\$sites/,
        'and does so only when the registry is empty - the registry still wins' );
    like( $src, qr/--plain --template-only/,
        'using the template-only listing, which is the authoritative one' );

    # It reads /usr/local/hestia/data/users, so a non-root caller must be told
    # THAT rather than "no registered site named X" - which would send them
    # hunting for a registry entry that was never going to exist.
    like( $src, qr/needs root/,
        'a non-root caller is told the real reason it cannot look' );
    like( $src, qr{/usr/local/hestia/data/users},
        'naming what it needs to read' );
};

done_testing();
