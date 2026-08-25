#!/usr/bin/perl
# Review D7: the CLI tools carry in-script POD so `perldoc` works and man pages
# can be generated at release. This checks the POD is valid (podchecker clean)
# and that tools/gen-manpages.pl produces a non-empty man page per tool.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
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

# --- SM561: the "produced no pages" refusal can fire ------------------------
# release.sh appended the trailing --prefix to MAN_ADD BEFORE testing it for
# emptiness, so the array always held one element and a generator that
# produced nothing sailed through to the tarball. The block is lifted from
# release.sh rather than re-typed, and run against an empty directory.
subtest 'release.sh refuses a man directory with no pages' => sub {
    my $release = "$root/tools/release.sh";
    my $src     = do { open my $fh, '<', $release or die $!; local $/; <$fh> };
    my ($block) = $src =~ /^(MAN_ADD=\(\)\n.*?produced no pages.*?\nfi\n(?:MAN_ADD\+=[^\n]*\n)?)/ms;
    ok( defined $block, 'the MAN_ADD block was lifted from release.sh' ) or return;

    my $run = sub {
        my ($pages) = @_;
        my $d = tempdir( CLEANUP => 1 );
        make_path("$d/man/man1");
        for my $n ( 1 .. $pages ) {
            open my $m, '>', "$d/man/man1/tool$n.1" or die $!;
            print {$m} ".TH TOOL$n 1\n";
            close $m;
        }
        open my $r, '>', "$d/run.sh" or die $!;
        print {$r} "STAGE=\"$d\"\nVERSION=9.9.9\nset -e\n"
            . "stage_disposition() { :; }\n"    # SM560's abort helper; inert here
            . $block
            . "echo \"REACHED: \${#MAN_ADD[@]} element(s)\"\n";
        close $r;
        my $out = qx(bash "$d/run.sh" 2>&1);
        return ( $? >> 8, $out );
    };

    my ( $rc, $out ) = $run->(0);
    is( $rc, 1, 'an empty man directory is refused (exit 1)' )
        or diag("output:\n$out");
    like( $out, qr/produced no pages/, 'and the refusal names the cause' );

    ( $rc, $out ) = $run->(1);
    is( $rc, 0, 'one page present: the gate passes' ) or diag("output:\n$out");
    like( $out, qr/REACHED: 3 element\(s\)/,
        'with the interleaved --prefix pair plus the trailing prefix the tarball relies on' );
};

done_testing();
