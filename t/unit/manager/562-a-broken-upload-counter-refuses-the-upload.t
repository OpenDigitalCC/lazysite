#!/usr/bin/perl
# Ruling 206 (item 9 of the 0.16.9 fault survey): A BROKEN UPLOAD COUNTER
# REFUSES THE UPLOAD.
#
# check_upload_rate answered { ok => 1 } - the hourly budget off - when its
# counter lazysite/manager/.upload-rate.db would not open. Now that is the
# cannot-tell refusal (503) naming the store and `lazysite check`, and the
# damaged file is left as it was found. An absent counter is a fresh site and
# still allows (it is made on first use); a budget of 0 on both axes is the
# operator switching it off and still allows.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Upload qw(check_upload_rate);
use Lazysite::Manager::Common ();

eval { require DB_File };
plan skip_all => 'DB_File not available' if $@;

my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/manager", "$docroot/lazysite/logs" );
$Lazysite::Manager::Upload::LAZYSITE_DIR = "$docroot/lazysite";
$Lazysite::Manager::Common::DOCROOT      = $docroot;
my $db = "$docroot/lazysite/manager/.upload-rate.db";

sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub conf {
    spit( "$docroot/lazysite/lazysite.conf", $_[0] );
    Lazysite::Manager::Common::_reset_upload_limits_cache();
}

conf("manager_upload_rate_count: 5\nmanager_upload_rate_mb: 100\n");

subtest 'an absent counter allows, and is made' => sub {
    unlink $db;
    my $r = check_upload_rate( 'alice', 1024 );
    is( $r->{ok}, 1, 'the first upload of a fresh site is allowed' );
    ok( -e $db, 'and the counter now exists' );
};

subtest 'a counter that does not open refuses as cannot-tell, and is left alone' => sub {
    my $junk = "this is not a Berkeley DB hash file\n" x 64;
    spit( $db, $junk );
    my ( $r, $err ) = ( undef, '' );
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $r = check_upload_rate( 'alice', 1024 );
        close STDERR;
    }
    is( $r->{ok},   0,             'the upload is refused' );
    is( $r->{kind}, 'cannot-tell', 'as cannot-tell (503), not as a rate decision' );
    is( $r->{store}, 'lazysite/manager/.upload-rate.db', 'naming the store' );
    like( $r->{error}, qr/lazysite\/manager\/\.upload-rate\.db/, 'the sentence names the store' );
    like( $r->{error}, qr/`lazysite check --docroot <docroot>` names the fault/, 'and the check' );
    unlike( $r->{error}, qr{/tmp|\Q$docroot\E}, 'and no host path' );
    is( slurp($db), $junk, 'the damaged counter is byte-identical' );
    like( $err, qr/cannot tell - lazysite\/manager\/\.upload-rate\.db/,
        'the log names the fault' );
};

subtest 'a budget switched off still allows, broken counter or not' => sub {
    conf("manager_upload_rate_count: 0\nmanager_upload_rate_mb: 0\n");
    my $r = check_upload_rate( 'alice', 1024 );
    is( $r->{ok}, 1, 'the operator turned the budget off: allowed' );
};

done_testing();
