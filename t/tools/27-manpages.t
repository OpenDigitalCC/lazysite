#!/usr/bin/perl
# Review D7: the CLI tools carry in-script POD so `perldoc` works and man pages
# can be generated at release. This checks the POD is valid (podchecker clean)
# and that tools/gen-manpages.pl produces a non-empty man page per tool.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @scripts = (
    "$root/tools/lazysite-users.pl",
    "$root/tools/lazysite-check.pl",
    "$root/install.pl",
);

# --- POD is present and valid ----------------------------------------------
for my $s (@scripts) {
    my $out = `podchecker \Q$s\E 2>&1`;
    like( $out, qr/pod syntax OK/, "POD valid: " . ( $s =~ m{([^/]+)$} )[0] );
    my $src = do { open my $fh, '<', $s or die $!; local $/; <$fh> };
    like( $src, qr/^=head1 NAME/m, "has a NAME section: " . ( $s =~ m{([^/]+)$} )[0] );
}

# --- gen-manpages.pl produces non-empty pages ------------------------------
my $out = tempdir( CLEANUP => 1 );
my $gen = "$root/tools/gen-manpages.pl";
my $log = `$^X \Q$gen\E \Q$out\E 2>&1`;
is( $? >> 8, 0, 'gen-manpages.pl exits 0' );

for my $name (qw(lazysite-users lazysite-check install)) {
    my $page = "$out/$name.1";
    ok( -s $page, "man page generated and non-empty: $name.1" );
    my $body = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
    like( $body, qr/\.TH/, "$name.1 is a troff man page (.TH header)" );
}

done_testing();
