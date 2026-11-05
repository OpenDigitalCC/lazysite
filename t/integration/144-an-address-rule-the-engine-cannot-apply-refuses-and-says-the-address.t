#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-2 and F-3), through the real processor behind a trusted proxy.
#
#   F-2  `addresses: zz60-mine` (a bare value) refused the page to everyone with
#        "You need to sign in to view this page" - to a signed-in member too, which
#        no sign-in can help. The refusal for an address rule the engine cannot
#        read says the address sentence SM1139 ruled, as every other refusal by
#        address does, and still refuses (fail closed).
#   F-3  `addresses_deny: [zz60-mine]`, zz60-mine being an allow list holding the
#        visitor's address, left the page open. SM1189 refused a list of the wrong
#        kind; SM1343 (0.16.5) took the kind away, so the slot is the meaning: a
#        profile denied refuses its addresses and allowed admits them, in either
#        layer (page, folder), and the page never stays open to an address it denies.
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

my $d = site_tempdir();
setup_test_site($d);
spit( "$d/lazysite/lazysite.conf", "site_name: Test\nsite_url: http://localhost\nlayout: test\ntrusted_proxies: 127.0.0.1\n" );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( {
    mine    => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} ) );
spit( "$d/bare.md",     "---\ntitle: Bare\naddresses: mine\n---\nBARE-BODY\n" );
spit( "$d/baredeny.md", "---\ntitle: Bare deny\naddresses_deny: blocked\n---\nBAREDENY-BODY\n" );
spit( "$d/barelist.md", "---\ntitle: Bare groups\nauth_groups: staff\n---\nBAREGROUPS-BODY\n" );
spit( "$d/wrongdeny.md",  "---\ntitle: W1\naddresses_deny: [mine]\n---\nWRONGDENY-BODY\n" );
spit( "$d/wrongallow.md", "---\ntitle: W2\naddresses: [mine, blocked]\n---\nWRONGALLOW-BODY\n" );
spit( "$d/good.md",     "---\ntitle: G\naddresses: [mine]\naddresses_deny: [blocked]\n---\nGOOD-BODY\n" );
spit( "$d/folder/page.md", "---\ntitle: F\n---\nFOLDER-BODY\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { folder => { owner => 'x', addresses_deny => ['mine'] } } ) );

sub hit {
    my ( $uri, $addr ) = @_;
    my $out = run_processor( $d, $uri, REMOTE_ADDR => '127.0.0.1', HTTP_X_FORWARDED_FOR => $addr );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return { status => $st // 200, body => $body // '' };
}
my $IN = '203.0.113.5';

subtest 'F-2: a bare value is refused with the address sentence, not "sign in"' => sub {
    for my $p (qw(/bare /baredeny)) {
        my $r = hit( $p, $IN );
        is( $r->{status}, 403, "$p is refused" );
        like( $r->{body}, qr/\Q$SENTENCE\E/, '  saying the address sentence' );
        unlike( $r->{body}, qr/sign in|Authentication required/i, '  and not sending the reader to sign in' );
        unlike( $r->{body}, qr/(?:BARE|BAREDENY)-BODY/, '  and not the page' );
    }
    my $g = hit( '/barelist', $IN );
    is( $g->{status}, 403, 'control: a bare auth_groups is still refused' );
};

subtest 'F-3: the slot is the meaning, in a page and in a folder rule' => sub {
    for my $p (qw(/wrongdeny /folder/page)) {
        my $r = hit( $p, $IN );
        is( $r->{status}, 403, "$p denies mine, and an address in it is refused" ) or diag $r->{body};
        like( $r->{body}, qr/\Q$SENTENCE\E/, '  with the address sentence' );
        unlike( $r->{body}, qr/(?:WRONGDENY|FOLDER)-BODY/, '  and not the page' );
        is( hit( $p, '198.51.100.5' )->{status}, 200, '  an address outside it is served' );
    }
    is( hit( '/wrongallow', $IN )->{status}, 200, '/wrongallow allows mine and blocked: an address in mine is served' );
    is( hit( '/wrongallow', '198.51.100.5' )->{status}, 403, '...and an address in neither is refused' );
    is( hit( '/good', $IN )->{status}, 200, 'control: mine allowed, blocked denied, an address in mine only serves' );
    is( hit( '/good', '203.0.113.9' )->{status}, 403, '...and the address blocked holds is refused (deny wins)' );
};

done_testing();
