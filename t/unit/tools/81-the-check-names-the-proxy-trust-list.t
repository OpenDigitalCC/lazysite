#!/usr/bin/perl
# SM1129: `lazysite check` warns when auth_proxy_trusted is on, with or without a
# list, and names the list - and says plainly when the list is empty, because
# then proxy sign-in is refused for everyone (the list fails closed).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n$conf";
    close $fh;
    return $d;
}

sub run {
    my ($d) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

my $off = run( site('') );
unlike( $off, qr/auth_proxy_trusted/, 'flag off: nothing said' );

my $listed = run( site("auth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8, 192.0.2.7\n") );
like( $listed, qr/auth_proxy_trusted is on/, 'flag on with a list: warned' );
like( $listed, qr{auth_proxy_trusted_from = 10\.0\.0\.0/8, 192\.0\.2\.7}, 'and the list is named' );
unlike( $listed, qr/lists no usable address/, 'and not called empty' );

my $none = run( site("auth_proxy_trusted: true\n") );
like( $none, qr/lists no usable address \(not set\)/, 'flag on, no list: says nobody is believed' );

my $typo = run( site("auth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8, nope\n") );
like( $typo, qr/not an address or range.*nope/, 'a typo in the list is named' );

done_testing();
