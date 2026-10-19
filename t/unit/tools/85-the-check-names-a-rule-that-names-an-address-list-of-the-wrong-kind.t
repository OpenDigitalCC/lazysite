#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-3): `lazysite check` names every existing rule that
# names an address list of the wrong kind - an allow list under a deny slot (which
# blocked nobody, in silence) or a deny list under an allow slot. The engine
# refuses the path such a rule governs; the check says which rule and which list,
# in every place a rule is kept: page front matter, an acls.json entry, a group
# record, the manager's and sign-in's lazysite.conf keys.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

my $lists = {
    office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => '' } ] },
};

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" . ( $o{conf} // '' ) );
    spit( "$d/lazysite/auth/address-lists.json", encode_json($lists) );
    spit( "$d/p.md", "---\ntitle: P\n$o{page}\n---\nbody\n" ) if $o{page};
    spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => $o{acl} } ) ) if $o{acl};
    spit( "$d/lazysite/auth/groups-settings.json", encode_json( { operators => $o{group} } ) ) if $o{group};
    return $d;
}

sub run {
    my ($d) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

my $good = run( site( page => "addresses: [office]\naddresses_deny: [blocked]" ) );
unlike( $good, qr/wrong kind|of the other kind/i, 'right kinds in the right slots: nothing said' );

my $page = run( site( page => 'addresses_deny: [office]' ) );
like( $page, qr/of the wrong kind: office is an allow list named in addresses_deny \(page p\.md\)/, 'a page: the allow list under addresses_deny, by name and place' );

my $page2 = run( site( page => 'addresses: [blocked]' ) );
like( $page2, qr/blocked is a deny list named in addresses \(page p\.md\)/, 'a page: a deny list under addresses' );

my $acl = run( site( acl => { owner => 'x', addresses_deny => ['office'] } ) );
like( $acl, qr/office is an allow list named in addresses_deny \(access rule for \/intranet\/\)/, 'an acls.json rule' );

my $grp = run( site( group => { addresses => ['blocked'] } ) );
like( $grp, qr/blocked is a deny list named in addresses \(group operators\)/, 'a group record' );

for my $c ( [ manager_addresses_deny => 'office' ], [ signin_addresses => 'blocked' ] ) {
    my $out = run( site( conf => "$c->[0]: $c->[1]\n" ) );
    like( $out, qr/named in \Q$c->[0]\E \(lazysite\.conf key \Q$c->[0]\E\)/, "lazysite.conf $c->[0]" );
}

done_testing();
