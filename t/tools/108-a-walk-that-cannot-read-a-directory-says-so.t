#!/usr/bin/perl
# Q16g: `lazysite check` run as a user that cannot read part of the site.
#
# On the 0.15.4 rollout the check ran as a user that could not read the private
# store, and three of its walks printed File::Find's raw warning -
#   Can't opendir(<docroot>-lazysite-private/sites): Permission denied
# - then reported their results as if the walk were complete. Every walk in the
# tool now turns an unreadable directory into a WARN naming the directory, the
# check that could not cover it, and how to run the check so it can.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

plan skip_all => 'root reads every directory, so nothing is unreadable' if $> == 0;

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
ok( -f $script, 'the check tool is present' ) or BAIL_OUT('no check tool');

my $doc  = site_tempdir();
my $cgi  = "$doc/../cgi-bin";
my $priv = "$doc-lazysite-private";
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", $cgi, "$doc/docs/locked", "$priv/sites/a" );
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
for my $p ( "$doc/docs/locked/page.md", "$priv/sites/a/page.md" ) {
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} "---\ntitle: x\n---\n\nx\n";
    close $fh;
}
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];

chmod 0000, "$doc/docs/locked", "$priv/sites" or die "chmod: $!";
my $out = run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname );
chmod 0755, "$doc/docs/locked", "$priv/sites";    # so the tempdir can be removed

unlike( $out, qr/Can't opendir/, 'no raw File::Find warning is printed' ) or diag($out);
like( $out, qr/^\[ warn \] the form-pattern check could not read 2 directories as \S+: /m,
    'the form-pattern check names what it could not read, and as whom' )
    or diag($out);
like( $out, qr/^\[ warn \] [^\n]*\Q$priv\E\/sites \(Permission denied\)/m,
    'the private store\'s directory is named, with the reason' );
like( $out, qr/^\[ warn \] [^\n]*\Q$doc\E\/docs\/locked \(Permission denied\)/m,
    'and so is one inside the docroot' );
like( $out, qr/^\[ warn \] the db: template check could not read/m, 'each walk says so for itself' );
like( $out, qr/nothing below them was looked at/, 'the finding says what it means for the result' );
like( $out, qr/-> run the check as root \(sudo lazysite check \.\.\.\) or as the user that owns the site/,
    'and how to run the check so it can' );

# Every walk goes through the one helper: the tool calls File::Find::find once,
# inside find_noting, so a walk added later cannot print the raw warning again.
my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };
( my $code = $src ) =~ s/^\s*#.*$//mg;
my @direct = $code =~ /File::Find::find\(/g;
is( scalar @direct, 1, 'File::Find::find is called in one place' );
like( $code, qr/sub find_noting \{.*?File::Find::find\( \$opts, \@roots \);/s, '...the helper' );

# With nothing unreadable there is no such finding.
my $clean = run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname );
unlike( $clean, qr/could not read \d+ director/, 'a readable site has no such finding' );

done_testing();
