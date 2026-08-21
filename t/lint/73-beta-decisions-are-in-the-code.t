#!/usr/bin/perl
# Two release-manager decisions, asserted where they live.
#
# SM462: adding a principal grants BOTH rights. It defaulted to read on,
# write off - and an empty write list means NO RESTRICTION, so the ordinary
# way of restricting a file produced a rule that locked reads and left writes
# open. An operator was shown "rw", the stored rule was read-only, and they
# found they could SAVE a file they could not PREVIEW.
#
# Read+write fails SAFE: too few people able to write is a nuisance, too many
# is the thing the feature exists to prevent. The per-chip toggles are
# untouched, so narrowing it back is one visible click.
#
# SM461: the all-files History OVERVIEW is hidden for this release - it fails
# with a JSON parse error while its data is fine, and diagnosing it needs a
# browser. The per-file History panel is NOT hidden: that one is a file
# operation, it works, and hiding it would remove something useful to fix
# something else.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/files.md';
plan skip_all => 'files page missing' unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

subtest 'SM462: a new principal gets read AND write' => sub {
    my ($fn) = $src =~ /function addPrincipal\(sel\)\s*\{(.*?)\n\}/s;
    ok( defined $fn, 'addPrincipal is present' ) or BAIL_OUT('cannot find it');
    like( $fn, qr/chipHtml\(name, 1, 1\)/,
        'both rights are on by default' )
        or diag( 'read-on/write-off stores an EMPTY write list, and an empty '
            . 'list means no restriction - so the file ends up readable by '
            . 'fewer people than can write it.' );
    unlike( $fn, qr/chipHtml\(name, 1, 0\)/, 'and not read-only' );
};

subtest 'SM461: the OVERVIEW is hidden, the per-file panel is not' => sub {
    my ($fn) = $src =~ /function loadGitStatus\(\)\s*\{(.*?)\n\}/s;
    ok( defined $fn, 'loadGitStatus is present' );
    like( $fn, qr/hb\.style\.display = 'none'/,
        'the overview button is hidden unconditionally' )
        or diag( 'It fails with a JSON parse error while its data is fine.' );
    unlike( $fn, qr/GIT\.enabled \? '' : 'none'/,
        'not merely gated on the feature being enabled' );

    # The per-file panel must survive. Hiding it would remove something that
    # works to fix something that does not.
    like( $src, qr/toggleHistory\(this\)/,
        'the per-file History control is still offered' )
        or diag( 'That one IS a file operation and belongs beside the file.' );
};

done_testing();
