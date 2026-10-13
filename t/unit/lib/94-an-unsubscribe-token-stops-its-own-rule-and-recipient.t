#!/usr/bin/perl
# SM1073 (SM1010 R4): AN UNSUBSCRIBE TOKEN STOPS ITS OWN RULE AND RECIPIENT, AND
# NOTHING ELSE.
#
# The one-click link acts without a sign-in, so the token is all of its
# authority. Lazysite::Unsubscribe makes it from the rule id, the recipient's
# 24-hex hash and an HMAC under the site's own key; here, what that has to hold:
# the same pair always gives the same token; changing the rule, the recipient
# or any character of the MAC gives one that does not verify; another site's
# key verifies nothing; a site that has made no key verifies nothing and the
# endpoint's side never makes one; recording is idempotent; and a suppression
# store that exists and will not open reads as "cannot tell", never as empty.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper            qw(site_tempdir);
use Lazysite::Unsubscribe ();

my $P  = 'a' x 24;
my $P2 = 'b' x 24;

my $d = site_tempdir();
make_path("$d/lazysite");

subtest 'no key, no verification - and the endpoint\'s side never makes one' => sub {
    my ( $k, $why ) = Lazysite::Unsubscribe::key($d);
    ok( !defined $k, 'no key yet' );
    like( $why, qr/no link has been sent/, 'and says why' );
    ok( !-e Lazysite::Unsubscribe::key_file($d), 'reading made none' );
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, "v1.rule.$P." . ( '0' x 32 ) ) ), 0,
        'a well-formed token verifies against nothing' );
};

my ($t) = Lazysite::Unsubscribe::token( $d, 'followers', $P );

subtest 'the token is made once and is stable' => sub {
    like( $t, qr/\Av1\.followers\.$P\.[0-9a-f]{32}\z/, 'v1.<rule>.<recipient hash>.<mac>' );
    ok( -f Lazysite::Unsubscribe::key_file($d), 'the key was made by the sending side' );
    is( ( stat Lazysite::Unsubscribe::key_file($d) )[2] & 07777, 0660, 'readable by the two identities, no one else' );
    my ($again) = Lazysite::Unsubscribe::token( $d, 'followers', $P );
    is( $again, $t, 'the same rule and recipient give the same token' );
    unlike( $t, qr/\@/, 'it names no address' );
};

subtest 'it verifies as its own rule and recipient, and nothing else does' => sub {
    is_deeply( [ Lazysite::Unsubscribe::verify( $d, $t ) ], [ 'followers', $P ], 'its own pair' );
    ( my $other_rule = $t ) =~ s/\.followers\./.newsletter./;
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, $other_rule ) ), 0, 'another rule, same MAC: refused' );
    ( my $other_p = $t ) =~ s/\.$P\./.$P2./;
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, $other_p ) ), 0, 'another recipient, same MAC: refused' );
    for my $i ( 0 .. 31 ) {
        my $bad = $t;
        my $pos = length($t) - 32 + $i;
        substr( $bad, $pos, 1 ) = substr( $bad, $pos, 1 ) eq '0' ? '1' : '0';
        if ( Lazysite::Unsubscribe::verify( $d, $bad ) ) { fail("one changed MAC character ($i) verified"); return }
    }
    pass('every one-character change of the MAC is refused');
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, uc $t ) ), 0, 'a changed case is refused' );
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, "$t " ) ), 0, 'trailing text is refused' );
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, undef ) ),  0, 'nothing is refused' );

    my $d2 = site_tempdir();
    make_path("$d2/lazysite");
    my ($t2) = Lazysite::Unsubscribe::token( $d2, 'followers', $P );
    isnt( $t2, $t, 'another site makes another token for the same pair' );
    is( scalar( () = Lazysite::Unsubscribe::verify( $d, $t2 ) ), 0, 'and it does not verify here' );
};

subtest 'recording is idempotent and per pair' => sub {
    is_deeply( Lazysite::Unsubscribe::suppressed($d), {}, 'nothing stopped yet' );
    is( ( Lazysite::Unsubscribe::record( $d, 'followers', $P ) )[0], 'added',   'the first stop is added' );
    is( ( Lazysite::Unsubscribe::record( $d, 'followers', $P ) )[0], 'already', 'the second says already' );
    my $s = Lazysite::Unsubscribe::suppressed($d);
    is_deeply( [ sort keys %$s ], ["followers\0$P"], 'one pair, recorded once' );
    open my $fh, '<', Lazysite::Unsubscribe::store_file($d) or die $!;
    my @l = <$fh>;
    close $fh;
    is( scalar(@l), 1, 'one line in the store' );
    unlike( $l[0], qr/\@/, 'and no address in it' );
    ok( !( Lazysite::Unsubscribe::record( $d, '../x', $P ) )[0], 'a rule that is not an id is refused' );
};

subtest 'a store that will not open is not an empty one' => sub {
    plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;
    my $f = Lazysite::Unsubscribe::store_file($d);
    chmod 0000, $f;
    ok( !defined Lazysite::Unsubscribe::suppressed($d), 'undef: cannot tell' );
    chmod 0644, $f;
};

done_testing();
