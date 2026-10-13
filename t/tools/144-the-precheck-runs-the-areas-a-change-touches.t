#!/usr/bin/perl
# SM1061: THE PRECHECK RUNS THE TESTS OF EACH AREA A CHANGE TOUCHES.
#
# On 2026-10-12 a change to lazysite-processor/sources.pm broke
# t/unit/processor/101, which names no file of the change, so the precheck -
# which ran only the tests naming a changed file - passed it, and the clash went
# unseen until a whole-suite run on main. With the whole suite out of the
# handoff, the precheck also runs every test directory that covers a changed
# area, from the one map in tools/precheck-areas.pl.
#
# Twice: against the real tree (today's case selects t/unit/processor/101), and
# by running the real precheck.sh in a scratch tree with a `prove` on PATH that
# records what it was asked to run. No real suite runs.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    die "git @a: exit $?" if $?;
    chomp $o;
    return $o;
}

sub areas {
    local $ENV{PERL5OPT} = '';
    my $out = run_cmd( $^X, "$root/tools/precheck-areas.pl", @_ );
    return [ split /\n/, $out ];
}

subtest "today's case: sources.pm selects t/unit/processor/101" => sub {
    my $sel = areas('lazysite-processor/sources.pm');
    ok( ( grep { $_ eq 't/unit/processor/101-a-list-is-a-list-and-a-registry-carries-front-matter.t' } @$sel ),
        'the test that broke unseen is in the selection' );
    ok( ( grep { m{^t/integration/} } @$sel ), 'with the integration tests that run the processor' );
    ok( !( grep { m{^t/unit/manager/} } @$sel ), 'and not the manager area' );
};

subtest 'a manager module selects the manager area, not the whole lib/ row' => sub {
    my $sel = areas('lib/Lazysite/Manager/Files.pm');
    ok( ( grep { m{^t/unit/manager/} } @$sel ), 'the manager unit tests' );
    ok( !( grep { m{^t/unit/lib/} } @$sel ), 'the longest prefix wins: not t/unit/lib/' );
    ok( !( grep { m{^t/unit/processor/} } @$sel ), 'and not the processor' );
};

# n562: 124, 128 and 129 reach the manager API only through t/lib/ManagerSession.pm
# and name no front end, so main's precheck missed all three.
subtest 'a manager API change selects the tests that drive it through ManagerSession' => sub {
    for my $file (
        qw(lazysite-manager-api.pl lib/Lazysite/Manager/Files.pm
        lib/Lazysite/ControlApi/Actions.pm lib/Lazysite/Auth/Acl.pm)
        )
    {
        my %sel = map { $_ => 1 } @{ areas($file) };
        for my $t (
            qw(t/integration/124-a-file-rule-binds-a-manage-users-holder.t
            t/integration/128-the-operator-is-the-operator-group.t
            t/integration/129-a-lock-is-taken-by-a-writer.t)
            )
        {
            ok( $sel{$t}, "$file selects $t" );
        }
    }
};

subtest 'a helper change selects the tests that load it' => sub {
    my %sel = map { $_ => 1 } @{ areas('t/lib/ManagerSession.pm') };
    ok( $sel{'t/integration/129-a-lock-is-taken-by-a-writer.t'}, 'ManagerSession.pm selects 129' );
    ok( !( grep { m{^t/unit/processor/} } keys %sel ), 'and not a processor test, which does not load it' );
    my %odoo = map { $_ => 1 } @{ areas('t/lib/LazysiteTest/OdooOps/Basket.pm') };
    ok( ( grep { m{^t/unit/odoo/} } keys %odoo ), 'a pack OdooTest loads by namespace selects its tests' );
    ok( ( grep { m{^t/integration/133-} } @{ areas('t/lib/CrashHook.pm') } ), 'a -M preload counts as loading it' );
};

subtest 'a file outside every area selects nothing' => sub {
    is_deeply( areas('docs/DEVELOPER.md'), [], 'a document is not an area' );
};

# A scratch tree holding the real precheck.sh and precheck-areas.pl, BASE on main
# and CHANGE committed on a branch, and a `prove` on PATH that records what it
# was asked to run. Returns the set of files prove was given.
sub precheck_runs {
    my ( $base, $change ) = @_;
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path( "$d/tools", "$d/tmp" );
    copy( "$root/tools/precheck.sh",       "$d/tools/precheck.sh" )       or die $!;
    copy( "$root/tools/precheck-areas.pl", "$d/tools/precheck-areas.pl" ) or die $!;
    spit( "$d/$_",                 $base->{$_} ) for keys %$base;
    spit( "$d/t/lint/01-a-lint.t", "1;\n" );
    spit( "$d/bin/prove", qq{#!/bin/sh\necho "\$*" > "\$STUB_CALLS"\necho "Files=1, Tests=1"\n} );
    chmod 0755, "$d/bin/prove";
    spit( "$d/.gitignore", "tmp/\nbin/\ncalls\n" );
    git( $d, 'add',      '-A' );
    git( $d, 'commit',   '-q', '-m', 'base' );
    git( $d, 'checkout', '-q', '-b', 'change' );
    spit( "$d/$_", $change->{$_} ) for keys %$change;
    git( $d, 'commit', '-q', '-am', 'the change' );

    local $ENV{PATH}       = "$d/bin:$ENV{PATH}";
    local $ENV{STUB_CALLS} = "$d/calls";
    my $out = run_cmd( 'bash', "$d/tools/precheck.sh", 'main' );
    is( $? >> 8, 0, 'the precheck passed' ) or diag($out);
    return { map { $_ => 1 } split ' ', slurp("$d/calls") };
}

subtest 'precheck.sh hands the area tests to prove' => sub {
    my $ran = precheck_runs(
        { 'lazysite-processor/sources.pm' => "1;\n",
            't/unit/processor/101-a-list-is-a-list.t' => "1;\n",
            't/unit/manager/01-a-manager-test.t'      => "1;\n",
            't/integration/01-runs-the-processor.t'   => "run_processor();\n",
            't/integration/02-runs-something-else.t'  => "1;\n",
        },
        { 'lazysite-processor/sources.pm' => "2;\n" }
    );
    ok( $ran->{'t/unit/processor/101-a-list-is-a-list.t'}, 'the processor area ran, though no test names sources.pm' );
    ok( $ran->{'t/integration/01-runs-the-processor.t'}, 'with the integration test that runs the processor' );
    ok( $ran->{'t/lint/01-a-lint.t'},                  'and the lints, as before' );
    ok( !$ran->{'t/unit/manager/01-a-manager-test.t'}, 'but not another area' );
    ok( !$ran->{'t/integration/02-runs-something-else.t'}, 'nor an integration test of another front end' );
};

# n562: the two gaps n560 found, through the real precheck.sh.
my %MANAGER_TREE = (
    'lazysite-manager-api.pl'                        => "1;\n",
    't/lib/ManagerSession.pm'                        => "package ManagerSession;\n1;\n",
    't/lib/Other.pm'                                 => "package Other;\n1;\n",
    't/integration/124-a-file-rule-binds-a-holder.t' => "use ManagerSession;\n1;\n",
    't/integration/128-the-operator-is-the-group.t' => "use ManagerSession qw(session);\n1;\n",
    't/integration/129-a-lock-is-taken-by-a-writer.t' => "use ManagerSession;\n1;\n",
    't/integration/02-runs-something-else.t'          => "use Other;\n1;\n",
    't/lib/Wrapper.pm' => "package Wrapper;\nuse ManagerSession;\n1;\n",
    't/integration/03-through-a-wrapper.t' => "use Wrapper;\n1;\n",
);

subtest 'precheck.sh runs the ManagerSession tests on a manager API change' => sub {
    my $ran = precheck_runs( \%MANAGER_TREE, { 'lazysite-manager-api.pl' => "2;\n" } );
    ok( $ran->{"t/integration/$_"}, "$_ ran, though it names no front end" )
        for qw(124-a-file-rule-binds-a-holder.t 128-the-operator-is-the-group.t 129-a-lock-is-taken-by-a-writer.t);
    ok( !$ran->{'t/integration/02-runs-something-else.t'}, 'but not a test that drives something else' );
};

subtest 'precheck.sh runs the tests that load a changed helper' => sub {
    my $ran = precheck_runs( \%MANAGER_TREE, { 't/lib/ManagerSession.pm' => "package ManagerSession;\n2;\n" } );
    ok( $ran->{'t/integration/129-a-lock-is-taken-by-a-writer.t'}, 'ManagerSession.pm ran 129' );
    ok( $ran->{'t/integration/03-through-a-wrapper.t'}, 'and a test that loads it through another helper' );
    ok( !$ran->{'t/integration/02-runs-something-else.t'}, 'but not a test that loads another helper' );
};

done_testing();
