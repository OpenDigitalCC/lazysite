#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-3) had `lazysite check` name every rule naming an address
# list of the wrong kind. SM1343 (0.16.5): a profile has no kind, so there is no
# wrong slot and the check says nothing of the sort, wherever a rule is kept (page
# front matter, an acls.json entry, a group record, the manager's and sign-in's
# lazysite.conf keys) and even where a hand edit left a `kind` on a record.
#
# What it does say (SM1345): a site whose address lists from before 0.16.5 were
# never converted - address-lists.json with no address-profiles.json beside it -
# while rules name profiles. The engine refuses every such rule until the upgrade
# converts the store, and the check names the file and the remedy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

my $profiles = {
    office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },    # a kind left by hand
    blocked => { entries => [ { cidr => '203.0.113.9', note => '' } ] },
};

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" . ( $o{conf} // '' ) );
    my $store = $o{unconverted} ? 'address-lists.json' : 'address-profiles.json';
    spit( "$d/lazysite/auth/$store", encode_json($profiles) );
    spit( "$d/p.md", "---\ntitle: P\n$o{page}\n---\nbody\n" ) if $o{page};
    spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => $o{acl} } ) ) if $o{acl};
    spit( "$d/lazysite/auth/groups-settings.json", encode_json( { operators => $o{group} } ) ) if $o{group};
    return $d;
}

sub run {
    my ($d) = @_;
    my $out = run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'inherit' )->{out};
    return $out // '';
}

for my $c ( [ page => "addresses: [office]\naddresses_deny: [blocked]" ], [ page => 'addresses_deny: [office]' ],
    [ page => 'addresses: [blocked]' ], [ acl => { owner => 'x', addresses_deny => ['office'] } ],
    [ group => { addresses => ['blocked'] } ], [ conf => "manager_addresses_deny: office\n" ],
    [ conf => "signin_addresses: blocked\n" ] )
{
    my $out = run( site(@$c) );
    my $say = ref $c->[1] ? "$c->[0] " . JSON::PP::encode_json( $c->[1] ) : "$c->[0] $c->[1]";
    unlike( $out, qr/wrong kind|of the other kind|is an allow list|is a deny list/i, "$say: no kind is said to be wrong" );
    like( $out, qr/every address profile a rule names is in the store/, '  and the names are found' );
}

my $old = run( site( page => 'addresses_deny: [blocked]', unconverted => 1 ) );
like( $old, qr/address-lists\.json from a release before 0\.16\.5 .* was not converted to address profiles while rules name blocked/,
    'an unconverted store is named, with the rule names' );
like( $old, qr/run the upgrade again: it converts the lists to profiles of the same names \(SM1345\)/, '  and the remedy' );
unlike( $old, qr/the store does not hold/, '  and is not mistaken for missing profiles' );

my $none = run( site( unconverted => 1 ) );
unlike( $none, qr/not converted/, 'with no rule naming a profile, there is nothing to say' );

done_testing();
