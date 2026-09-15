#!/usr/bin/perl
# SM888 A7 / K3: a submission refused for its TIMING says so; a submission
# refused for a bad token does not.
#
# The field reported "a form posted within a second of page load fails with a
# generic error". SM252's time token was refusing correctly and its reason was
# being discarded one word from being shown: `reject` dies plain, `reject_user`
# dies `USER:...`, and only `USER:` messages reach the submitter. All five
# refusals in check_timestamp used `reject`.
#
# THE DISTINCTION IS NOT COSMETIC, and it is why this is not "make them all
# user-visible":
#
#   TIMING refusals - too fast, expired - happen to REAL PEOPLE holding a valid
#   token this site issued. The HMAC has already matched, so nothing is being
#   probed; the visitor typed too quickly or left the page open. Telling them
#   costs nothing (the three-second floor is in the shipped source) and saves
#   them retyping a form they think ate their answer.
#
#   TOKEN refusals - missing, malformed, wrong HMAC - are the ones an attacker
#   drives. Distinguishing "no token" from "wrong token" from "not a number"
#   tells a forger which half of their attempt was wrong. Those stay generic,
#   and this test holds them generic so that a later reading of "be helpful"
#   cannot quietly widen it.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = site_tempdir();
my $SECRET  = 'b' x 64;

make_path("$docroot/lazysite/forms");
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $hcf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hcf} "handlers:\n  - id: store\n    type: file\n    name: Store\n";
close $hcf;
open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$ff} "rate_limit: 0\ntargets:\n  - handler: store\n";
close $ff;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} $SECRET;
close $fs;

# JSON, so the reason is in the body rather than a redirect query string -
# what is under test is WHICH reason reaches the submitter, not how it travels.
sub submit {
    my (%o)  = @_;
    my $ts   = defined $o{ts} ? $o{ts} : time - 10;
    my $tk   = defined $o{tk} ? $o{tk} : hmac_sha256_hex( $ts, $SECRET );
    my %f    = ( _form => 'contact', name => 'x', _hp => '', _ts => $ts, _tk => $tk );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        HTTP_ACCEPT    => 'application/json',
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null) // '';
}

# THE DURABLE ASSERTION IS THE ABSENCE OF THE GENERIC MESSAGE, and the
# wording check sits second on purpose. Written the other way round, this
# subtest failed on the fix that was already correct: the handler says "too
# quick" and the test looked for "too fast", so a working refusal read as a
# broken one. What the visitor must not get is the catch-all; which words
# replace it is a copy decision that may be revised.
subtest 'posted within the floor: the visitor is told why' => sub {
    my $out = submit( ts => time );    # age 0, under the three-second floor
    like( $out, qr/"ok":0/, 'refused' );
    unlike( $out, qr/An error occurred/i,
        'the submitter does NOT get the catch-all' )
        or diag( "got: $out\n"
            . 'A visitor told only "an error occurred" retypes a form they '
            . 'think ate their answer, and hits the same floor again.' );
    like( $out, qr/too quick/i, 'they are told it was a timing refusal' );
};

subtest 'left open too long: the visitor is told why' => sub {
    my $out = submit( ts => time - 100_000 );    # past the two-hour window
    like( $out, qr/"ok":0/,   'refused' );
    like( $out, qr/expired/i, 'and the reason reaches the submitter' )
        or diag("got: $out");
};

# --- and the ones that must STAY generic ------------------------------------

subtest 'a wrong token says nothing useful' => sub {
    my $out = submit( tk => 'f' x 64 );
    like( $out, qr/"ok":0/, 'refused' );
    unlike( $out, qr/token|hmac|invalid submission/i,
        'the submitter is not told which part of the token failed' )
        or diag( 'Distinguishing "no token" from "wrong token" tells a forger '
            . 'which half of their attempt was wrong.' );
};

subtest 'a missing token says nothing useful' => sub {
    my $out = submit( tk => '' );
    like( $out, qr/"ok":0/, 'refused' );
    unlike( $out, qr/token|hmac|invalid submission/i,
        'still generic' );
};

subtest 'a malformed timestamp says nothing useful' => sub {
    my $out = submit( ts => 'not-a-number' );
    like( $out, qr/"ok":0/, 'refused' );
    unlike( $out, qr/token|hmac|invalid submission/i,
        'still generic - a non-numeric stamp is a forged one, not a slow human' );
};

done_testing();
