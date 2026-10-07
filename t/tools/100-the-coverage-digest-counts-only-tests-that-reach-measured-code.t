#!/usr/bin/perl
# SM950 (3): THE COVERAGE DIGEST MOVES FOR WHAT CAN CHANGE COVERAGE, AND ONLY THAT.
#
# A gate reuses a recorded coverage pass when tools/coverage-inputs.pl gives the
# same digest. Measured across 24 commits on main the digest moved on 11, most
# of them a lint or a tool test that cannot run a CGI. It now leaves out a test
# whose code - read with PPI - starts no process, loads no file by name, calls
# no sub that does, and names no measured file.
#
# The direction that matters is the other one: a skip licensed by a digest that
# did NOT move when coverage could have changed drops the coverage gate from a
# release without anyone seeing it. So most of this file proves that the digest
# MOVES: for every measured file, every module, and every test that launches,
# loads, calls a launcher, calls dynamically, or names a measured CGI - and for
# every test when PPI is not there to show otherwise.
#
# Run against a COPY of the tool in a temporary tree of small stand-in files,
# never against the repository.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
plan skip_all => 'PPI is not installed' unless eval { require PPI; 1 };

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}

my %TREE = (
    'lazysite-processor.pl'          => "print 'processor';\n",
    'lazysite-auth.pl'               => "print 'auth';\n",
    'lazysite-dav.pl'                => "1;\n",
    'lazysite-manager-api.pl'        => "1;\n",
    'lazysite-mcp.pl'                => "1;\n",
    'lazysite-oauth.pl'              => "1;\n",
    'tools/lazysite-users.pl'        => "1;\n",
    'tools/lazysite-bundle-apply.pl' => "1;\n",
    'dist/config/coverage-floor'     => "floor=75\n",
    'tools/coverage.sh'              => "#!/bin/sh\n",
    'plugins/stats.pl'               => "sub stats { 1 }\n1;\n",
    'CHANGELOG.md'                   => "# Changelog\n",
    'docs/guide.md'                  => "A guide.\n",
    'lib/Lazysite/Plain.pm' => "package Lazysite::Plain;\nsub tidy { return 1 }\n1;\n",
    'lib/Lazysite/Spawn.pm' => "package Lazysite::Spawn;\nsub spawn_it { return system('true') }\n"
        . "sub via { return spawn_it() }\n1;\n",
    't/lib/Helper.pm' => "package Helper;\nuse IPC::Open3;\nuse Exporter 'import';\n"
        . "our \@EXPORT_OK = qw(run_it quiet);\nsub run_it { return qx(true) }\nsub quiet { return 2 }\n1;\n",
    't/lib/Loader.pm' => "package Loader;\nsystem('true');\nsub nothing { 1 }\n1;\n",
    't/lib/Wraps.pm'  => "package Wraps;\nuse Loader;\nsub nothing_either { 1 }\n1;\n",

    # Inert: a backtick and `system` in strings, `system` in a comment, a read
    # open, a non-launching helper sub, a hash key named exec.
    't/lint/static.t' => "use strict;\nuse Test::More;\nuse Helper qw(quiet);\n"
        . "# system('rm') is only a comment\nmy \$s = 'a `quoted` word and system too';\n"
        . "open my \$fh, '<', 'CHANGELOG.md' or die;\nmy %h = ( exec => 1 );\n"
        . "ok( quiet() );\ndone_testing();\n",
    't/unit/spawn.t'  => "system(\$^X, 'x.pl');\n",
    't/unit/qx.t'     => "my \$o = qx(true);\n",
    't/unit/pipe.t'   => "open my \$fh, '-|', 'true';\n",
    't/unit/two.t'    => "open my \$fh, 'true |';\n",
    't/unit/do.t'     => "my \$r = do \$ENV{X};\n",
    't/unit/req.t'    => "require \$ENV{X};\n",
    't/unit/eval.t'   => "eval \$ENV{X};\n",
    't/unit/helper.t' => "use Helper qw(run_it);\nrun_it();\n",
    't/unit/lib.t'    => "use Lazysite::Spawn;\nLazysite::Spawn::via();\n",
    't/unit/load.t'   => "use Wraps;\nWraps::nothing_either();\n",
    't/unit/can.t'    => "use Helper;\nmy \$c = Helper->can(\$ENV{X});\n",
    't/unit/cast.t'   => "my \$c = \\&CORE::time;\n&\$c;\n",
    't/unit/named.t'  => "my \$f = 'lazysite-auth.pl';\n",
    't/unit/net.t'    => "use LWP::UserAgent;\n",
);

sub tree {
    my $d = tempdir( CLEANUP => 1 );
    spit( "$d/$_", $TREE{$_} ) for keys %TREE;
    copy( "$root/tools/coverage-inputs.pl", "$d/tools/coverage-inputs.pl" ) or die $!;
    return $d;
}

# PERL5OPT cleared: under coverage.sh the suite runs instrumented, and a
# harness that tests a harness has to stand outside it (t/unit/tools/76).
sub digest {
    my ( $d, @inc ) = @_;
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    my $inc = join ' ', map { "-I\Q$_\E" } @inc;
    my $out = `$^X $inc \Q$d/tools/coverage-inputs.pl\E 2>&1`;
    my ($h) = $out =~ /^([0-9a-f]{64}) \d+$/m;
    return $h // "NO DIGEST: $out";
}

sub listing {
    my ($d) = @_;
    local $ENV{PERL5OPT} = '';
    my %l;
    for ( split /\n/, `$^X \Q$d/tools/coverage-inputs.pl\E --list 2>&1` ) {
        my ( $c, $f, $why ) = split /\t/;
        $l{$f} = [ $c, $why ];
    }
    return \%l;
}

sub append { my ( $p, $t ) = @_; open my $f, '>>', $p or die "$p: $!"; print {$f} $t; close $f }

sub moves {
    my ( $file, $edit, @inc ) = @_;
    my $d      = tree();
    my $before = digest( $d, @inc );
    append( "$d/$file", $edit // "# changed\n1;\n" );
    return digest( $d, @inc ) ne $before;
}

subtest '(a) a change to anything measured moves the digest' => sub {
    for my $f (
        qw(lazysite-processor.pl tools/lazysite-users.pl dist/config/coverage-floor lib/Lazysite/Plain.pm
        plugins/stats.pl t/lib/Helper.pm tools/coverage.sh tools/coverage-inputs.pl)
        )
    {
        ok( moves($f), "$f" );
    }
};

subtest '(b) a change to a test that can reach measured code moves the digest' => sub {
    my $l   = listing( tree() );
    my %why = (
        't/unit/spawn.t'  => qr/launches: system/,
        't/unit/qx.t'     => qr/launches: command/,
        't/unit/pipe.t'   => qr/launches: open \('-\|'\)/,
        't/unit/two.t'    => qr/launches: open \('true \|'\)/,
        't/unit/do.t'     => qr/launches: do EXPR/,
        't/unit/req.t'    => qr/launches: require EXPR/,
        't/unit/eval.t'   => qr/launches: eval EXPR/,
        't/unit/helper.t' => qr/calls a launching sub \(run_it\)/,
        't/unit/lib.t'    => qr/calls a launching sub \(via\)/,
        't/unit/load.t'   => qr/loads a module whose loading launches \(Wraps\)/,
        't/unit/can.t'    => qr/launches: ->can/,
        't/unit/cast.t'   => qr/launches: dynamic call/,
        't/unit/named.t'  => qr/names a measured file \(lazysite-auth\)/,
        't/unit/net.t'    => qr/loads LWP::UserAgent, not known to be inert/,
    );
    for my $t ( sort keys %why ) {
        is( $l->{$t}[0], 'in', "$t is counted" ) or next;
        like( $l->{$t}[1], $why{$t}, '  for the right reason' );
        ok( moves( $t, "# edited\n" ), '  and editing it moves the digest' );
    }
};

subtest '(b) a test shown to reach nothing measured does not, until it can' => sub {
    my $l = listing( tree() );
    is( $l->{'t/lint/static.t'}[0], 'out', 'the inert test is left out' )
        or diag( $l->{'t/lint/static.t'}[1] );
    ok( !moves( 't/lint/static.t', "ok( 1, 'another' );\n" ), 'editing it does not move the digest' );
    ok( moves( 't/lint/static.t', "system('true');\n" ), 'until it launches something' );
    ok( moves( 't/lint/static.t', "Helper::run_it();\n" ), 'or calls a sub that does' );
};

subtest '(c) a document or the changelog does not move it' => sub {
    ok( !moves( 'CHANGELOG.md',  "- an entry\n" ), 'CHANGELOG.md' );
    ok( !moves( 'docs/guide.md', "More.\n" ),      'a doc' );
};

subtest 'without PPI nothing is shown inert, so every test counts' => sub {
    my $fake = tempdir( CLEANUP => 1 );
    spit( "$fake/PPI.pm", "die qq(no PPI here\\n);\n" );
    ok( moves( 't/lint/static.t', "ok( 1, 'another' );\n", $fake ), 'the inert test moves the digest again' );
};

subtest 'the cache changes nothing but the time' => sub {
    my $d     = tree();
    my $first = digest($d);
    ok( -f "$d/tmp/coverage-inputs-cache.sto", 'a cache is written' );
    is( digest($d), $first, 'a cached run gives the same digest' );
    spit( "$d/tmp/coverage-inputs-cache.sto", 'not a cache' );
    is( digest($d), $first, 'and a corrupt cache is ignored' );
};

done_testing();
