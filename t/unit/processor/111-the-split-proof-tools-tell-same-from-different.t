#!/usr/bin/perl
# SM1012 (ruled 2026-10-12, Q2): the two tools a split of a long processor sub
# rests on are committed, so a reviewer can rerun the proof - and a proof is
# only as good as its ability to say DIFFERENT. Each is run here on a pair of
# processor trees that are the same and a pair that are not, and must tell
# them apart.
#
#   tools/deparse-subs.pl   every processor sub, deparsed; --compare two trees
#                           and name the subs that differ
#   tools/deparse-block.pl  a block of an old file, wrapped as a sub, against
#                           the sub extracted from it
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $base = dirname( dirname( site_tempdir() ) );

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; return <$fh> }
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# Two copies of this tree's processor: A as it is, B with one sub changed and
# one added.
sub copy_tree {
    my ($to) = @_;
    make_path("$to/lazysite-processor");
    copy( "$root/lazysite-processor.pl", "$to/lazysite-processor.pl" ) or die "copy: $!";
    opendir my $dh, "$root/lazysite-processor" or die $!;
    for my $f ( grep { /\.pm\z/ } readdir $dh ) {
        copy( "$root/lazysite-processor/$f", "$to/lazysite-processor/$f" ) or die "copy $f: $!";
    }
    closedir $dh;
    return $to;
}
my $A = copy_tree("$base/tree-a");
my $B = copy_tree("$base/tree-b");
{
    my $forms = slurp("$B/lazysite-processor/forms.pm");
    $forms =~ s{(sub _esc_attr \{.*?)    \$v =~ s/"/&quot;/g;\n}{$1}s
        or die 'the _esc_attr anchor moved; update this test';
    $forms =~ s{\n1;\s*\z}{\nsub _sm1012_added { return 1 }\n\n1;\n} or die 'no 1; at the foot';
    spit( "$B/lazysite-processor/forms.pm", $forms );
}

# Run a tool, its stderr discarded; returns ( exit code, stdout ).
sub run_tool {
    my ( $tool, @args ) = @_;
    open my $save, '>&', \*STDERR    or die $!;
    open STDERR,   '>',  '/dev/null' or die $!;
    open my $fh,   '-|', $^X, "$root/tools/$tool", @args or die "$tool: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    open STDERR, '>&', $save or die $!;
    return ( $rc, $out // '' );
}

subtest 'deparse-subs lists every processor sub' => sub {
    my ( $rc, $out ) = run_tool( 'deparse-subs.pl', $A );
    is( $rc, 0, 'it exits 0' );
    spit( "$base/a.txt", $out );
    my @names = $out =~ /^=== sub (\S+)$/mg;
    cmp_ok( scalar @names, '>=', 200, 'the script and its parts, not only the script' );
    ok( ( grep { $_ eq '_render_form' } @names ), 'a part\'s sub (forms.pm) is in the list' );
    ok( ( grep { $_ eq 'main' } @names ), 'the script\'s own sub is in the list' );
    is_deeply( \@names, [ sort @names ], 'sorted, so two listings diff line by line' );
};

subtest 'deparse-subs --compare: the same tree is the same' => sub {
    # A tree against a listing saved from it: each side read its own way.
    my ( $rc, $out ) = run_tool( 'deparse-subs.pl', '--compare', "$base/a.txt", $A );
    is( $rc, 0, 'no sub differs and none was expected to' );
    like( $out, qr/^changed: $/m, 'nothing changed' );
};

subtest 'deparse-subs --compare: a changed and an added sub are named' => sub {
    my ( $rc, $out ) = run_tool( 'deparse-subs.pl', $B );
    spit( "$base/b.txt", $out );
    my ( $A, $B ) = ( "$base/a.txt", "$base/b.txt" );    # deparsed once each
    ( $rc, $out ) = run_tool( 'deparse-subs.pl', '--compare', $A, $B );
    is( $rc, 1, 'differences nobody expected fail' );
    like( $out, qr/^changed: _esc_attr$/m,     'the changed sub is named' );
    like( $out, qr/^added:   _sm1012_added$/m, 'the added sub is named' );

    ( $rc, $out ) = run_tool( 'deparse-subs.pl', '--compare', $A, $B, '--expect',
        '_esc_attr,_sm1012_added' );
    is( $rc, 0, 'exactly the expected set differs: pass' ) or diag($out);

    ( $rc, $out ) = run_tool( 'deparse-subs.pl', '--compare', $A, $B, '--expect',
        '_esc_attr,_sm1012_added,_render_form' );
    is( $rc, 1, 'an expected change that did not happen fails too' );
    like( $out, qr/^MISSING .*_render_form/m, 'and is named' );
};

subtest 'deparse-block: a block wrapped as a sub against the sub' => sub {
    # _esc_attr's body in A, the three lines between its unpack and its return.
    my @l    = split /^/m, slurp("$A/lazysite-processor/forms.pm");
    my ($at) = grep { $l[$_] =~ /^sub _esc_attr \{/ } 0 .. $#l;
    ok( defined $at, 'found _esc_attr in the copy' ) or return;
    my ( $from, $to ) = ( $at + 3, $at + 5 );    # 1-based: after the unpack line
    like( $l[ $from - 1 ], qr/unless defined \$v/, 'the block starts where expected' );
    like( $l[ $to - 1 ],   qr/&quot;/,             'and ends where expected' );

    my @args = ( '--old', "$A/lazysite-processor/forms.pm", '--from', $from, '--to', $to,
        '--params', '$v', '--returns', '$v', '--sub', '_esc_attr' );
    my ( $rc, $out ) = run_tool( 'deparse-block.pl', @args, '--tree', $A );
    is( $rc, 0, 'the sub that IS the block: SAME' ) or diag($out);

    ( $rc, $out ) = run_tool( 'deparse-block.pl', @args, '--tree', $B );
    is( $rc, 1, 'a sub that lost a line: DIFFERENT' );
    like( $out, qr/^--- the block, wrapped$/m, 'and both texts are printed' );

    ( $rc, $out ) = run_tool( 'deparse-block.pl', @args[ 0 .. 5 ], '--params', '$v',
        '--sub', '_esc_attr', '--tree', $A );
    is( $rc, 1, 'the wrong return value: DIFFERENT' );

    # --lines: the same block as a range, and with its middle line left out.
    my @rest = ( '--params', '$v', '--returns', '$v', '--sub', '_esc_attr', '--tree', $A );
    ( $rc, $out ) = run_tool( 'deparse-block.pl', '--old', $args[1], '--lines', "$from-$to", @rest );
    is( $rc, 0, '--lines FROM-TO is --from/--to: SAME' ) or diag($out);
    ( $rc, $out ) = run_tool( 'deparse-block.pl', '--old', $args[1], '--lines', "$from,$to", @rest );
    is( $rc, 1, '--lines with a gap leaves the gap out: DIFFERENT' );
};

done_testing();
