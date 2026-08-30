#!/usr/bin/perl
# SM700: the data endpoint emits UTF-8 bytes, and counts them.
#
# WHAT AN OPERATOR SAW. On familyhq a Swiss holiday rendered as
# "Je<?>ne f<?>d<?>ral" - a replacement character for every accent, while ASCII
# and even the en dash were fine. It had been reported before and was still
# there, because an earlier attempt was aimed at ingest and storage.
#
# THOSE WERE NEVER WRONG. The field agent measured the stored bytes through the
# control API and got C3 BB / C3 A9 - valid UTF-8. Ingest, SQLite and the
# control API were all correct. The two endpoints read the same rows and
# diverged at one step: the control API uses encode_json (UTF-8 by definition)
# with STDOUT in binmode; lazysite-data.pl used JSON::PP->new->...->encode with
# no ->utf8 and no binmode.
#
# THE CHAIN. Connect.pm opens SQLite with sqlite_unicode => 1, so TEXT comes
# back as CHARACTERS. Encoding without ->utf8 keeps it characters. Printing a
# character string to a layer-less STDOUT writes each codepoint as one byte, so
# U+00FB goes out as 0xFB. The header promises charset=utf-8, the browser meets
# a lone high byte, and every accent becomes U+FFFD.
#
# AND THE LENGTH. Content-Length was length() of the character string. It
# happened to be right only BECAUSE of the bug - one byte per character. Fixing
# the encoding alone would have under-reported the length and truncated every
# response carrying an accent, turning a cosmetic fault into a broken one.
use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN { eval { require JSON::PP; 1 } or plan skip_all => 'JSON::PP not available' }

my $script = "$FindBin::Bin/../../../lazysite-data.pl";
plan skip_all => "no $script" unless -f $script;
my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };

# The string from the report, as SQLite hands it over: CHARACTERS, not bytes.
my $accented = "Je\x{00FB}ne f\x{00E9}d\x{00E9}ral";

subtest 'the encoder produces bytes, not codepoints' => sub {
    my $fixed  = JSON::PP->new->utf8->canonical->encode( { s => $accented } );
    my $broken = JSON::PP->new->canonical->encode( { s => $accented } );

    like( $fixed, qr/\xC3\xBB/,
        'the accented character is emitted as its UTF-8 bytes' );
    unlike( $fixed, qr/(?<!\xC3)\xFB/,
        '...and never as a lone high byte' )
        or diag( 'A lone 0xFB is not a valid UTF-8 start. The header says '
            . 'charset=utf-8, so the browser replaces it with U+FFFD - which '
            . 'is the black diamond the operator reported.' );

    # The defect is real, so the fix is not decoration.
    like( $broken, qr/\xFB/,
        'without ->utf8 it really does emit the bare codepoint' );
};

subtest 'Content-Length is the BYTE length' => sub {
    my $fixed = JSON::PP->new->utf8->canonical->encode( { s => $accented } );
    my $chars = JSON::PP->new->canonical->encode( { s => $accented } );
    cmp_ok( length($fixed), '>', length($chars),
        'the encoded body is longer in bytes than in characters' )
        or diag( 'If these are equal the test string has no multi-byte '
            . 'characters and proves nothing.' );

    # The ordering in the source is the thing that matters: the length must be
    # taken from the encoded body, not from whatever was encoded.
    my ($fn) = $src =~ /(sub reply \{.*?\n\})/s;
    ok( $fn, 'reply() was found' ) or return;
    # Comments stripped first. This sub explains itself at length and the
    # explanation names Content-Length, so measuring against the raw text finds
    # the word in the prose rather than in the code - the same trap that had
    # t/lint/96 reading a class name out of a CSS comment.
    ( my $code = $fn ) =~ s/^\s*#.*$//mg;
    my $enc_at = index( $code, 'my $body = JSON::PP' );
    my $len_at = index( $code, 'Content-Length' );
    cmp_ok( $enc_at, '>=', 0, 'the encode was located' );
    cmp_ok( $len_at, '>',  $enc_at,
        'the body is encoded BEFORE its length is measured' )
        or diag( 'length() on the character string counts characters. It was '
            . 'right only because the bug emitted one byte per character, so '
            . 'measuring before encoding would truncate every accented '
            . 'response - a cosmetic fault turned into a broken one.' );
};

subtest 'both directions of the endpoint agree on UTF-8' => sub {
    like( $src, qr/JSON::PP->new->utf8->canonical->encode/,
        'the response is encoded as UTF-8' );
    like( $src, qr/JSON::PP->new->utf8->decode/,
        'and the request body is DECODED as UTF-8' )
        or diag( 'read() gives bytes. Decoding them without ->utf8 treats each '
            . 'byte as a codepoint, so a posted accent arrives as two '
            . 'characters and is stored double-encoded. The read path made the '
            . 'mojibake visible; this one would have written it.' );
    like( $src, qr/binmode STDOUT/,
        'and STDOUT is explicitly bytes' )
        or diag( 'Relying on the absence of an encoding layer works until '
            . 'something adds one.' );
};

subtest 'a round trip through both ends preserves the text' => sub {
    my $wire    = JSON::PP->new->utf8->canonical->encode( { s => $accented } );
    my $back    = JSON::PP->new->utf8->decode($wire);
    is( $back->{s}, $accented,
        'what goes out as bytes comes back as the same characters' )
        or diag( 'This is the property the endpoint has to hold: a client that '
            . 'reads a row and posts it back unchanged must not corrupt it.' );
};

done_testing();
