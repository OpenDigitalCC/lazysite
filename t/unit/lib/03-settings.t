#!/usr/bin/perl
# SM079 step 2b: Lazysite::Auth::Settings - settings store + consume lock,
# unit-tested in-process.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Settings qw(read_settings write_settings _consume_lock);

my $d = tempdir( CLEANUP => 1 );
$Lazysite::Auth::Settings::AUTH_DIR = $d;

is_deeply( read_settings(), {}, 'empty hash when no file exists' );

write_settings( { alice => { webdav => 1 }, bob => { ui => 0 } } );
is_deeply( read_settings(), { alice => { webdav => 1 }, bob => { ui => 0 } },
    'write then read round-trips' );

my $lk = _consume_lock();
ok( $lk, 'consume lock returns a handle' );
ok( -f "$d/.consume.lock", 'lock file created under AUTH_DIR' );
undef $lk;

open my $fh, '>', "$d/user-settings.json" or die $!;
print {$fh} "this is not json";
close $fh;
is_deeply( read_settings(), {}, 'unparseable file yields empty defaults' );

done_testing();
