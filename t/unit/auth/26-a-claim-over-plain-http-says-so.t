#!/usr/bin/perl
# P7 (WORK-PLAN-0154): a setup link refused over plain HTTP says why.
#
# handle_claim refuses to set a password when the peer is not the machine
# itself and HTTPS is not set - correctly - and redirected to
# /claim?u=NAME&error=1, the same answer as a bad or used link. The claim page
# then said "That setup link is invalid or has expired ... ask your site
# operator for a new one", so the person asked for a link that failed the same
# way (reported from a site reached over http on a LAN).
#
# The transport refusal now redirects with error=https and the page says that a
# password can only be set over HTTPS. The refusal is taken before the link or
# the account is looked at, so it answers the same for a real link, a bogus one
# and a name that does not exist: it says nothing about either.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_processor run_child);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $docroot ],
        stdin => encode_json($payload), stderr => 'inherit' )->{out};
    return decode_json($out);
}

sub claim {
    my (%o) = @_;
    my $body = "username=$o{username}&claim=$o{claim}&password=" . ( $o{password} // '' );
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT       => $o{docroot},
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => 'action=claim',
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => $o{addr},
        HTTPS               => $o{https} // '',
        LAZYSITE_USERS_TOOL => $utl,
    );
    my $out = run_child( [ $^X, $auth ], stdin => $body )->{out};
    my ($loc) = ( $out // '' ) =~ /^Location:\s*(\S+)/mi;
    return $loc // '';
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
users_api( $d, { action => 'add', username => 'newbie', password => '' } );
my $c = users_api( $d, { action => 'claim-create', username => 'newbie' } );
ok( $c->{ok} && $c->{claim}, 'a claim was minted' ) or BAIL_OUT('no claim');

subtest 'over plain HTTP from another machine, the refusal names the transport' => sub {
    my %seen;
    for my $case ( [ 'a real link', 'newbie', $c->{claim} ], [ 'a bogus link', 'newbie', 'lzc_bogus' ],
        [ 'no such account', 'nobody', 'lzc_bogus' ] )
    {
        my ( $label, $u, $k ) = @$case;
        my $loc = claim( docroot => $d, username => $u, claim => $k, password => 'pw-chosen-long-enough', addr => '192.0.2.7' );
        like( $loc, qr{\A/claim\?u=\Q$u\E&error=https\z}, "$label: error=https" );
        ( my $shape = $loc ) =~ s/u=[^&]*/u=NAME/;
        $seen{$shape}++;
    }
    is( scalar keys %seen, 1, 'and the same answer for each: it says nothing about the link or the account' );
    ok( !users_api( $d, { action => 'verify-credential', username => 'newbie', secret => 'pw-chosen-long-enough' } )->{ok},
        'nothing was set' );
};

subtest 'over HTTPS a bad link is still the generic answer, and a good one works' => sub {
    my $loc = claim( docroot => $d, username => 'newbie', claim => 'lzc_bogus', password => 'x-long-enough',
        addr => '192.0.2.7', https => 'on' );
    like( $loc, qr{error=1\z}, 'a bogus link: error=1' );
    $loc = claim( docroot => $d, username => 'newbie', claim => $c->{claim}, password => 'pw-chosen-long-enough',
        addr => '192.0.2.7', https => 'on' );
    like( $loc, qr{/login\?claimed=1}, 'the real link, unused by the refusals, still works' );
};

subtest 'the claim page says each' => sub {
    my $site = site_tempdir();
    make_path("$site/lazysite/templates/system");
    open my $sc, '>', "$site/lazysite/lazysite.conf" or die $!;
    print {$sc} "site_name: T\nsite_url: http://localhost\n";
    close $sc;
    open my $in, '<', "$root/starter/lazysite/templates/system/claim.md" or die $!;
    my $page = do { local $/; <$in> };
    close $in;
    open my $out, '>', "$site/claim.md" or die $!;
    print {$out} $page;
    close $out;
    my $https = run_processor( $site, '/claim', QUERY_STRING => 'u=newbie&error=https' ) // '';
    like( $https, qr/can only be set over a secure \(HTTPS\)\s+connection/, 'error=https: the transport' );
    unlike( $https, qr/invalid or has expired/, 'and not the expired link' );
    my $gen = run_processor( $site, '/claim', QUERY_STRING => 'u=newbie&error=1' ) // '';
    like( $gen, qr/invalid or has expired/, 'error=1: the generic answer, as before' );
    unlike( $gen, qr/HTTPS\)\s+connection/, 'without the transport sentence' );
};

done_testing;
