#!/usr/bin/perl
# SM915: the extension list is ONE registry spelled two ways. SM817 renamed it
# from `plugins:` to `extensions:` and said so in the comment that has held ever
# since - "both open the SAME list, so a site cannot end up with two lists that
# disagree about what is enabled".
#
# Four of the six places that matched a list header did. Two did not: the
# processor's `_enabled_plugins`, which hid manager nav entries for extensions
# that were enabled, and the WRITER, which on an `extensions:` site appended a
# SECOND list under the old spelling and reported success. This gate exists so a
# seventh copy cannot arrive the same way - the defect was never one bug, it was
# one judgement written down six times and drifting.
#
# WHAT THIS DOES NOT CHECK: that a reader parses the entries correctly, or that
# the writer writes the right header back. t/unit/manager/197 holds the writer's
# behaviour. This is a census: every regex anchored on a list header names both
# spellings.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# A line that anchors a regex on one of the two header names, followed by the
# `\s*:` that makes it a conf header rather than a path prefix. Written to accept
# the three real spellings - ^plugins\s*:, ^(?:extensions|plugins)\s*: and
# ^(extensions|plugins)\s*: - and to REJECT a different key that merely starts
# with the same letters, which is why the alternation body is [a-z|]* and not .*
# (`^plugins_extra\s*:` must not be dragged in).
my $HEADER_SITE = qr{
    \^                                      # anchored at line start
    \(?                                     # optional group open
    (?: \?: )?                              #   non-capturing
    [a-z|]*                                 # alternation body before the name
    (?: extensions | plugins )              # one of the two names
    [a-z|]*                                 # alternation body after it
    \)?                                     # optional group close
    \\s\*:                                  # ... \s*:  -- a conf header colon
}x;

my @FILES;
for my $dir ( '', 'lib/Lazysite', 'lib/Lazysite/Manager', 'lib/Lazysite/Auth',
    'lib/Lazysite/Daemon', 'plugins', 'tools', 'cgi-bin' )
{
    my $glob = $root . ( length $dir ? "/$dir" : '' );
    push @FILES, glob("$glob/*.pl"), glob("$glob/*.pm");
}
# The release stage is a copy of the tree; linting it double-counts and can fail
# on an older stage nobody is editing.
#
# RELATIVE TO THE ROOT. This matched `/tmp/` anywhere in the ABSOLUTE path, and
# the release gate runs the suite from a stage under a tmp directory (/tmp, or
# /srv/tmp) - so in the stage every file was excluded, nothing was found, and the
# floor below failed the 0.15.2 gate. Only the tree's own tmp/ and dist/ are
# meant.
@FILES = grep { ( my $rel = $_ ) =~ s{^\Q$root\E/}{}; $rel !~ m{^(?:tmp|dist)/} } @FILES;

my @sites;
for my $f (@FILES) {
    open my $fh, '<', $f or do { fail("$f: unreadable"); next };
    my $n = 0;
    while ( my $line = <$fh> ) {
        $n++;
        next if $line =~ /^\s*#/;    # a comment quoting a regex is not a reader
        next unless $line =~ $HEADER_SITE;
        ( my $rel = $f ) =~ s{^\Q$root\E/}{};
        push @sites, { file => $rel, line => $n, text => $line };
    }
    close $fh;
}

# The gate must not be able to pass by finding nothing. Six sites were measured
# on 2026-09-30 (install.pl, lazysite-processor.pl x2, Notify.pm,
# Manager/Plugins.pm x2); the floor is set below that so adding a reader does not
# fail the suite, but losing the lot does.
cmp_ok( scalar @sites, '>=', 5,
    'the list-header sites are found at all (' . scalar(@sites) . ' seen)' );

for my $s (@sites) {
    my $both = $s->{text} =~ /extensions/ && $s->{text} =~ /plugins/;
    ok( $both,
        "$s->{file}:$s->{line} matches the list header under BOTH spellings" )
        or diag(
        "  $s->{text}"
            . "  SM817: `extensions:` is the name and `plugins:` is the old one, and\n"
            . "  BOTH open the same list. A site keeps whichever it has, so a reader\n"
            . "  that knows one spelling reports the other site's extensions as\n"
            . "  disabled. Copy the shape at lib/Lazysite/Manager/Plugins.pm:\n"
            . "      /^(?:extensions|plugins)\\s*:\\s*\$/\n" );
}

done_testing();
