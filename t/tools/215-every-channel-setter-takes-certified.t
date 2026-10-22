#!/usr/bin/perl
# SM1260: EVERY PLACE THAT SETS A SITE'S update_channel TAKES `certified`.
#
# ADR 0010 says a site that requires certification sets
# `update_channel: certified`. The manager's config-set refused it (SM1260,
# t/unit/manager/17 holds that side); this holds the others, each by running it:
# install.pl --channel, and the CLI's `channel` verb. Each writes the value
# into lazysite.conf and refuses one that is not a rung.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $ROOT = repo_root();

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\nupdate_channel: stable\n";
    close $fh;
    return $d;
}

sub run {
    my (@cmd) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $c   = join ' ', map {quotemeta} @cmd;
    my $out = `$c 2>&1`;
    return ( $? >> 8, $out );
}

my %setter = (
    'install.pl --channel' => sub { ( $^X, "$ROOT/install.pl", '--channel', $_[1], '--docroot', $_[0] ) },
    'lazysite channel'     => sub { ( $^X, "$ROOT/tools/lazysite-cli.pl", 'channel', $_[1], '--docroot', $_[0] ) },
);

for my $name ( sort keys %setter ) {
    my $d = site();
    my ( $rc, $out ) = run( $setter{$name}->( $d, 'certified' ) );
    is( $rc, 0, "$name certified: accepted" ) or diag $out;
    like( slurp("$d/lazysite/lazysite.conf"), qr/^update_channel: certified$/m, "$name certified: written to the conf" );

    my $e = site();
    ( $rc, $out ) = run( $setter{$name}->( $e, 'gold' ) );
    isnt( $rc, 0, "$name gold: refused" );
    like( slurp("$e/lazysite/lazysite.conf"), qr/^update_channel: stable$/m, "$name gold: the conf is untouched" );
}

done_testing();
