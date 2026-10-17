#!/usr/bin/perl
# SM1129: the render path's pinned copy of proxy_identity answers exactly as the
# module's does, for every conf and peer.
#
# The processor loads nothing from the Lazysite:: tree (ADR 0001), so it carries
# its own _proxy_identity, as it does for the request address (t/lint/205). The
# manager API and the auth wrapper call the module's. Two readers of one flag that
# could disagree is the hole SM1129 closes, so the answers are compared here over
# a table: flag off / on, list absent / empty / none / typo / listed, peer inside
# / outside / absent / IPv6.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(setup_minimal_site load_processor);
use Lazysite::Util ();

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

my $dir  = "$docroot/lazysite";
my $conf = "$dir/lazysite.conf";

sub set_conf {
    my ($extra) = @_;
    open my $fh, '>', $conf or die "$conf: $!";
    print {$fh} "site_name: T\n$extra";
    close $fh;
    return;
}

my $ON = "auth_proxy_trusted: true\n";

# [ label, conf, peer, expected trusted, expected state ]
my @CASES = (
    [ 'flag off, no list',                  '',                                                   '10.1.2.3', 0, 'off' ],
    [ 'flag off, list present',             "auth_proxy_trusted_from: 10.0.0.0/8\n",              '10.1.2.3', 0, 'off' ],
    [ 'flag false',                         "auth_proxy_trusted: false\nauth_proxy_trusted_from: 10.0.0.0/8\n", '10.1.2.3', 0, 'off' ],
    [ 'flag on, list absent',               $ON,                                                  '10.1.2.3', 0, 'no-list' ],
    [ 'flag on, list empty',                $ON . "auth_proxy_trusted_from:\n",                   '10.1.2.3', 0, 'no-list' ],
    [ 'flag on, list none',                 $ON . "auth_proxy_trusted_from: none\n",              '10.1.2.3', 0, 'no-list' ],
    [ 'flag on, list is a typo',            $ON . "auth_proxy_trusted_from: nope\n",              '10.1.2.3', 0, 'no-list' ],
    [ 'flag on, list is /0',                $ON . "auth_proxy_trusted_from: 0.0.0.0/0\n",         '10.1.2.3', 0, 'no-list' ],
    [ 'flag on, peer inside a CIDR',        $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n",        '10.1.2.3', 1, 'listed' ],
    [ 'flag on, peer outside',              $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n",        '11.1.2.3', 0, 'not-listed' ],
    [ 'flag on, peer a listed host',        $ON . "auth_proxy_trusted_from: 192.0.2.1, 10.0.0.0/8\n", '192.0.2.1', 1, 'listed' ],
    [ 'flag on, no peer (a CLI run)',       $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n",        undef,      0, 'not-listed' ],
    [ 'flag on, v6 inside',                 $ON . "auth_proxy_trusted_from: 2001:db8::/32\n",     '2001:db8::1', 1, 'listed' ],
    [ 'flag on, v6 outside',                $ON . "auth_proxy_trusted_from: 2001:db8::/32\n",     '2001:db9::1', 0, 'not-listed' ],
    [ 'flag on, spelt TRUE',                "auth_proxy_trusted: TRUE\nauth_proxy_trusted_from: 10.0.0.0/8\n", '10.1.2.3', 1, 'listed' ],
    [ 'flag on, the last of two flag lines wins', "auth_proxy_trusted: true\nauth_proxy_trusted: false\nauth_proxy_trusted_from: 10.0.0.0/8\n", '10.1.2.3', 0, 'off' ],
);

for my $c (@CASES) {
    my ( $what, $extra, $peer, $trusted, $state ) = @{$c};
    set_conf($extra);
    local $ENV{REMOTE_ADDR};
    if   ( defined $peer ) { $ENV{REMOTE_ADDR} = $peer }
    else                   { delete $ENV{REMOTE_ADDR} }
    local $ENV{HTTP_X_FORWARDED_FOR} = '10.9.9.9';    # never consulted

    my $m = Lazysite::Util::proxy_identity($dir);
    my $p = main::_proxy_identity();
    is( $m->{trusted} ? 1 : 0, $trusted, "module trusted: $what" );
    is( $m->{state},           $state,   "module state: $what" );
    is( $p->{trusted} ? 1 : 0, $trusted, "processor trusted: $what" );
    is( $p->{state},           $state,   "processor state: $what" );
}

done_testing();
