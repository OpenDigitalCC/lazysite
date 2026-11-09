#!/usr/bin/perl
# Ruling 223 (n795, the 0.16.9 restack; as ruling 212 for the Odoo sign-in): AN OIDC
# SIGN-IN START SAYS A BROKEN RATE LIMITER IS A FAULT ON THE HOST, NOT "TOO MANY".
#
# Ruling 213 counts every start against the sign-in limiter per address, and ruling
# 206 (n789, item 4) makes a limiter that cannot count - no DB_File, a counter that
# will not open - refuse. The start answered that refusal as 429 "Too many sign-in
# attempts. Wait a few minutes", which sends the person to wait for a fault that will
# not pass. Now it is cannot-tell (503) in the limiter's own words
# (Lazysite::Auth::LoginRate::fault_refusal), and nothing is written. A limiter that
# counts, over its cap, still answers 429.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use DB_File;
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

use lib repo_root() . '/extensions/oidc/lib';
require Lazysite::Ext::OIDC;

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $d  = site_tempdir();
my $LZ = "$d/lazysite";
make_path("$LZ/auth");
spit( "$LZ/lazysite.conf", "site_name: T\nextensions:\n  - extensions/login-rate-limit.pl\n" );
my $DB = "$LZ/auth/.login-rate.db";
my $IP = '198.51.100.7';

sub start {
    local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    return Lazysite::Ext::OIDC::start( docroot => $d, lz => $LZ, name => 'nosuch', next => '/',
        base => 'https://site.test', secure => 1, ip => $IP );
}

sub pending { opendir my $dh, "$LZ/oidc/pending" or return 0; my $n = grep { /\.json\z/ } readdir $dh; return $n }

subtest 'a limiter that counts, under its cap: the start goes on (to the provider check)' => sub {
    my $r = start();
    unlike( $r->{status} // '', qr/\A429/, 'not refused by the limiter' );
    like( $r->{error} // '', qr/not available/, 'refused only because no such provider is set' );
};

subtest 'a limiter that cannot count: cannot-tell, in the limiter\'s own words' => sub {
    unlink $DB;
    mkdir $DB or die "mkdir $DB: $!";    # a directory where the counter belongs: the tie fails
    my $r = start();
    rmdir $DB;
    is( $r->{ok}, 0, 'refused' );
    like( $r->{status} // '', qr/\A503 /, '503, not 429' );
    is( $r->{kind}, 'cannot-tell', 'kind cannot-tell' );
    unlike( $r->{error} // '', qr/too many/i, 'never "too many sign-in attempts"' );
    like( $r->{error} // '', qr/rate limiter cannot count/, 'the limiter\'s own words' );
    like( $r->{error} // '', qr/fault on the host/, 'a fault on the host' );
    like( $r->{error} // '', qr/lazysite check --docroot <docroot>/, 'naming the check' );
    is( pending(), 0, 'nothing written to the pending store' );
};

subtest 'a limiter that counts, over its cap: still 429' => sub {
    my %db;
    tie %db, 'DB_File', $DB, O_CREAT | O_RDWR, 0o600 or die "tie: $!";
    $db{ "oidc-ip=$IP:" . int( time() / 300 ) } = 99;
    untie %db;
    my $r = start();
    like( $r->{status} // '', qr/\A429 /, 'refused 429' );
    like( $r->{error} // '', qr/Too many sign-in attempts/, 'with the rate sentence' );
};

done_testing();
