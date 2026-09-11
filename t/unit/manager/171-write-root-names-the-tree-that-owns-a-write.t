#!/usr/bin/perl
# SM836: Lazysite::Private::write_root answers "which tree owns this write" the
# way resolve_for_write decides it - including the two cases where the obvious
# answer is wrong.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Private qw(write_root private_root private_path);

my $d = site_tempdir();    # lint 118: not a bare tempdir
make_path( "$d/open", "$d/lazysite-assets/lay/theme" );

sub spit { my ($p) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $f, '>', $p or die "$p: $!"; print {$f} "x\n"; close $f }

# A gated folder: it exists only in the store, because protecting it moved it.
spit( private_path( $d, 'members/secret.md' ) );
# A PUBLIC folder that happens to hold one private file - the trap SM286 met.
spit( "$d/open/public.md" );
spit( private_path( $d, 'open/one-private.md' ) );
# A theme mirror file with a private copy - SM438's trap.
spit( private_path( $d, 'lazysite-assets/lay/theme/main.css' ) );

my $priv = private_root($d);

is( write_root( $d, '' ),                     $d,    'the docroot itself is owned by the docroot' );
is( write_root( $d, 'open/new.md' ),          $d,    'a new file in a public folder is written publicly' );
is( write_root( $d, 'members/new.md' ),       $priv, 'a new file in a GATED folder is written to the store' );
is( write_root( $d, 'members' ),              $priv, '...and so is the gated folder itself, which upload targets' );
is( write_root( $d, 'open/another.md' ),      $d,
    'one private file does not make its public folder private (SM286)' );
is( write_root( $d, 'lazysite-assets/lay/theme/main.css' ), $d,
    'a theme mirror is engine-owned and always public, private copy or not (SM438)' );

done_testing();
