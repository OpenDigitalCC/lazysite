#!/usr/bin/perl
# SM1081: no file under t/, lib/ or tools/ names OOM's working tree or reads OOM from
# the host's perl5 directory, except the two tools that exist to do exactly that
# (tools/vendor-oom.sh, which refreshes the snapshot, and tools/ext-compat.sh, the
# advisory compatibility tier).
#
# WHY. The release gate failed THREE TIMES on 2026-10-13 and 14 - lint 207 against
# OOM's working tree as it moved, and Odoo tests that read whichever OOM the host had -
# for changes that were not lazysite's. Release manager, 2026-10-14: "it isn't intended
# that oom changes will prevent a lazysite build ... we can't be testing against odoo to
# run a lazysite, it's just an extension, not core." The tests run on t/vendor/oom/
# (held to its MANIFEST by t/lint/261); this lint holds the other half: nothing reaches
# past it to the host. A new test that names /srv/projects/odoo fails here, in review,
# not at 01:30 on the night of a cut.
#
# t/vendor/ itself is OOM's own code and is not scanned (it is held by t/lint/261).
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# What reaches past the snapshot. Built from pieces so that this file does not name
# them whole, and is therefore not its own finding.
my @NAMES = (
    '/srv/projects/' . 'odoo',            # OOM's working tree
    '/usr/share/perl5/' . 'Odoo',         # the deb's library
    '/usr/share/' . 'odoo-oom',           # the deb's data directory
    '/usr/share/doc/libodoo-' . 'oom',    # the deb's documents
);

my %ALLOWED = map { $_ => 1 } qw(
    tools/vendor-oom.sh tools/ext-compat.sh
    t/lint/262-nothing-the-gate-runs-reads-oom-from-the-host.t
);    # the last is this file, which has to say what it forbids

# SM1164 D0 (release manager, 2026-10-18: "narrow exemption in lint 262"): ONE
# LINE OF PRODUCTION CODE MAY NAME THE DEB'S DATA DIRECTORY. odoo_pack_dirs may
# name the packaged packs, so Lazysite::Odoo must say where they are; that is a
# path an operator configures, not something the gate reads. Only the
# declaration line is exempt, matched whole, so a second mention in the file, or
# any test naming the path, is still a finding.
my %ALLOWED_LINE = (
    'lib/Lazysite/Odoo.pm' => q{our $PACKAGED_PACKS = '} . '/usr/share/' . q{odoo-oom/packs';},
);

my @files;
for my $top (qw(t lib tools)) {
    next unless -d "$root/$top";
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                if ( -d $_ && $_ =~ m{/t/vendor\z} ) { $File::Find::prune = 1; return }
                return unless -f $_ && !-l $_;
                return if /\.(?:png|jpe?g|gif|ico|woff2?|gz|zip|tar|deb|sqlite)\z/i;
                ( my $rel = $_ ) =~ s{\A\Q$root\E/}{};
                push @files, $rel;
            } },
        "$root/$top"
    );
}
cmp_ok( scalar @files, '>', 200, 'the scan found the tree' );

my @found;
for my $rel ( sort @files ) {
    next if $ALLOWED{$rel};
    open my $fh, '<:raw', "$root/$rel" or next;
    local $/;
    my $t = <$fh>;
    next if $t =~ /\0/;
    if ( defined( my $line = $ALLOWED_LINE{$rel} ) ) {
        $t = join "\n", grep { $_ ne $line } split /\n/, $t;
    }
    for my $n (@NAMES) {
        push @found, "$rel names $n" if index( $t, $n ) >= 0;
    }
}
is_deeply( \@found, [], 'nothing the gate runs names OOM\'s tree or reads OOM from the host' )
    or diag( join( "\n", @found ) . "\n\nA test must run on t/vendor/oom (OdooTest::oom_lib). Reading OOM from the host\n"
        . "is for tools/ext-compat.sh only, which is advisory and never the gate (SM1081)." );

done_testing();
