#!/usr/bin/perl
# SM1446: `install.pl --restore-full` REFUSES A BACKUP THAT DID NOT FINISH, BEFORE IT
# MAKES, LAYS OR EXTRACTS ANYTHING.
#
# A full backup killed mid-tar leaves its claimed name as an empty file; one taken
# before SM885 was written through its own name and can stop part way. Restored, the
# empty one fails late and the cut-off one extracts part of a site. Both are refused,
# saying why and that nothing was changed, with no docroot or cgi-bin made.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $INSTALL = "$FindBin::Bin/../../install.pl";
my $tmp     = dirname( dirname site_tempdir() );
my $GROUP   = getgrgid( $) + 0 ) // ( $) + 0 );

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; binmode $fh; print {$fh} $_[1]; close $fh; return }

my %bad = (
    'an empty claim'                   => '',
    'an archive that stops part way'   => "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03" . ( "\x55" x 64 ),
);
for my $what ( sort keys %bad ) {
    subtest "$what is refused, with nothing changed" => sub {
        ( my $tag = $what ) =~ s/\W+/-/g;
        my $file = "$tmp/lazysite-full-$tag.tar.gz";
        spit( $file, $bad{$what} );
        my $docroot = "$tmp/$tag/public_html";
        my $r = run_child( [ $^X, $INSTALL, '--restore-full', $file, '--docroot', $docroot,
                '--cgibin', "$tmp/$tag/cgi-bin", '--serving-group', $GROUP ], stderr => 'merge' );
        isnt( $r->{status} >> 8, 0, 'refused' ) or diag $r->{out};
        like( $r->{out}, qr/refusing to restore: '[^']*lazysite-full-\Q$tag\E\.tar\.gz' is not a finished backup/,
            'naming the file and why' );
        like( $r->{out}, qr/Nothing was changed/, 'and saying nothing was changed' );
        ok( !-e $docroot && !-e "$tmp/$tag/cgi-bin", 'no docroot and no cgi-bin were made' );
    };
}

done_testing();
