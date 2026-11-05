#!/usr/bin/perl
# SM1138 (slice A of SM1134), SM1343: Lazysite::Auth::AddressProfiles answers "is
# this address in that profile" and "may this address through", for the rules that
# allow or deny a profile on a page, a folder, a group and the manager.
#
# What this holds:
#   - matching: IPv4 and IPv6, single addresses and CIDR ranges, edges of a
#     range, a single address is a /32 or /128, families never cross, and the
#     IPv4-mapped form is an IPv6 address (the matcher is Util's, as for
#     trusted_proxies)
#   - entries: refused unless one address or one CIDR (a prefix of 0, a word
#     list, `none`, an empty string, a too-long prefix)
#   - decide: DENY WINS; a profile allowed and the address in none of them is a
#     deny; only profiles denied and no match is an allow; none named is an allow
#   - SM1343: a profile has no kind, so ONE profile may be allowed by one rule
#     and denied by another (a `kind` a hand edit left is ignored)
#   - an unknown profile name is false and logged once, never a crash
#   - the store FAILS CLOSED (SM1024): unreadable and undecodable both deny
#     wherever a profile is named, allowed or denied, and say which fault; so do
#     address lists from before 0.16.5 left unconverted (SM1345); absent is an
#     answer (no profiles)
#   - client_address reads the visitor's address through trusted_proxies and
#     never believes X-Forwarded-For from an unlisted peer
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Paths ();
use Lazysite::Auth::AddressProfiles ();

my $AL = 'Lazysite::Auth::AddressProfiles';

sub spit { open my $h, '>', $_[0] or die "$_[0]: $!"; print {$h} $_[1]; close $h }

# A site whose auth/ holds the given store text (undef: no store at all).
sub site {
    my ($store) = @_;
    my $d  = site_tempdir();
    my $lz = Lazysite::Paths::lazysite_dir($d);
    make_path("$lz/auth");
    spit( "$lz/auth/address-profiles.json", $store ) if defined $store;
    $Lazysite::Auth::AddressProfiles::AUTH_DIR = "$lz/auth";
    $AL->can('_clear_cache')->();
    return $lz;
}

my $STORE = <<'JSON';
{
  "office":  { "entries": [
      { "cidr": "203.0.113.0/24", "note": "HQ" },
      { "cidr": "198.51.100.7",   "note": "the gateway" },
      { "cidr": "2001:db8:1::/48", "note": "v6 office" } ] },
  "branch":  { "entries": [ { "cidr": "192.0.2.0/25", "note": "branch" } ] },
  "blocked": { "entries": [
      { "cidr": "203.0.113.66", "note": "scanner inside the office range" },
      { "cidr": "2001:db8:1:bad::/64", "note": "v6 abuse" } ] },
  "empty":   { "entries": [] }
}
JSON

subtest 'matching: ranges, single addresses, families' => sub {
    site($STORE);
    ok( $AL->can('in_profile')->( '203.0.113.5',   'office' ), 'inside an IPv4 range' );
    ok( $AL->can('in_profile')->( '203.0.113.0',   'office' ), 'the first address of the range' );
    ok( $AL->can('in_profile')->( '203.0.113.255', 'office' ), 'the last address of the range' );
    ok( !$AL->can('in_profile')->( '203.0.114.0', 'office' ), 'one past the range' );
    ok( !$AL->can('in_profile')->( '203.0.112.255', 'office' ), 'one before the range' );
    ok( $AL->can('in_profile')->( '198.51.100.7', 'office' ), 'a single address is itself' );
    ok( !$AL->can('in_profile')->( '198.51.100.8', 'office' ), 'and not its neighbour' );
    ok( $AL->can('in_profile')->( '192.0.2.127', 'branch' ), 'a /25 holds its top address' );
    ok( !$AL->can('in_profile')->( '192.0.2.128', 'branch' ), 'and not the next one' );
    ok( $AL->can('in_profile')->( '2001:db8:1:ffff::1', 'office' ), 'inside an IPv6 range' );
    ok( !$AL->can('in_profile')->( '2001:db8:2::1', 'office' ), 'outside it' );
    ok( $AL->can('in_profile')->( '2001:0DB8:0001:0000:0000:0000:0000:0001', 'office' ),
        'another spelling of the same IPv6 address' );
    ok( !$AL->can('in_profile')->( '::ffff:203.0.113.5', 'office' ),
        'the IPv4-mapped form is an IPv6 address: in no IPv4 range (as with trusted_proxies)' );
    ok( !$AL->can('in_profile')->( '203.0.113.5', 'blocked' ), 'a different list does not match' );
    ok( !$AL->can('in_profile')->( 'not-an-address', 'office' ), 'a non-address is in nothing' );
    ok( !$AL->can('in_profile')->( '', 'office' ), 'an empty address is in nothing' );
    ok( !$AL->can('in_profile')->( undef, 'office' ), 'an undefined address is in nothing' );
    ok( !$AL->can('in_profile')->( '203.0.113.5; DROP', 'office' ), 'trailing text is not an address' );
    ok( !$AL->can('in_profile')->( '1.2.3.4', 'empty' ), 'an empty list holds nobody' );
};

subtest 'an entry is one address or one CIDR, and nothing else' => sub {
    my %ok = (
        '10.0.0.0/8'     => '10.0.0.0/8',
        '203.0.113.7'    => '203.0.113.7',
        '203.0.113.7/32' => '203.0.113.7',
        '  192.0.2.0/24 ' => '192.0.2.0/24',
        '2001:DB8::/32'  => '2001:db8::/32',
        '::1'            => '::1',
        '::1/128'        => '::1',
        '::ffff:203.0.113.0/120' => '::ffff:203.0.113.0/120',
    );
    for my $in ( sort keys %ok ) {
        my ( $c, $why ) = $AL->can('check_entry')->($in);
        is( $c, $ok{$in}, "'$in' is kept as $ok{$in}" ) or diag $why;
    }
    for my $bad ( '0.0.0.0/0', '::/0', '10.0.0.0/33', '::1/129', 'none', '', ' ', '1.2.3', '10.0.0.0/8 10.1.0.0/16',
        '10.0.0.0/8,10.1.0.0/16', 'example.com', '10.0.0.0/-1', '10.0.0.0/', '*', '1.2.3.4/abc' )
    {
        my ( $c, $why ) = $AL->can('check_entry')->($bad);
        ok( !defined $c && length $why, "'$bad' is refused with a reason" );
    }
    my ( $c, $why ) = $AL->can('check_entry')->(undef);
    ok( !defined $c && length $why, 'undef is refused' );
    ok( $AL->can('valid_name')->('office-2_a'), 'a name of a-z 0-9 _ -' );
    ok( !$AL->can('valid_name')->($_), "'$_' is not a name" )
        for ( 'Office', 'a b', '', 'a' x 65, '../x', 'a.b' );
    ok( $AL->can('valid_name')->( 'a' x 64 ), '64 characters is a name' );
};

subtest 'decide: deny wins, an allow list present means outside it is denied' => sub {
    site($STORE);
    my $d = $AL->can('decide');
    is_deeply( [ $d->('1.2.3.4') ], [ 'allow', 'no-rules' ], 'no list named: allowed' );
    is_deeply( [ $d->( '1.2.3.4', allow => [], deny => [] ) ], [ 'allow', 'no-rules' ], 'empty lists named: allowed' );
    is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'allow', 'allow-profile' ], 'in the allow list' );
    is_deeply( [ $d->( '8.8.8.8', allow => ['office'] ) ], [ 'deny', 'not-allowed' ], 'outside the only allow list' );
    is_deeply( [ $d->( '192.0.2.5', allow => [ 'office', 'branch' ] ) ], [ 'allow', 'allow-profile' ],
        'in the second of two allow lists' );
    is_deeply( [ $d->( '8.8.8.8', allow => [ 'office', 'branch' ] ) ], [ 'deny', 'not-allowed' ], 'in neither' );
    is_deeply( [ $d->( '8.8.8.8', deny => ['blocked'] ) ], [ 'allow', 'not-denied' ], 'only a deny list, no match' );
    is_deeply( [ $d->( '203.0.113.66', deny => ['blocked'] ) ], [ 'deny', 'deny-profile' ], 'in the deny list' );
    is_deeply( [ $d->( '203.0.113.66', allow => ['office'], deny => ['blocked'] ) ], [ 'deny', 'deny-profile' ],
        'DENY WINS: in an allow list and a deny list' );
    is_deeply( [ $d->( '2001:db8:1:bad::5', allow => ['office'], deny => ['blocked'] ) ], [ 'deny', 'deny-profile' ],
        'deny wins in IPv6 too' );
    is_deeply( [ $d->( '203.0.113.67', allow => ['office'], deny => ['blocked'] ) ], [ 'allow', 'allow-profile' ],
        'the neighbour of a denied address is allowed' );
    is_deeply( [ $d->( '1.2.3.4', allow => ['empty'] ) ], [ 'deny', 'not-allowed' ], 'an empty allow list admits nobody' );
    is_deeply( [ $d->( 'garbage', allow => ['office'] ) ], [ 'deny', 'no-address' ], 'no usable address: denied' );
    is_deeply( [ $d->( 'garbage', deny => ['blocked'] ) ], [ 'deny', 'no-address' ],
        'no usable address: denied even against a deny list (cannot tell)' );
    is_deeply( [ $d->( undef, allow => ['office'] ) ], [ 'deny', 'no-address' ], 'undef address: denied' );
    is_deeply( [ $d->('garbage') ], [ 'allow', 'no-rules' ], 'but with nothing named the address is not asked' );
};

subtest 'an unknown name is false and logged once' => sub {
    site($STORE);
    my @log;
    no warnings 'redefine';
    local *Lazysite::Auth::AddressProfiles::log_event = sub { push @log, [@_] };
    ok( !$AL->can('in_profile')->( '203.0.113.5', 'nosuch' ), 'unknown name: false' );
    ok( !$AL->can('in_profile')->( '203.0.113.5', 'nosuch' ), 'and again' );
    is( scalar( grep { ( $_->[3] // '' ) =~ /nosuch/ || ( $_->[2] // '' ) =~ /nosuch/ } @log ), 1, 'logged once' );
    ok( !$AL->can('in_profile')->( '203.0.113.5', undef ), 'undef name: false' );
    my $d = $AL->can('decide');
    is_deeply( [ $d->( '203.0.113.5', allow => ['nosuch'] ) ], [ 'deny', 'not-allowed' ],
        'only an unknown profile allowed: nobody is admitted (not public)' );
    is_deeply( [ $d->( '203.0.113.5', deny => ['nosuch'] ) ], [ 'allow', 'not-denied' ],
        'an unknown profile denied blocks nobody' );
    is_deeply( [ $d->( '203.0.113.5', allow => [ 'nosuch', 'office' ] ) ], [ 'allow', 'allow-profile' ],
        'an unknown name beside a good one does not spoil it' );
};

# SM1343: the request (24 October 2026) - "the selected profiles can be allowed or
# denied". Before it, office could be only an allow list or only a deny list, so
# the second rule here was refused (SM1189 'wrong-kind') and the office range was
# kept twice.
subtest 'one profile is allowed by one rule and denied by another' => sub {
    site($STORE);
    my $d = $AL->can('decide');
    is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'allow', 'allow-profile' ],
        'office allowed: an office address is admitted' );
    is_deeply( [ $d->( '8.8.8.8', allow => ['office'] ) ], [ 'deny', 'not-allowed' ], '...and nobody else' );
    is_deeply( [ $d->( '203.0.113.5', deny => ['office'] ) ], [ 'deny', 'deny-profile' ],
        'office denied: the same office address is refused' );
    is_deeply( [ $d->( '8.8.8.8', deny => ['office'] ) ], [ 'allow', 'not-denied' ], '...and everyone else admitted' );
    is_deeply( [ $d->( '203.0.113.66', allow => ['blocked'] ) ], [ 'allow', 'allow-profile' ],
        'a profile used to deny elsewhere may be allowed' );
    is_deeply( [ $d->( '203.0.113.5', allow => ['office'], deny => ['office'] ) ], [ 'deny', 'deny-profile' ],
        'allowed and denied in one rule: deny wins' );
    site( '{ "office": { "kind": "deny", "entries": [ { "cidr": "203.0.113.0/24", "note": "" } ] } }' );
    is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'allow', 'allow-profile' ],
        'a kind left on a record by a hand edit is ignored' );
};

subtest 'the store fails closed (SM1024)' => sub {
    for my $case ( [ 'truncated', '{ "office": { "entries": [' ],
        [ 'an array', '[1,2]' ], [ 'empty file', '' ], [ 'a bare string', '"x"' ] )
    {
        my ( $label, $text ) = @$case;
        site($text);
        my $d = $AL->can('decide');
        is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'deny', 'store-fault' ], "$label: an allow list denies" );
        is_deeply( [ $d->( '8.8.8.8', deny => ['blocked'] ) ], [ 'deny', 'store-fault' ],
            "$label: a deny list denies too (the contents are unknown, not empty)" );
        is_deeply( [ $d->('8.8.8.8') ], [ 'allow', 'no-rules' ], "$label: with no list named nothing is asked" );
        ok( !$AL->can('in_profile')->( '203.0.113.5', 'office' ), "$label: in_list is false" );
        is( $AL->can('store_fault')->(), 'undecodable', "$label: the fault says undecodable" );
        my $r = eval { $AL->can('write_profiles')->( {} ); 1 };
        ok( !$r && $@ =~ /Refusing to write/, "$label: the writer refuses to write over it" );
    }
    SKIP: {
        skip 'running as root - file modes do not bind', 6 if $> == 0;
        my $lz = site($STORE);
        chmod 0000, "$lz/auth/address-profiles.json";
        $AL->can('_clear_cache')->();
        my $d = $AL->can('decide');
        is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'deny', 'store-fault' ], 'unreadable: an allow list denies' );
        is_deeply( [ $d->( '8.8.8.8', deny => ['blocked'] ) ], [ 'deny', 'store-fault' ], 'unreadable: a deny list denies' );
        is( $AL->can('store_fault')->(), 'unreadable', 'the fault says unreadable' );
        is_deeply( $AL->can('profiles')->(), {}, 'profiles() is empty, and store_fault says why' );
        my $r = eval { $AL->can('write_profiles')->( {} ); 1 };
        ok( !$r && $@ =~ /could not be read/, 'the writer refuses to write over it' );
        chmod 0644, "$lz/auth/address-profiles.json";
        $AL->can('_clear_cache')->();
        is_deeply( [ $d->( '203.0.113.5', allow => ['office'] ) ], [ 'allow', 'allow-profile' ], 'readable again: answers' );
    }
    site(undef);
    my $d = $AL->can('decide');
    is( $AL->can('store_fault')->() || 0, 0, 'an absent store is not a fault' );
    is_deeply( $AL->can('profiles')->(), {}, 'absent: no profiles' );
    is_deeply( [ $d->( '1.2.3.4', allow => ['office'] ) ], [ 'deny', 'not-allowed' ],
        'absent: a rule allowing a profile admits nobody (the name is unknown)' );
    is_deeply( [ $d->('1.2.3.4') ], [ 'allow', 'no-rules' ], 'absent: no rules, allowed' );
};

# SM1345: the store before 0.16.5 was auth/address-lists.json. Left there with no
# profile store beside it, its rules name profiles this module cannot read; an
# absent store would let every rule that denies one block nobody, so it is a fault.
subtest 'address lists left unconverted fail closed (SM1345)' => sub {
    my $lz = site(undef);
    spit( "$lz/auth/address-lists.json", '{ "blocked": { "kind": "deny", "entries": [ { "cidr": "203.0.113.66" } ] } }' );
    $AL->can('_clear_cache')->();
    my $d = $AL->can('decide');
    is_deeply( [ $d->( '203.0.113.66', deny => ['blocked'] ) ], [ 'deny', 'store-fault' ],
        'a rule denying a profile still refuses the address it shut out' );
    is_deeply( [ $d->( '8.8.8.8', deny => ['blocked'] ) ], [ 'deny', 'store-fault' ], '...and every other (unknown)' );
    is_deeply( [ $d->('8.8.8.8') ], [ 'allow', 'no-rules' ], 'nothing named: nothing asked' );
    is( $AL->can('store_fault')->(), 'unconverted', 'the fault says unconverted' );
    like( $AL->can('fault_text')->('unconverted'), qr/run the upgrade again/, 'and the sentence says what to do' );
    my $r = eval { $AL->can('write_profiles')->( { x => { entries => [] } } ); 1 };
    ok( !$r && $@ =~ /not been converted/, 'the writer refuses to start a profile store beside it' );
    ok( !-e "$lz/auth/address-profiles.json", 'and wrote nothing' );
    spit( "$lz/auth/address-profiles.json", '{ "blocked": { "entries": [ { "cidr": "203.0.113.66" } ] } }' );
    $AL->can('_clear_cache')->();
    is_deeply( [ $d->( '8.8.8.8', deny => ['blocked'] ) ], [ 'allow', 'not-denied' ],
        'once the profile store is there, it is the store (the old file is not read)' );
};

subtest 'profiles(): a copy, in a stable shape; a bad entry is reported, not trusted' => sub {
    site( <<'JSON' );
{ "mixed": { "created_by": "sjm", "entries": [
    { "cidr": "10.0.0.0/8", "note": "ok" }, { "cidr": "banana", "note": "typo" }, { "cidr": "0.0.0.0/0" } ] },
  "nokind": { "entries": [ { "cidr": "10.0.0.0/8" } ] },
  "Bad Name": { "entries": [] } }
JSON
    my $l = $AL->can('profiles')->();
    is_deeply( [ sort keys %$l ], [ 'mixed', 'nokind' ], 'a name that is not a name is not a profile' );
    ok( !exists $l->{mixed}{kind}, 'a profile carries no kind' );
    is_deeply( $l->{mixed}{entries}, [ { cidr => '10.0.0.0/8', note => 'ok' } ], 'only the good entry is kept' );
    is_deeply( $l->{mixed}{rejected}, [ 'banana', '0.0.0.0/0' ], 'and the rest are named' );
    is( $l->{mixed}{created_by}, 'sjm', 'created_by comes through' );
    ok( !$AL->can('in_profile')->( '8.8.8.8', 'mixed' ), 'a rejected /0 entry did not become match-everything' );
    ok( $AL->can('in_profile')->( '10.9.9.9', 'mixed' ), 'the good entry matches' );
    is_deeply( [ $AL->can('decide')->( '10.1.1.1', allow => ['nokind'] ) ], [ 'allow', 'allow-profile' ],
        'a record with no kind is a profile like any other' );
    $l->{mixed}{entries}[0]{cidr} = 'changed';
    is( $AL->can('profiles')->()->{mixed}{entries}[0]{cidr}, '10.0.0.0/8', 'a caller cannot change the next caller\'s answer' );
    is_deeply( [ $AL->can('profile_names')->() ], [ 'mixed', 'nokind' ], 'profile_names is sorted' );
};

subtest 'write_profiles and the decode cache' => sub {
    my $lz = site(undef);
    $AL->can('write_profiles')->( { office => { entries => [ { cidr => '10.0.0.0/8', note => '' } ] } } );
    ok( $AL->can('in_profile')->( '10.2.3.4', 'office' ), 'a written profile answers at once' );
    my $mode = ( stat "$lz/auth/address-profiles.json" )[2] & 07777;
    is( sprintf( '%04o', $mode ), '0660', 'the store is 0660, as the other auth stores' );
    $AL->can('write_profiles')->( { office => { entries => [ { cidr => '192.0.2.0/24', note => '' } ] } } );
    ok( !$AL->can('in_profile')->( '10.2.3.4', 'office' ), 'and a rewrite is seen at once (own write clears the memo)' );
    ok( $AL->can('in_profile')->( '192.0.2.9', 'office' ), 'the new entry answers' );
    my $raw = $AL->can('raw_profiles')->();
    is( ref $raw, 'HASH', 'raw_profiles hands the writer the store as it is' );
    ok( !-e "$lz/auth/address-profiles.json.tmp.$$", 'no temp file is left behind' );
};

subtest 'the store is decoded once per change, not once per question' => sub {
    my $lz   = site($STORE);
    my $path = "$lz/auth/address-profiles.json";
    my $old  = time() - 60;
    utime $old, $old, $path;    # older than the one-second guard, so it may be memoised
    my $decodes = 0;
    no warnings 'redefine';
    my $real = \&JSON::PP::decode_json;
    local *JSON::PP::decode_json = sub { $decodes++; goto &$real };
    $AL->can('in_profile')->( '203.0.113.5', 'office' ) for 1 .. 5;
    $AL->can('decide')->( '203.0.113.5', allow => ['office'], deny => ['blocked'] ) for 1 .. 5;
    is( $decodes, 1, 'ten questions, one decode' );
    spit( $path, '{ "office": { "entries": [ { "cidr": "192.0.2.0/24", "note": "" } ] } }' );
    utime $old, $old, $path;
    ok( !$AL->can('in_profile')->( '203.0.113.5', 'office' ), 'a changed file (new size) is read afresh' );
    is( $decodes, 2, '...with one more decode' );
    my $fresh = site($STORE);    # a file younger than a second is never memoised
    $decodes = 0;
    $AL->can('in_profile')->( '203.0.113.5', 'office' ) for 1 .. 3;
    is( $decodes, 3, 'a file written this second is read every time (a same-second rewrite shares the key)' );
};

subtest 'client_address reads the visitor through trusted_proxies' => sub {
    my $lz = site($STORE);
    local %ENV = %ENV;
    delete $ENV{HTTP_X_FORWARDED_FOR};
    $ENV{REMOTE_ADDR} = '203.0.113.5';
    spit( "$lz/lazysite.conf", "trusted_proxies: 10.0.0.0/8\n" );
    is( $AL->can('client_address')->(), '203.0.113.5', 'no forwarded header: the peer, verbatim' );
    $ENV{HTTP_X_FORWARDED_FOR} = '8.8.8.8';
    is( $AL->can('client_address')->(), '203.0.113.5',
        'a peer that is not a listed proxy cannot name the visitor with X-Forwarded-For' );
    $ENV{REMOTE_ADDR} = '10.1.1.1';
    is( $AL->can('client_address')->(), '8.8.8.8', 'a listed proxy: the address it forwards' );
    $ENV{HTTP_X_FORWARDED_FOR} = '203.0.113.5, 198.51.100.200';
    is( $AL->can('client_address')->(), '198.51.100.200',
        'the rightmost hop, so a caller-supplied value ahead of the true one is not believed' );
    my ( $v, $why ) = $AL->can('decide')->( $AL->can('client_address')->(), allow => ['office'] );
    is( $v, 'deny', 'and the decision is made on that address' );
    spit( "$lz/lazysite.conf", "trusted_proxies: none\n" );
    is( $AL->can('client_address')->(), '10.1.1.1', 'trusted_proxies: none - the peer' );
};

done_testing;
