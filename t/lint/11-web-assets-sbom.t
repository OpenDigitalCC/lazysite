#!/usr/bin/perl
# SM147: every bundled third-party web asset (vendored JS/CSS shipped in the
# tree - CodeMirror, qrcode-generator, ...) must be declared in the SBOM deps
# (dist/config/sbom-deps.json "web_assets"), so it appears in the release SBOM
# and THIRD-PARTY-NOTICES. This gate scans for the tell-tale vendored files
# (minified bundles, or an explicit vendor list) and fails if any is not
# covered by a web_assets `files` glob - so adding a library without declaring
# it cannot ship silently.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Load the declared globs.
open my $fh, '<', "$root/dist/config/sbom-deps.json" or BAIL_OUT("no sbom-deps.json: $!");
my $deps = decode_json( do { local $/; <$fh> } );
close $fh;
my @globs = grep { defined && length }
    map { $_->{files} } @{ $deps->{web_assets} // [] };
ok( scalar @globs, 'sbom-deps declares at least one web_asset files glob' );

# glob -> anchored regex (only * supported, matching within a path segment set).
sub glob_re {
    my $g = shift;
    $g = quotemeta $g;
    $g =~ s/\\\*/.*/g;
    return qr/\A$g\z/;
}
my @res = map { glob_re($_) } @globs;
sub covered { my $p = shift; for my $re (@res) { return 1 if $p =~ $re } return 0 }

# Candidate vendored files: minified bundles + the known vendored plain-JS lib.
# (lazysite's own assets are hand-written and NOT minified.)
my @candidates;
my $wanted = sub {
    my $p = $File::Find::name;
    return unless -f $p;
    ( my $rel = $p ) =~ s{^\Q$root\E/}{};
    push @candidates, $rel
        if $rel =~ m{\.min\.(?:js|css)$}
        || $rel =~ m{/qrcode\.js$};
};
File::Find::find( { wanted => $wanted, no_chdir => 1 }, "$root/starter" );

cmp_ok( scalar @candidates, '>=', 1, 'found vendored web assets to check' );
for my $c ( sort @candidates ) {
    ok( covered($c), "vendored asset declared in sbom-deps web_assets: $c" );
}

done_testing();
