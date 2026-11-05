#!/usr/bin/perl
# SM915 / SM1142: the extension list is read under ONE name, everywhere.
#
# SM817 renamed the list from its old header to `extensions:` and kept both
# readable; SM915 found two of six readers knowing one spelling - the processor's
# nav reader, which hid entries for enabled extensions, and the WRITER, which
# appended a second list - and this gate held every reader to both. SM1142 (R3,
# "fixup on upgrade, then its done") retired the old name: install.pl's
# extensions-rename converts a site's list once, and from then on a reader that
# still knew the old header would see a list nothing else sees.
#
# So the census is turned round: every regex anchored on a list header names
# `extensions` and nothing else. The two places that must read the old header to
# do their job - the upgrade step that converts it and the check that names a
# list written back under it - sit inside `old-name` regions, which t/lint/307
# confines to a fixed list of files.
#
# WHAT THIS DOES NOT CHECK: that a reader parses the entries correctly
# (t/lint/125 runs the readers) or what the writer writes (t/unit/manager/198).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# A regex anchored at line start on a word followed by the `\s*:` that makes it
# a conf header: ^extensions\s*:, ^(?:extensions|other)\s*:, ^(\w+)\s*: and so on.
# The alternation body is [a-z|]* so a different key that merely starts with the
# same letters (`^extensions_extra\s*:`) is not dragged in.
my $HEADER_SITE = qr{
    \^                                      # anchored at line start
    \(?                                     # optional group open
    (?: \?: )?                              #   non-capturing
    ( [a-z|]* extensions [a-z|]* )          # the alternation naming the list
    \)?                                     # optional group close
    \\s\*:                                  # ... \s*:  -- a conf header colon
}x;

my @FILES;
for my $dir ( '', 'lib/Lazysite', 'lib/Lazysite/Manager', 'lib/Lazysite/Auth',
    'lib/Lazysite/Daemon', 'extensions', 'tools', 'cgi-bin', 'lazysite-processor' )
{
    my $glob = $root . ( length $dir ? "/$dir" : '' );
    push @FILES, glob("$glob/*.pl"), glob("$glob/*.pm");
}
# The release stage is a copy of the tree; only the tree's own tmp/ and dist/
# are excluded, RELATIVE TO THE ROOT (the gate's stage itself lives under a tmp).
@FILES = grep { ( my $rel = $_ ) =~ s{^\Q$root\E/}{}; $rel !~ m{^(?:tmp|dist)/} } @FILES;

my @sites;
for my $f (@FILES) {
    open my $fh, '<', $f or do { fail("$f: unreadable"); next };
    my ( $n, $old ) = ( 0, 0 );
    while ( my $line = <$fh> ) {
        $n++;
        $old = 1, next if $line =~ /^\s*# old-name: begin\b/;
        $old = 0, next if $line =~ /^\s*# old-name: end\b/;
        next if $old;
        next if $line =~ /^\s*#/;    # a comment quoting a regex is not a reader
        next unless $line =~ $HEADER_SITE;
        my $alt = $1;
        ( my $rel = $f ) =~ s{^\Q$root\E/}{};
        push @sites, { file => $rel, line => $n, text => $line, alt => $alt };
    }
    close $fh;
}

# The gate must not be able to pass by finding nothing. Six readers and the
# installer's writer were measured on 2026-11-05 (install.pl, the processor's
# access-log.pm and layout.pm, Notify.pm, Manager/Extensions.pm x2).
cmp_ok( scalar @sites, '>=', 5,
    'the list-header sites are found at all (' . scalar(@sites) . ' seen)' );

for my $s (@sites) {
    is( $s->{alt}, 'extensions',
        "$s->{file}:$s->{line} matches the list header under the one name" )
        or diag(
        "  $s->{text}"
            . "  SM1142: `extensions:` is the one name - the upgrade converted the old\n"
            . "  one, so a reader that knows another spelling sees a list nothing else\n"
            . "  sees. Copy the shape at lib/Lazysite/Manager/Extensions.pm:\n"
            . "      /^extensions\\s*:\\s*\$/\n" );
}

done_testing();
