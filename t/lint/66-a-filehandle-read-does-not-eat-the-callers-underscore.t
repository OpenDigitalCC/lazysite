#!/usr/bin/perl
# SM420: `while (<$fh>)` assigns the GLOBAL $_.
#
# A sub that does it without `local $_` destroys its CALLER's $_ - so
# `grep { some_predicate($_) } @list` silently loses the element under test if
# that predicate reads a file anywhere beneath it. SM419 hit exactly this:
# is_blocked_config -> upload_limits -> load_upload_limits, and the summary
# filter dropped the first path it looked at.
#
# It is worse than an ordinary bug because upload_limits MEMOISES: only the
# first call in a process clobbers, so the first element of the first such grep
# comes back empty and every later one is fine. A corruption a second run hides
# is one nobody debugs; they re-run it, see it pass, and move on.
#
# So the shape is banned outright rather than case-by-case. `local $_;` costs
# one line and removes the whole class - including from subs nobody calls from
# a grep TODAY, because the difference between latent and live is one caller.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files;
for my $dir ( "$root/lib", $root, "$root/plugins" ) {
    next unless -d $dir;
    opendir my $dh, $dir or next;
    push @files, map { "$dir/$_" } grep { /\.p[lm]$/ } readdir $dh;
    closedir $dh;
}
# lib/ is a tree, so walk it properly for the modules.
if ( -d "$root/lib" ) {
    require File::Find;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub { push @files, $_ if -f $_ && /\.pm$/ },
        },
        "$root/lib"
    );
}
my %seen;
@files = grep { !$seen{$_}++ } @files;
ok( scalar @files > 10, 'found the source files to check (sanity)' );

my @offenders;
for my $f (@files) {
    open my $fh, '<', $f or next;
    my $src = do { local $/; <$fh> };
    close $fh;
    ( my $short = $f ) =~ s{^\Q$root\E/}{};

    while ( $src =~ /\nsub (\w+)\s*\{(.*?)(?=\nsub \w|\z)/gs ) {
        my ( $name, $body ) = ( $1, $2 );
        ( my $code = $body ) =~ s/^\s*#.*$//mg;
        next unless $code    =~ /while \s* \( \s* < \$? \w+ > \s* \)/x;
        next if $code        =~ /local \s+ \$_ \s* ;/x;
        push @offenders, "$short:$name";
    }
}

is_deeply( \@offenders, [],
    'every sub that reads a filehandle into $_ localises it first' )
    or diag( "These eat their caller's \$_:\n  "
        . join( "\n  ", @offenders )
        . "\n\nAdd `local \$_;` at the top of each. See SM419 for what it "
        . "costs when one of them is reached from inside a grep." );

done_testing();
