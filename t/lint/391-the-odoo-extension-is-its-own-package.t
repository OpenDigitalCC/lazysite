#!/usr/bin/perl
# SM1369 X7 (rulings 188, 202): the Odoo extension ships in its own deb,
# lazysite-odoo, from the same source and the same release, and nowhere else.
#
# Each file is in exactly one package. lazysite-common.install names the
# `extensions` directory whole, so debian/rules removes the Odoo files from it
# after dh_install; lazysite-odoo.install ships them, with the endpoint the
# descriptor declares in owns.endpoints. A file in both is a dpkg conflict on
# every install; a file in neither is an extension that never arrives.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $control = slurp("$root/debian/control");
my ($stanza) = $control =~ /^(Package:\s*lazysite-odoo\n.*?)(?:\n\n|\z)/ms;

subtest 'debian/control declares lazysite-odoo' => sub {
    ok( defined $stanza, 'a lazysite-odoo stanza' ) or return;
    like( $stanza, qr/^Architecture:\s*all$/m, 'Architecture: all' );
    like( $stanza, qr/^Depends:\n(?:\s.*\n)*?\s+lazysite-common \(= \$\{source:Version\}\),/m,
        'Depends on the same-version lazysite-common' );
    like( $stanza, qr/^Recommends:\n\s+libodoo-oom-perl,/m,
        'OOM is a Recommends (ruling 202)' );
    unlike( $stanza, qr/^Depends:\n(?:\s.*\n)*?\s+libodoo-oom-perl/m,
        'and not a Depends: it is not in the Debian archive' );
};

# The descriptor's owns.endpoints, read from its source.
my $descriptor = slurp("$root/extensions/odoo.pl");
my ($endpoints) = $descriptor =~ /endpoints\s*=>\s*\[([^\]]*)\]/;
my @endpoints = ( $endpoints // '' ) =~ /'([^']+)'/g;

subtest 'lazysite-odoo.install ships the descriptor, the payload and the endpoints' => sub {
    my @lines = grep { /\S/ && !/^\s*#/ } split /\n/, slurp("$root/debian/lazysite-odoo.install");
    my %got = map { my ( $s, $d ) = split ' '; ( $s => $d ) } @lines;
    ok( @endpoints, 'the descriptor declares an endpoint' );
    my %want = (
        'extensions/odoo.pl' => 'usr/share/lazysite/extensions',
        'extensions/odoo'    => 'usr/share/lazysite/extensions',
        map { ( $_ => 'usr/share/lazysite' ) } @endpoints,
    );
    is_deeply( \%got, \%want, 'exactly these, at their place in the engine payload' );
};

subtest 'lazysite-common carries none of them' => sub {
    my $common = slurp("$root/debian/lazysite-common.install");
    for my $e (@endpoints) {
        unlike( $common, qr/^\Q$e\E\s/m, "$e is not in lazysite-common.install" );
    }
    my $rules = slurp("$root/debian/rules");
    my ($after) = $rules =~ /^execute_after_dh_install:\n((?:\t.*\n?)*)/m;
    ok( defined $after, 'debian/rules has an execute_after_dh_install' ) or return;
    like( $after, qr{^\trm -rf debian/lazysite-common/usr/share/lazysite/extensions/odoo$}m,
        'which removes the payload directory from lazysite-common' );
    like( $after, qr{^\trm -f debian/lazysite-common/usr/share/lazysite/extensions/odoo\.pl$}m,
        'and the descriptor' );
};

done_testing();
