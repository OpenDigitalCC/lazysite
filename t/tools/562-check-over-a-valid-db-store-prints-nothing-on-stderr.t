#!/usr/bin/perl
# n800: LAZYSITE CHECK PRINTS WHAT IT MEANS, AND NOTHING ELSE.
#
# The 0.16.9 repair on edge printed "untie attempted while 1 inner references
# still exist" twice, over stores that were perfectly sound: the check kept the
# object tie returns while it untied. A run over valid DB_File stores (the
# upload-rate counter and the login-rate counter) leaves STDERR empty, and says
# both are fine. And a message quotes its apostrophe plainly: no backtick
# stands in for one.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Fcntl;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

BEGIN {
    eval { require DB_File; 1 } or plan skip_all => 'DB_File is not installed on this host';
}

my $root  = repo_root();
my $check = "$root/tools/lazysite-check.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
make_path( map { "$d/lazysite/$_" } qw(auth manager notify forms logs connectors daemon notify-templates db) );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nextensions:\n  - extensions/login-rate-limit.pl\n" );

# Two sound DB_File stores, each holding a record.
for my $f ( "$d/lazysite/manager/.upload-rate.db", "$d/lazysite/auth/.login-rate.db" ) {
    my %h;
    tie %h, 'DB_File', $f, O_CREAT | O_RDWR, 0660 or die "tie $f: $!";
    $h{'127.0.0.1'} = '1:1';
    untie %h;
    chmod 0666, $f;    # the CGI may open it whatever group this test runs in
}

my $r = run_child( [ $^X, $check, '--docroot', $d ], stderr => 'pipe' );
my $out = $r->{out} // '';

unlike( $out, qr/does not open as a DB_File database/, 'neither store is called damaged' ) or diag $out;
like( $out, qr/\] the login rate limiter is in force/, 'the login rate counter is checked and usable' ) or diag $out;
is( $r->{err}, '', 'and nothing at all is printed on STDERR' ) or diag $r->{err};

done_testing();
