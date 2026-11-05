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
#
# Ruling 106: with the old store kept as address-lists.json.converted, the check
# names every rule whose slot is not its old list's kind (only a hand edit made one;
# it refused every visitor before 0.16.5 and now applies in its slot). Ruling 105:
# it names every template call left under the test names from before 0.16.5
# (visitor.in_list and visitor.in_any, SM1345), by file and line, since the engine
# no longer knows them.
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
    spit( "$d/p.md", "---\ntitle: P\n$o{page}\n---\n" . ( $o{body} // 'body' ) . "\n" ) if $o{page};
    spit( "$d/lazysite/auth/address-lists.json.converted", encode_json( $o{converted} ) ) if $o{converted};
    spit( "$d/lazysite/layouts/mine/layout.tt", $o{layout} ) if $o{layout};
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

# old-address-name: begin (SM1343, the fixtures hold the old kinds and the old names)
my $kinds = { office => { kind => 'allow', entries => [] }, blocked => { kind => 'deny', entries => [] } };
my $slots = run( site( page => "addresses_deny: [office]\naddresses: [blocked]", converted => $kinds,
        group => { addresses => ['office'] } ) );
like( $slots, qr/use a profile the other way from its old list's kind: .*office \(an allow list before 0\.16\.5\) is denied by page p\.md/,
    'a rule denying what was an allow list is named, by place' );
like( $slots, qr/blocked \(a deny list before 0\.16\.5\) is allowed by page p\.md/, '...and one allowing a deny list' );
unlike( $slots, qr/office[^;]*is allowed by group operators/, 'a rule in the slot its kind meant is not' );
my $same = run( site( page => "addresses: [office]\naddresses_deny: [blocked]", converted => $kinds ) );
like( $same, qr/every rule names its address profile in the slot its old list's kind meant/, 'all in their old slots: OK' );
unlike( run( site( page => 'addresses_deny: [office]' ) ), qr/old list's kind/, 'no converted file: nothing said' );

my $tpl = run( site( page => 'title2: x', body => "[% IF visitor.in_list('office') %]in[% END %]",
        layout => "x\n[% IF visitor.in_any(['office']) %]y[% END %]\n[% visitor.in_any_profile(['a']) %]\n" ) );
like( $tpl, qr/templates call the address tests by their names from before 0\.16\.5: .*lazysite\/layouts\/mine\/layout\.tt line 2.*p\.md line \d+|templates call the address tests by their names from before 0\.16\.5: .*p\.md line \d+.*lazysite\/layouts\/mine\/layout\.tt line 2/s,
    'an old call in a page and in a layout is named by file and line' );
unlike( $tpl, qr/layout\.tt line 3/, 'a call by the new name is not' );
unlike( run( site( page => 'title2: x', body => "[% visitor.in_profile('office') %]" ) ), qr/names from before 0\.16\.5/,
    'new names only: nothing said' );
# old-address-name: end

done_testing();
