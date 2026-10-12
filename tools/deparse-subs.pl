#!/usr/bin/perl
# tools/deparse-subs.pl - every sub the processor defines, as Perl compiled it.
#
# A refactor that splits or moves code says "nothing else changed". This is how
# that is shown rather than asserted (SM944 S16, SM1012): load the processor the
# way a request does, deparse every sub defined in lazysite-processor.pl or one
# of its parts with B::Deparse, and compare two trees sub by sub. Comments,
# layout and which file a sub lives in do not reach the deparse; a changed
# expression, a bareword that now parses as a call, a constant written
# differently - all do.
#
#   perl tools/deparse-subs.pl TREE
#       print every processor sub of TREE, sorted by name, each headed
#       `=== sub NAME`
#   perl tools/deparse-subs.pl --compare OLD NEW [--expect NAME,NAME...] [--show]
#       deparse both and compare. Exit 0 when the subs that differ (changed,
#       added or removed) are exactly the --expect set; 1 otherwise. --show
#       prints both texts of each changed sub.
#
# TREE, OLD and NEW are each a directory holding lazysite-processor.pl, or a git
# revision of this repository (its processor is exported to a temporary
# directory with `git archive`). Each tree is deparsed in its own perl, because
# two processors cannot be loaded into one. OLD and NEW may also be a listing
# saved from the first form, so a tree deparsed once can be compared often.
#
# Development only: excluded from the release manifest
# (dist/config/classification.json). Reads the repository; writes nothing but
# its temporary directories.
# Its own package: the processor it loads defines its subs in main.
package DeparseSubs;

use strict;
use warnings;
use B          ();
use File::Temp qw(tempdir);
use FindBin;

( my $ROOT = $FindBin::Bin ) =~ s{/tools\z}{};

sub usage {
    print STDERR "usage: $0 TREE\n"
        . "       $0 --compare OLD NEW [--expect NAME,NAME...] [--show]\n";
    exit 2;
}

# A directory is a tree as it stands; anything else is a revision to export.
sub tree_dir {
    my ($spec) = @_;
    return $spec if -d $spec && -f "$spec/lazysite-processor.pl";
    my $tmp = tempdir( 'deparse-tree-XXXX', TMPDIR => 1, CLEANUP => 1 );
    system( 'git', '-C', $ROOT, 'archive', '-o', "$tmp/t.tar", $spec, '--',
        'lazysite-processor.pl', 'lazysite-processor' ) == 0
        or die "$0: $spec is neither a processor tree nor a revision\n";
    system( 'tar', '-xf', "$tmp/t.tar", '-C', $tmp ) == 0 or die "$0: tar failed\n";
    return $tmp;
}

# Load TREE's processor into this perl and print every sub it defines.
sub deparse_tree {
    my ($tree) = @_;
    require B::Deparse;
    my $doc = tempdir( 'deparse-doc-XXXX', TMPDIR => 1, CLEANUP => 1 );
    mkdir "$doc/lazysite" or die "$0: mkdir: $!\n";
    local $ENV{DOCUMENT_ROOT}  = $doc;
    local $ENV{REDIRECT_URL}   = '/__deparse_subs_nonexistent__';
    local $ENV{REQUEST_METHOD} = 'GET';
    local $ENV{QUERY_STRING}   = '';
    my $proc = "$tree/lazysite-processor.pl";
    die "$0: no $proc\n" unless -f $proc;
    {
        # The processor answers its request (a 404) when it loads; keep that
        # out of the listing.
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
    }
    my $dp = B::Deparse->new;
    my $n  = 0;
    for my $name ( sort keys %main:: ) {
        my $cr   = main->can($name) or next;
        my $file = B::svref_2object($cr)->FILE // '';
        next unless $file =~ m{lazysite-processor(?:\.pl|/[\w-]+\.pm)\z};
        print "=== sub $name\n", $dp->coderef2text($cr), "\n";
        $n++;
    }
    print STDERR "$n subs\n";
    return $n;
}

# `do` compiles in the caller's package; the processor has none of its own.
sub do_in_main {
    my ($file) = @_;

    package main;    ## no critic (ProhibitMultiplePackages) - the processor's own package
    return do $file;
}

# NAME => text, from a listing this tool printed.
sub parse_listing {
    my ($text) = @_;
    my %sub;
    my @parts = split /^=== sub (\S+)\n/m, $text;
    shift @parts;
    while (@parts) {
        my ( $name, $body ) = splice @parts, 0, 2;
        $sub{$name} = $body;
    }
    return \%sub;
}

sub listing_of {
    my ($spec) = @_;
    if ( -f $spec ) {
        open my $fh, '<', $spec or die "$0: $spec: $!\n";
        local $/;
        my $saved = <$fh>;
        close $fh;
        die "$0: $spec is not a listing this tool printed\n" unless $saved =~ /\A=== sub /;
        return parse_listing($saved);
    }
    my $dir = tree_dir($spec);
    my $out = `$^X \Q$0\E \Q$dir\E 2>/dev/null`;
    die "$0: deparsing $spec failed\n" if $? != 0 || $out !~ /^=== sub /m;
    return parse_listing($out);
}

sub compare {
    my ( $old_spec, $new_spec, $expect, $show ) = @_;
    my $old = listing_of($old_spec);
    my $new = listing_of($new_spec);
    my ( @same, @changed, @added, @removed );
    for my $n ( sort keys %$old ) {
        if    ( !exists $new->{$n} )       { push @removed, $n }
        elsif ( $old->{$n} eq $new->{$n} ) { push @same,    $n }
        else                               { push @changed, $n }
    }
    @added = grep { !exists $old->{$_} } sort keys %$new;

    printf "%s: %d subs; %s: %d subs\n", $old_spec, scalar keys %$old, $new_spec,
        scalar keys %$new;
    print "same:    ", scalar(@same), "\n";
    print "changed: @changed\n";
    print "added:   @added\n";
    print "removed: @removed\n";
    if ($show) {
        for my $n (@changed) {
            print "--- $n in $old_spec\n$old->{$n}--- $n in $new_spec\n$new->{$n}";
        }
    }

    my %want       = map  { $_ => 1 } @$expect;
    my %got        = map  { $_ => 1 } @changed, @added, @removed;
    my @unexpected = grep { !$want{$_} } sort keys %got;
    my @missing    = grep { !$got{$_} } sort keys %want;
    print "UNEXPECTED (differ, not in --expect): @unexpected\n" if @unexpected;
    print "MISSING (in --expect, deparse the same): @missing\n" if @missing;
    if ( @unexpected || @missing ) { print "RESULT: DIFFERENT\n"; return 1 }
    print "RESULT: only the expected subs differ\n";
    return 0;
}

usage() unless @ARGV;
if ( $ARGV[0] eq '--compare' ) {
    shift @ARGV;
    my ( @pos, @expect, $show );
    while (@ARGV) {
        my $a = shift @ARGV;
        if ( $a eq '--expect' )  { push @expect, split /,/, ( shift(@ARGV) // usage() ) }
        elsif ( $a eq '--show' ) { $show = 1 }
        else                     { push @pos, $a }
    }
    usage() unless @pos == 2;
    exit compare( @pos, \@expect, $show );
}
usage() unless @ARGV == 1;
exit( deparse_tree( tree_dir( $ARGV[0] ) ) ? 0 : 1 );
