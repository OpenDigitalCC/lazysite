#!/usr/bin/perl
# SM948: A GENERATED DOCUMENT IS REGENERATED, NOT FAILED ON.
#
# Five documents are generated from code and each has a test that fails when it
# is stale. In 0.15.2 a stale one failed the six-minute handoff three times, each
# fixed by running one command. tools/regen-generated.sh runs every generator and
# names what changed; tools/handoff.sh runs it first and commits the result.
#
# Run against a COPY of the script in a temporary tree with stand-in
# generators: editing the real documents here would race the tests that read
# them under -j4.
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
sub spit { open my $f, '>', $_[0] or die "$_[0]: $!"; print {$f} $_[1]; close $f }
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

sub tree {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/tools", "$d/docs/reference" );
    copy( "$root/tools/regen-generated.sh", "$d/tools/regen-generated.sh" ) or die $!;
    spit( "$d/tools/gen-capability-docs.pl", 'print "doc:$ARGV[0]\n"; ' . ( $o{fail} ? 'exit 1;' : '' ) );
    spit( "$d/tools/gen-host-deps.pl",       'print "hostdeps\n";' );
    spit( "$d/tools/gen-doc-index.pl",       'open my $f, ">", "docs/INDEX.md" or die; print {$f} "index\n";' );
    spit( "$d/docs/reference/$_->[0]", $_->[1] ) for (
        [ 'capability-map.md',      "doc:map\n" ],
        [ 'quickstarts.md',         "doc:quickstarts\n" ],
        [ 'control-api-actions.md', "doc:actions\n" ],
        [ 'host-dependencies.md',   "hostdeps\n" ] );
    spit( "$d/docs/INDEX.md", "index\n" );
    return $d;
}
sub run { my ($d) = @_; my $o = `bash \Q$d/tools/regen-generated.sh\E 2>&1`; return ( $? >> 8, $o ) }

subtest 'a current tree is left alone and nothing is named' => sub {
    my ( $rc, $out ) = run( tree() );
    is( $rc,  0,  'exit 0' );
    is( $out, '', 'nothing printed, so the handoff commits nothing' );
};

subtest 'a stale document is rewritten and named' => sub {
    my $d = tree();
    spit( "$d/docs/reference/quickstarts.md", "stale\n" );
    my ( $rc, $out ) = run($d);
    is( $rc, 0, 'exit 0' );
    is( $out, "docs/reference/quickstarts.md\n", 'only the stale one is named' );
    is( slurp("$d/docs/reference/quickstarts.md"), "doc:quickstarts\n", 'and it is current again' );
};

subtest 'a failing generator fails, and leaves the document as it was' => sub {
    my $d = tree( fail => 1 );
    my ( $rc, $out ) = run($d);
    isnt( $rc, 0, 'non-zero, so the handoff fails on it' );
    like( $out, qr/regen: FAILED/, 'saying which' );
    is( slurp("$d/docs/reference/capability-map.md"), "doc:map\n", 'the document is untouched' );
};

subtest 'the handoff runs it and commits what it names' => sub {
    my $h = slurp("$root/tools/handoff.sh");
    like( $h, qr/REGEN=\$\(bash tools\/regen-generated\.sh\)/, 'handoff runs the script' );
    like( $h, qr/git add \$REGEN && git commit/, 'and commits only what it named' );
};

done_testing();
