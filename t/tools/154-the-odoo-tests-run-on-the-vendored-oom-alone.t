#!/usr/bin/perl
# SM1081: the Odoo extension's tests run on the pinned snapshot of OOM inside this
# repository ALONE - and the compatibility tier that looks at the host's OOM is
# advisory and can never fail anything.
#
# Release manager, 2026-10-14: "it isn't intended that oom changes will prevent a
# lazysite build ... we can't be testing against odoo to run a lazysite, it's just an
# extension, not core." The gate failed three times on 2026-10-13 and 14 for changes in
# OOM's working tree and in whichever OOM the host had. So:
#
#   * with LAZYSITE_OOM_LIB unset, every Odoo module a test loads comes from
#     t/vendor/oom - even with a POISONED Odoo::Ops put first on PERL5LIB, which a test
#     that reached for the host's OOM would pick up and die on;
#   * the Odoo tests pass in that state;
#   * tools/ext-compat.sh runs the same tests against other OOMs, reports each target
#     on its own line, and ALWAYS exits 0 - against a deliberately broken OOM it says
#     FAIL (advisory), files one note in the inbox (once a day) and still exits 0;
#   * SM1330: that line and note name the failing files (bounded), and the target runs
#     alone - its own oomd, no host packs, no other OOM's share root.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root   = repo_root();
my $vendor = "$root/t/vendor/oom";
ok( -d "$vendor/lib/Odoo", 'the snapshot is in the repository' ) or BAIL_OUT('t/vendor/oom is missing');

my $t = tempdir( CLEANUP => 1 );
sub spit { my ( $p, $c ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $f, '>', $p or die "$p: $!"; print {$f} $c; close $f }

# An Odoo::Ops that dies if it is ever loaded: what a host's own OOM would look like to a
# test that read it, for the purpose of showing none does.
spit( "$t/poison/Odoo/Ops.pm", "package Odoo::Ops;\ndie 'the HOST\\'s OOM was loaded - a test reached past the snapshot';\n1;\n" );
spit( "$t/poison/Odoo/Transport/Session.pm", "package Odoo::Transport::Session;\ndie 'the HOST\\'s OOM was loaded';\n1;\n" );

subtest 'every Odoo module a test loads is the snapshot\'s' => sub {
    my $prog = q{
        use lib "t/lib", "lib";
        use OdooTest;
        OdooTest::oom_or_skip();
        require Odoo::Ops;
        require Odoo::Ops::Context;
        require Odoo::Transport::Session;
        require Odoo::Test::FakeOdoo;
        require Lazysite::Odoo;
        print "$_\n" for sort map { $INC{$_} } grep { m{^Odoo/} } keys %INC;
        print "VERSION $Odoo::Ops::VERSION\n";
    };
    my $out = qx(cd $root && env -u LAZYSITE_OOM_LIB -u LAZYSITE_OOM_TEST_LIB PERL5LIB=$t/poison $^X -e '$prog' 2>&1);
    is( $?, 0, 'it loads, with the poisoned OOM first on PERL5LIB' ) or diag $out;
    my @paths = grep { m{\.pm\z} } split /\n/, $out;
    cmp_ok( scalar @paths, '>', 5, 'and loaded Odoo modules' );
    my @outside = grep { index( $_, "$vendor/" ) != 0 } @paths;
    is_deeply( \@outside, [], 'every one of them is under t/vendor/oom' ) or diag join "\n", @outside;
    like( $out, qr/^VERSION 0\.\d+/m, 'and it is a released version' );
};

subtest 'the Odoo tests pass on the snapshot alone' => sub {
    my $out = qx(cd $root && env -u LAZYSITE_OOM_LIB -u LAZYSITE_OOM_TEST_LIB PERL5LIB=$t/poison prove -I$root/lib t/unit/odoo/09-a-read-runs-as-the-connection-user-inside-its-scope.t t/unit/odoo/12-a-plan-waits-for-its-maker-and-applies-once.t t/integration/171-the-odoo-tools-over-mcp.t 2>&1);
    is( $?, 0, 'a read, a plan and its confirm, and the MCP tools (a child process) all pass' ) or diag $out;
    unlike( $out, qr/HOST.s OOM was loaded/, 'and none reached the host\'s OOM' );
};

subtest 'tools/ext-compat.sh is advisory: a broken OOM is a FAIL line and a note, never an exit' => sub {
    plan skip_all => 'tools/ext-compat.sh is missing' unless -x "$root/tools/ext-compat.sh";
    my $tree  = "$t/broken-oom";
    my $inbox = "$t/inbox";
    make_path($inbox);
    # SM1330: before it dies, the broken OOM writes down the environment it was loaded in -
    # what a target's own code sees under the tier.
    spit( "$tree/lib/Odoo/Ops.pm", "package Odoo::Ops;\nour \$VERSION = '9.9';\n"
        . "if ( open my \$f, '>>', '$t/seen' ) { print {\$f} join( ' ', map { \"\$_=\" . ( \$ENV{\$_} // '(unset)' ) } qw(LAZYSITE_OOMD ODOO_OOM_PACK_DIRS ODOO_OOM_SHARE) ), \"\\n\" }\n"
        . "die 'broken on purpose';\n1;\n" );
# The deb target is pointed at nothing (OOM_DEB_LIB): what this host has installed is not this test's
# business, and the day OOM 0.11 was installed it filed a second note here and failed the gate.
    my $run = sub { qx(cd $root && OOM_TREE=$tree OOM_DEB_LIB=$t/no-deb LAZYSITE_INBOX=$inbox bash tools/ext-compat.sh --night 2>&1) };
    my $out = $run->();
    is( $? >> 8, 0, 'it exits 0 although a target failed' );
    like( $out, qr/^ext-compat: OOM tree \(9\.9\): FAIL \(advisory\)/m, 'the broken OOM is a FAIL line, marked advisory' );
    like( $out, qr/^ext-compat: installed deb: skipped/m, 'the deb target, pointed at nothing, is skipped - not read from this host' );
    my @notes = glob("$inbox/*oom-changes-break-lazysites-odoo-tests*.md");
    is( scalar @notes, 1, 'and files one note in the inbox' );
    like( $notes[0] // '', qr/-oom-tree\.md\z/, 'named for its target' );
    my $note = do { open my $fh, '<', $notes[0] or die $!; local $/; <$fh> };
    like( $note, qr/Advisory only \(SM1081\)/, 'which says it is advisory' );

    # SM1330: prove names each file by the absolute path it was given, which the summary
    # match missed, so neither the line nor the note ever said which files failed.
    my ($line) = $out =~ /^(ext-compat: OOM tree \(9\.9\): FAIL[^\n]*)/m;
    like( $line // '', qr{ - t/unit/odoo/\S+\.t }, 'the FAIL line names the failing files, from t/' );
    unlike( $line // '', qr{\Q$root\E/}, 'not by their absolute paths' );
    like( $line // '', qr/ and \d+ more\z/, 'bounded: the rest are counted' );
    my @listed = $note =~ m{^- (t/\S+\.t)$}mg;
    cmp_ok( scalar @listed, '>', 0, 'the note lists the failing files, one per line' );
    cmp_ok( scalar @listed, '<=', 20, 'no more than twenty of them' );
    like( $note, qr/^- and \d+ more$/m, 'and counts the rest' );
    like( $note, qr/: (\d+) failing files/, 'saying how many failed in all' );

    # SM1330: what the target was run with. Its own oomd (the snapshot's puts the snapshot's
    # library first and ran 0.42 under 0.44), none of the host's packs (whose `shop`
    # claimed the suite's `shop.basket`), and for a tree no share root (its data is
    # beside its lib, and the deb's is another OOM's).
    my @seen = do { open my $fh, '<', "$t/seen" or die "$t/seen: $!"; my %u = map { chomp; $_ => 1 } <$fh>; sort keys %u };
    is_deeply( \@seen, ["LAZYSITE_OOMD=$tree/bin/oomd ODOO_OOM_PACK_DIRS=$vendor/no-packs-here ODOO_OOM_SHARE="],
        'the target ran with its own oomd, no host packs and no share root' ) or diag explain \@seen;
    $run->();
    is( scalar( () = glob("$inbox/*.md") ), 1, 'a second run the same day files no second note' );
    my $quiet = qx(cd $root && OOM_TREE=$t/no-such-tree OOM_DEB_LIB=$t/no-deb LAZYSITE_INBOX=$inbox bash tools/ext-compat.sh 2>&1);
    is( $? >> 8, 0, 'a missing target is a skipped line, still exit 0' );
    like( $quiet, qr/OOM tree: skipped/, 'by name' );
};

# SM1330: the daemon tests start OdooTest::oomd_bin. A library named without its oomd is
# refused, by name, rather than tested on the snapshot's daemon.
subtest 'a daemon test runs the target\'s oomd, and a target without one is refused' => sub {
    my $prog = 'use OdooTest; print eval { OdooTest::oomd_bin() } // "REFUSED: $@"';
    my $ask  = sub {
        run_child( [ 'env', '-u', 'LAZYSITE_OOM_LIB', '-u', 'LAZYSITE_OOMD', @_, $^X, "-I$root/t/lib", "-I$root/lib", '-e', $prog ] )->{out};
    };
    is( $ask->(), "$vendor/bin/oomd", 'in the gate: the snapshot\'s' );
    is( $ask->( "LAZYSITE_OOM_LIB=$t/target/lib", "LAZYSITE_OOMD=$t/target/bin/oomd" ), "$t/target/bin/oomd", 'under the tier: the one it names' );
    like( $ask->("LAZYSITE_OOM_LIB=$t/target/lib"), qr/\AREFUSED: .*LAZYSITE_OOMD is not/, 'a library with no oomd named is refused, naming it' );
};

subtest 'tools/overnight.sh calls it once, after the nightly suite, and never on its result' => sub {
    open my $fh, '<', "$root/tools/overnight.sh" or die $!;
    my $src   = do { local $/; <$fh> };
    my @calls = $src =~ /(ext-compat\.sh[^\n]*)/g;
    is( scalar @calls, 1, 'one call' );
    like( $calls[0], qr/\|\| true|; *true/, 'whose result is discarded' );
    cmp_ok( index( $src, 'ext-compat.sh' ), '>', index( $src, 'nightly suite: exit' ), 'and it is after the nightly suite' );
};

done_testing();
