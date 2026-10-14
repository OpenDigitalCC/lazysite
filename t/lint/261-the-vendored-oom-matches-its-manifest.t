#!/usr/bin/perl
# SM1081: the pinned snapshot of OOM that lazysite's tests run on is exactly what its
# MANIFEST says - every file present, every hash right, nothing added - so a change to
# it is always DELIBERATE and shows in review as a change to the MANIFEST beside it.
#
# WHY IT EXISTS. Release manager, 2026-10-14: "it isn't intended that oom changes will
# prevent a lazysite build ... we can't be testing against odoo to run a lazysite."
# The tests used to run on OOM's working tree and on the host's perl5 directory, and
# the gate failed three times on 2026-10-13 and 14 for changes that were not lazysite's.
# They now run on t/vendor/oom/, taken from one released commit by tools/vendor-oom.sh.
# A snapshot that anyone could edit by hand, or that drifted, would be the same
# problem in a different place; this is the check that it does not.
#
# THE FIX is never to edit the MANIFEST by hand: run tools/vendor-oom.sh with the
# commit (and the deb, when there is one) and review what changed.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use File::Find  ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $dir      = repo_root() . '/t/vendor/oom';
my $manifest = "$dir/MANIFEST";
ok( -d $dir && -f $manifest, 'the vendored OOM and its MANIFEST are in the repository' )
    or BAIL_OUT('t/vendor/oom/MANIFEST is missing - run tools/vendor-oom.sh');

my ( %want, %meta );
open my $fh, '<', $manifest or die "$manifest: $!";
while ( my $l = <$fh> ) {
    chomp $l;
    if ( $l =~ /\A([0-9a-f]{64})  (\S.*)\z/ ) { $want{$2} = $1; next }
    $meta{$1} = $2 if $l =~ /\A([a-z0-9-]+): (.*)\z/;
}
close $fh;

for my $k (qw(source-commit source-commit-date source-subject source-deb licence spec-sha256)) {
    ok( defined $meta{$k} && length $meta{$k}, "the MANIFEST says $k" );
}
like( $meta{'source-commit'} // '', qr/\A[0-9a-f]{40}\z/, 'and the source commit is a full hash' );
cmp_ok( scalar keys %want, '>', 50, 'and it lists the snapshot\'s files' );

my @bad;
for my $rel ( sort keys %want ) {
    my $p = "$dir/$rel";
    unless ( -f $p ) { push @bad, "missing:  $rel"; next }
    open my $in, '<:raw', $p or do { push @bad, "unreadable: $rel"; next };
    local $/;
    my $got = sha256_hex(<$in>);
    push @bad, "changed:  $rel" if $got ne $want{$rel};
}
is_deeply( \@bad, [], 'every file in the MANIFEST is there and has its hash' )
    or diag( join "\n", @bad, '', 'The snapshot was edited by hand, or half-refreshed. Run tools/vendor-oom.sh.' );

my @extra;
File::Find::find(
    { no_chdir => 1, wanted => sub {
            return unless -f $_;
            ( my $rel = $_ ) =~ s{\A\Q$dir\E/}{};
            push @extra, $rel unless $rel eq 'MANIFEST' || exists $want{$rel};
    } },
    $dir
);
is_deeply( [ sort @extra ], [], 'and nothing is in the snapshot that the MANIFEST does not list' );

my $spec = "$dir/docs/MAPPER-SPEC.md";
if ( -f $spec ) {
    open my $in, '<:raw', $spec or die $!;
    local $/;
    is( sha256_hex(<$in>), $meta{'spec-sha256'}, 'and the spec-sha256 line is the spec\'s hash' );
}

done_testing();
