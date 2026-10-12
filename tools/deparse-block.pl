#!/usr/bin/perl
# tools/deparse-block.pl - is an extracted sub the block it was cut from?
#
# Splitting a long sub changes the parent's deparse by construction, so
# tools/deparse-subs.pl can only show that every OTHER sub is unchanged. This
# shows the rest (SM944 S33, SM1012): it takes the block's lines from the file
# as it was, wraps them the way the extraction did -
#
#     sub __block__ { my (PARAMS) = @_; <the block> return RETURNS; }
#
# - compiles that in package main beside the processor of TREE, and compares
# B::Deparse's text of it with the text of the new sub. Equal text means the
# new sub is the old block with its free variables as parameters and its
# result as the return value: nothing was edited on the way across.
#
#   perl tools/deparse-block.pl --old REV:PATH --from N --to M \
#       --sub NAME [--params '$a, %b'] [--returns '$x'] [--tree DIR]
#
#   --old      the file the block came from: REV:PATH (as `git show` takes it)
#              or a file on disk
#   --from/--to  the block's first and last line in that file, inclusive
#   --sub      the extracted sub, as TREE defines it in package main
#   --params   the sub's parameter list, unpacked as `my (PARAMS) = @_;`
#              (omit for a sub that takes none)
#   --returns  what the sub returns (omit for one that returns nothing)
#   --tree     the tree whose processor defines --sub (default: this one)
#
# The block is compiled under the pragmas the old file opens with (its leading
# `use strict` / `use warnings` / `no warnings` lines) and its file-scope `our`
# declarations, so it sees the package variables it saw in place. A block that
# reads a file-scope `my` variable cannot be compiled this way and is refused
# with Perl's own error. Exit 0 when the two texts are equal, 1 when they
# differ (both are printed), 2 on a usage or compile error.
#
# Development only: excluded from the release manifest
# (dist/config/classification.json).
package DeparseBlock;

use strict;
use warnings;
use FindBin;

( my $ROOT = $FindBin::Bin ) =~ s{/tools\z}{};

sub usage {
    print STDERR "usage: $0 --old REV:PATH --from N --to M --sub NAME"
        . " [--params LIST] [--returns EXPR] [--tree DIR]\n";
    exit 2;
}

sub old_lines {
    my ($old) = @_;
    my $text;
    if ( -f $old ) {
        open my $fh, '<', $old or die "$0: $old: $!\n";
        local $/;
        $text = <$fh>;
        close $fh;
    }
    else {
        open my $gh, '-|', 'git', '-C', $ROOT, 'show', $old or die "$0: git: $!\n";
        local $/;
        $text = <$gh>;
        close $gh or die "$0: git show $old failed\n";
    }
    return split /^/m, $text;
}

# The pragmas and file-scope `our` declarations of the old file, so the block
# compiles in the scope it was written in.
sub file_scope {
    my (@lines) = @_;
    my @keep;
    for my $l (@lines) {
        last if $l =~ /^sub\s/;
        push @keep, $l if $l =~ /^(?:use\s+(?:strict|warnings)|no\s+warnings|our\s)/;
    }
    return join '', @keep;
}

sub load_processor {
    my ($tree) = @_;
    require File::Temp;
    my $doc = File::Temp::tempdir( 'deparse-doc-XXXX', TMPDIR => 1, CLEANUP => 1 );
    mkdir "$doc/lazysite" or die "$0: mkdir: $!\n";
    local $ENV{DOCUMENT_ROOT}  = $doc;
    local $ENV{REDIRECT_URL}   = '/__deparse_block_nonexistent__';
    local $ENV{REQUEST_METHOD} = 'GET';
    local $ENV{QUERY_STRING}   = '';
    my $proc = "$tree/lazysite-processor.pl";
    die "$0: no $proc\n" unless -f $proc;
    open my $null, '>',  '/dev/null' or die "$0: /dev/null: $!\n";
    open my $so,   '>&', \*STDOUT    or die "$0: dup: $!\n";
    open my $se,   '>&', \*STDERR    or die "$0: dup: $!\n";
    open STDOUT,   '>&', $null       or die "$0: redirect: $!\n";
    open STDERR,   '>&', $null       or die "$0: redirect: $!\n";
    my $ok  = do_in_main($proc);
    my $err = $@;
    open STDOUT, '>&', $so or die "$0: restore: $!\n";
    open STDERR, '>&', $se or die "$0: restore: $!\n";
    die "$0: $proc did not load: $err\n" if !$ok && $err;
    return;
}

sub do_in_main {
    my ($file) = @_;

    package main;    ## no critic (ProhibitMultiplePackages) - the processor's own package
    return do $file;
}

sub compile_in_main {
    my ($src) = @_;

    package main;    ## no critic (ProhibitMultiplePackages) - the processor's own package
    return eval $src; ## no critic (ProhibitStringyEval) - the block under test is source text
}

my %o = ( tree => $ROOT );
while (@ARGV) {
    my $k = shift @ARGV;
    usage() unless $k =~ /\A--(old|from|to|sub|params|returns|tree)\z/ && @ARGV;
    $o{$1} = shift @ARGV;
}
usage() unless defined $o{old} && defined $o{sub} && ( $o{from} // '' ) =~ /\A\d+\z/
    && ( $o{to} // '' ) =~ /\A\d+\z/ && $o{to} >= $o{from};

my @lines = old_lines( $o{old} );
die "$0: $o{old} has " . scalar(@lines) . " lines, not $o{to}\n" if $o{to} > @lines;
my @block = @lines[ $o{from} - 1 .. $o{to} - 1 ];
print "block: $o{old} lines $o{from}-$o{to}\n  first: $block[0]  last:  $block[-1]";

my $src = "no strict;\nno warnings;\n"
    . file_scope(@lines)
    . "sub deparse_block_wrapped {\n"
    . ( defined $o{params} ? "    my ( $o{params} ) = \@_;\n" : '' )
    . "#line $o{from}\n"
    . join( '', @block )
    . ( defined $o{returns} ? "    return $o{returns};\n" : '' )
    . "}\n1;\n";

load_processor( $o{tree} );
compile_in_main($src) or do { print STDERR "$0: the block does not compile: $@"; exit 2 };

require B::Deparse;
my $d = B::Deparse->new( '-q', '-si4' );
my $new = main->can( $o{sub} ) or do { print STDERR "$0: $o{tree} defines no main::$o{sub}\n"; exit 2 };
my $before = $d->coderef2text( main->can('deparse_block_wrapped') );
my $after  = $d->coderef2text($new);
if ( $before eq $after ) {
    print "SAME: main::$o{sub} deparses as the block, wrapped\n";
    exit 0;
}
print "DIFFERENT\n--- the block, wrapped\n$before\n--- main::$o{sub}\n$after\n";
exit 1;
