#!/usr/bin/perl
# SM1139 (slice B of SM1134): A PAGE, A FILE OR A FOLDER IS LIMITED BY THE
# VISITOR'S ADDRESS, through the real processor behind a trusted proxy.
#
# The site trusts 127.0.0.1 as its front end, so the visitor's address is the
# X-Forwarded-For the test sends from that peer. Two lists: `office` (allow,
# 203.0.113.0/24) and `blocked` (deny, 203.0.113.9); `vpn` (allow, 198.51.100.0/24).
#
#   /rota                 front matter addresses: [office]
#   /open                 front matter addresses_deny: [blocked]
#   /both                 front matter addresses: [office], addresses_deny: [blocked]
#   /internal/notes       no front matter; the folder rule (acls.json) allows [office]
#   /internal/doc.txt     a static file under the same folder rule
#   /nested/inner/page    folder `nested` allows [office], folder `nested/inner` allows [vpn]
#   /plain                no rule at all
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_test_site run_processor site_tempdir);

my $SENTENCE = 'This page is not available from your address.';

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    setup_test_site($d);
    spit( "$d/lazysite/lazysite.conf",
        "site_name: Test\nsite_url: http://localhost\nlayout: test\n"
            . ( $o{no_proxy} ? '' : "trusted_proxies: 127.0.0.1\n" ) );
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/auth/address-lists.json", encode_json( {
        office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24',  note => 'HQ' } ] },
        vpn     => { kind => 'allow', entries => [ { cidr => '198.51.100.0/24', note => 'VPN' } ] },
        blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',     note => 'scanner' } ] },
    } ) );
    spit( "$d/rota.md",  "---\ntitle: Rota\naddresses: [office]\n---\nThe rota body.\n" );
    spit( "$d/open.md",  "---\ntitle: Open\naddresses_deny: [blocked]\n---\nThe open body.\n" );
    spit( "$d/both.md",  "---\ntitle: Both\naddresses: [office]\naddresses_deny: [blocked]\n---\nThe both body.\n" );
    spit( "$d/plain.md", "---\ntitle: Plain\n---\nThe plain body.\n" );
    spit( "$d/internal/notes.md",      "---\ntitle: Notes\n---\nThe notes body.\n" );
    spit( "$d/internal/doc.txt",       "the static text\n" );
    spit( "$d/internal/ext.url",       "http://127.0.0.1:1/never\n" );
    spit( "$d/nested/inner/page.md",   "---\ntitle: Inner\n---\nThe inner body.\n" );
    spit( "$d/lazysite/auth/acls.json", encode_json( {
        'internal'     => { owner => 'x', addresses => ['office'] },
        'nested'       => { owner => 'x', addresses => ['office'] },
        'nested/inner' => { owner => 'x', addresses => ['vpn'] },
    } ) );
    $o{after}->($d) if $o{after};
    return $d;
}

# One request from $addr, as the trusted front end forwards it.
sub hit {
    my ( $d, $uri, $addr, %env ) = @_;
    my $out = run_processor( $d, $uri,
        REMOTE_ADDR => '127.0.0.1', HTTP_X_FORWARDED_FOR => $addr, %env );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return { status => $st // 200, head => $head // '', body => $body // '', raw => $out };
}

my $OFFICE  = '203.0.113.5';
my $SCANNER = '203.0.113.9';    # inside office, and on the deny list
my $OUTSIDE = '192.0.2.77';
my $VPN     = '198.51.100.4';

subtest 'an allowed address is served, an unlisted one is refused with the ruled sentence' => sub {
    my $d = site();
    my $ok = hit( $d, '/rota', $OFFICE );
    is( $ok->{status}, 200, 'the office address reads the page' );
    like( $ok->{body}, qr/The rota body/, 'and gets its body' );
    my $no = hit( $d, '/rota', $OUTSIDE );
    is( $no->{status}, 403, 'an unlisted address is refused with a 403' );
    like( $no->{body}, qr/\Q$SENTENCE\E/, 'saying the ruled sentence' );
    unlike( $no->{body}, qr/The rota body/, 'and not the page' );
    unlike( $no->{body}, qr/office/i, 'the refusal does not name the list' );
    like( $no->{head}, qr/Cache-Control:\s*no-store,\s*private/i, 'the refusal is not stored' );
};

subtest 'a deny list refuses its addresses; deny wins over allow' => sub {
    my $d = site();
    is( hit( $d, '/open', $OUTSIDE )->{status}, 200, 'only a deny list: an address not on it is served' );
    my $bad = hit( $d, '/open', $SCANNER );
    is( $bad->{status}, 403, 'an address on the deny list is refused' );
    like( $bad->{body}, qr/\Q$SENTENCE\E/, 'with the same sentence' );
    is( hit( $d, '/both', $OFFICE )->{status},  200, 'allowed and not denied: served' );
    is( hit( $d, '/both', $SCANNER )->{status}, 403, 'in the allow list AND the deny list: refused, deny wins' );
};

subtest 'a folder rule applies to the pages and files inside it' => sub {
    my $d = site();
    is( hit( $d, '/internal/notes', $OFFICE )->{status},  200, 'a page in the folder: the office reads it' );
    is( hit( $d, '/internal/notes', $OUTSIDE )->{status}, 403, 'an outside address is refused' );
    my $st = hit( $d, '/internal/doc.txt', $OUTSIDE );
    is( $st->{status}, 403, 'a static file in the folder is refused too' );
    like( $st->{body}, qr/\Q$SENTENCE\E/, 'with the sentence' );
    my $ok = hit( $d, '/internal/doc.txt', $OFFICE );
    is( $ok->{status}, 200, 'and served to the office' );
    like( $ok->{body}, qr/the static text/, 'with its bytes' );
    like( $ok->{head}, qr/Cache-Control:\s*no-store,\s*private/i, 'a static under the rule is no-store, private' );
    is( hit( $d, '/internal/ext.url', $OUTSIDE )->{status}, 403, 'a .url page in the folder is refused (and never fetched)' );
};

subtest 'layers are ANDed: a page and each enclosing folder must all admit the address' => sub {
    my $d = site();
    is( hit( $d, '/nested/inner/page', $OFFICE )->{status}, 403, 'in the outer folder\'s list but not the inner\'s: refused' );
    is( hit( $d, '/nested/inner/page', $VPN )->{status},    403, 'in the inner folder\'s list but not the outer\'s: refused' );
    $d = site(
        after => sub {
            spit( "$_[0]/lazysite/auth/address-lists.json", encode_json( {
                office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
                vpn    => { kind => 'allow', entries => [ { cidr => '203.0.113.0/25', note => '' } ] },
            } ) );
        } );
    is( hit( $d, '/nested/inner/page', $OFFICE )->{status}, 200, 'in both folders\' lists: served' );
    is( hit( $d, '/nested/inner/page', '203.0.113.200' )->{status}, 403, 'in the outer only: refused' );
};

subtest 'a limited page is not cached, and a refused visitor never gets the first one\'s render' => sub {
    my $d = site();
    my $first = hit( $d, '/rota', $OFFICE );
    is( $first->{status}, 200, 'the office reads it' );
    like( $first->{head}, qr/Cache-Control:\s*no-store,\s*private/i, 'it is sent no-store, private' );
    ok( !-e "$d/rota.html", 'and no render is written next to the page' );
    my $second = hit( $d, '/rota', $OUTSIDE );
    is( $second->{status}, 403, 'a second visitor from a refused address is refused' );
    unlike( $second->{body}, qr/The rota body/, 'and gets none of the first visitor\'s render' );
    is( hit( $d, '/rota', $OFFICE )->{status}, 200, 'and the office is still served afterwards' );
    my $folder = hit( $d, '/internal/notes', $OFFICE );
    like( $folder->{head}, qr/Cache-Control:\s*no-store,\s*private/i, 'a page under a folder rule is no-store, private as well' );
    ok( !-e "$d/internal/notes.html", 'and is not written to the cache' );
};

subtest 'a refusal is audited once per target and address per hour' => sub {
    my $d = site();
    hit( $d, '/rota', $OUTSIDE ) for 1 .. 3;
    my $log = do { local $/; open my $fh, '<', "$d/lazysite/logs/audit.log" or die "audit.log: $!"; <$fh> };
    my @rows = grep { /\| address-refused \| \/rota \|/ } split /\n/, $log;
    is( scalar @rows, 1, 'three refusals from one address for one page: one row' );
    like( $rows[0], qr/\Q$OUTSIDE\E/, 'it names the address' );
    like( $rows[0], qr/not-allowed/,  'and the reason code' );
    like( $rows[0], qr/office/,       'and the list that refused' );
    hit( $d, '/rota', '192.0.2.78' );
    hit( $d, '/both', $SCANNER );
    $log  = do { local $/; open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!; <$fh> };
    @rows = grep { /\| address-refused \|/ } split /\n/, $log;
    is( scalar @rows, 3, 'another address, and another page, each earn their own row' );
};

subtest 'a store that will not read denies every limited page; an unlimited page is unaffected' => sub {
    my $d = site( after => sub { spit( "$_[0]/lazysite/auth/address-lists.json", "{ not json" ) } );
    my $r = hit( $d, '/rota', $OFFICE );
    is( $r->{status}, 403, 'a faulted store refuses even the address that would have been allowed' );
    like( $r->{body}, qr/\Q$SENTENCE\E/, 'with the sentence' );
    is( hit( $d, '/open', $OFFICE )->{status}, 403, 'and a deny-only rule refuses as well (it cannot be proved the address is not on it)' );
    my $p = hit( $d, '/plain', $OUTSIDE );
    is( $p->{status}, 200, 'a page with no rule is served as before' );
    like( $p->{body}, qr/The plain body/, 'with its body' );
};

subtest 'without a trusted proxy the forwarded address is not believed' => sub {
    my $d = site( no_proxy => 1 );
    is( hit( $d, '/rota', $OFFICE )->{status}, 403,
        'X-Forwarded-For from an unlisted peer is ignored: the peer (127.0.0.1) is the address, and it is not in office' );
};

subtest 'an unruled page does not load or consult the lists at all' => sub {
    my $d = site( after => sub { unlink "$_[0]/lazysite/auth/address-lists.json" } );
    my $p = hit( $d, '/plain', $OUTSIDE );
    is( $p->{status}, 200, 'no store, no rule on the page: served' );
    my $r = hit( $d, '/rota', $OFFICE );
    is( $r->{status}, 403, 'a page naming a list that does not exist admits nobody (an allow list with no match)' );
};

done_testing;
