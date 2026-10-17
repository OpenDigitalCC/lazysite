#!/usr/bin/perl
# SM1141 (slice D of SM1134): `lazysite check` says so when address rules cannot
# work, and is silent about a site that has none.
#   - no rule anywhere: nothing said
#   - a rule (page front matter, acls.json entry, group record, the two
#     lazysite.conf manager keys) and no front end trusted (trusted_proxies none):
#     warned, naming where the rules are
#   - a rule on an install with a front end (a pool conf for this docroot) and
#     trusted_proxies unset: warned that only the private ranges are believed
#   - the same with trusted_proxies naming the front end: no such warning
#   - a rule naming a list the store does not hold: warned, naming list and place
#   - a store that will not decode while rules name lists: warned
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

my $lists = { office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] } };

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n" . ( $o{conf} // '' );
    close $fh;
    if ( !exists $o{store} || defined $o{store} ) {
        open my $s, '>', "$d/lazysite/auth/address-lists.json" or die $!;
        print {$s} ( $o{store} // encode_json($lists) );
        close $s;
    }
    if ( $o{page} ) {
        open my $p, '>', "$d/staff.md" or die $!;
        print {$p} "---\ntitle: Staff\naddresses: [$o{page}]\n---\n\nbody\n";
        close $p;
    }
    if ( $o{acl} ) {
        open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
        print {$a} encode_json( { '/intranet/' => { read => ['@staff'], addresses => [ $o{acl} ] } } );
        close $a;
    }
    if ( $o{group} ) {
        open my $g, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
        print {$g} encode_json( { operators => { addresses_deny => [ $o{group} ] } } );
        close $g;
    }
    return $d;
}

sub run {
    my ( $d, %env ) = @_;
    local %ENV = ( %ENV, %env );
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

my $none = run( site() );
unlike( $none, qr/address rule|address list/i, 'no rule anywhere: nothing said' );

# --- no front end trusted -----------------------------------------------------
my $distrust = run( site( conf => "trusted_proxies: none\n", page => 'office' ) );
like( $distrust, qr/address rules are in use \(page staff\.md\) and trusted_proxies trusts no front end/,
    'a page rule with trusted_proxies none: warned, and the page named' );

my $acl = run( site( conf => "trusted_proxies: none\n", acl => 'office' ) );
like( $acl, qr/in use \(access rule for \/intranet\/\).*trusts no front end/s, 'an acls.json rule counts' );

my $grp = run( site( conf => "trusted_proxies: none\n", group => 'office' ) );
like( $grp, qr/in use \(group operators\).*trusts no front end/s, 'a group record counts' );

my $mgr = run( site( conf => "trusted_proxies: none\nmanager_addresses: office\n" ) );
like( $mgr, qr/in use \(lazysite\.conf key manager_addresses\).*trusts no front end/s, 'the manager conf key counts' );

my $mgrd = run( site( conf => "trusted_proxies: none\nmanager_addresses_deny: office\n" ) );
like( $mgrd, qr/lazysite\.conf key manager_addresses_deny/, 'so does the deny key' );

# --- a front end in front, trusted_proxies unset -------------------------------
my $pools = site_tempdir();
my $fe    = site( page => 'office' );
open my $pc, '>', "$pools/shop.conf" or die $!;
print {$pc} "DOCROOT=$fe\nFRONT_DOOR=1\n";
close $pc;
my $dflt = run( $fe, LAZYSITE_CHECK_POOLS => $pools );
like( $dflt, qr/behind a front end \(pool shop\.conf\) and trusted_proxies is not set.*private ranges/s,
    'a front end and trusted_proxies unset: only the private ranges are believed' );

my $direct = run( site( page => 'office' ), LAZYSITE_CHECK_POOLS => $pools );
unlike( $direct, qr/behind a front end/, 'no front end evidence: the unset default is not called wrong' );

my $named = site( conf => "trusted_proxies: 127.0.0.1\n", page => 'office' );
open $pc, '>', "$pools/shop.conf" or die $!;
print {$pc} "DOCROOT=$named\n";
close $pc;
my $ok = run( $named, LAZYSITE_CHECK_POOLS => $pools );
unlike( $ok, qr/trusts no front end|trusted_proxies is not set/, 'trusted_proxies naming the front end: not warned' );
like( $ok, qr/trusted_proxies names the front end/, '...and said to be fine' );

# --- lists that are not in the store --------------------------------------------
my $miss = run( site( conf => "trusted_proxies: 127.0.0.1\n", page => 'office, blocked' ) );
like( $miss, qr/store does not hold: blocked \(page staff\.md\)/, 'a rule naming a list the store lacks: warned, by name and place' );
unlike( $miss, qr/does not hold: [^\n]*office/, 'a list that exists is not named' );

my $good = run( site( conf => "trusted_proxies: 127.0.0.1\n", page => 'office' ) );
like( $good, qr/every address list a rule names is in the store/, 'all present: said so' );

# --- a store that will not decode -----------------------------------------------
my $bad = run( site( conf => "trusted_proxies: 127.0.0.1\n", page => 'office', store => '{ nope' ) );
like( $bad, qr/address-lists\.json does not decode.*while rules name office/s, 'an undecodable store while rules name lists: warned' );

# An absent store is the same as no lists: every named list is missing.
my $absent = run( site( conf => "trusted_proxies: 127.0.0.1\n", page => 'office', store => undef ) );
like( $absent, qr/store does not hold: office/, 'an absent store: the named list is missing' );

done_testing();
