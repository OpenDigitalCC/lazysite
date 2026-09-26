#!/usr/bin/perl
# SM904: a form value with a non-ASCII character is stored as the visitor typed
# it - not double-encoded.
#
# FROM THE FIELD (2026-09-24): a real lead on a live expo form, name ending
# "Hervé", stored in the table as "HervÃ©" - UTF-8's two bytes C3 A9 read as two
# Latin-1 characters and encoded again. Reproduced on edge two ways (a
# percent-encoded XHR and the browser's own submit), same result, so not the
# client. The API path (data-row-save, a JSON body) round-trips "Ostrów", so
# the data layer is not at fault either.
#
# THE MECHANISM: parse_post decodes %XX to chr(hex) and takes a multipart body
# raw, so every field reaches the handlers as BYTES. Every consumer then treats
# those bytes as characters and encodes them again: insert_row, the `>>:utf8`
# submissions store, the JSON payload handed to the SMTP script, the `:utf8`
# STDOUT that renders the thank-you. One decode at the parse fixes all four.
#
# THIS TEST POSTS TO THE CGI. t/integration/63 drives deliver() with Perl
# strings and could never see this: the defect is upstream of it.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
plan skip_all => "no $handler" unless -f $handler;
my $SECRET = 'c' x 64;

sub site {
    my $docroot = site_tempdir();
    make_path( "$docroot/lazysite/forms", "$docroot/lazysite/auth" );
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
    return $docroot;
}

# POST a body as BYTES, the way a browser sends it.
sub post {
    my ( $docroot, $ctype, $body ) = @_;
    my $bf = "$docroot/.body";
    open my $b, '>:raw', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => $ctype,
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        HTTP_ACCEPT    => 'application/json',
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null) // '';
}

# The last record in the submissions store, decoded as the UTF-8 it is written as.
sub last_record {
    my ($docroot) = @_;
    open my $fh, '<:raw', "$docroot/lazysite/forms/submissions/contact.jsonl" or return undef;
    my @l = <$fh>;
    close $fh;
    return decode_json( $l[-1] );
}

my $ts   = time - 10;
my $tk   = hmac_sha256_hex( $ts, $SECRET );
my $NAME = 'Hervé Ümläut';                                # characters (use utf8)
my $utf8 = do { my $b = $NAME; utf8::encode($b); $b };    # the bytes a browser sends

subtest 'urlencoded: %C3%A9 comes back as one e-acute, not two Latin-1 characters' => sub {
    my $d   = site();
    my $enc = $utf8;
    $enc =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord $1)/ge;
    my $out = post( $d, 'application/x-www-form-urlencoded',
        "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=$enc" );
    like( $out, qr/"ok":\s*1/, 'accepted' ) or diag($out);
    my $rec = last_record($d);
    ok( $rec, 'a record was stored' ) or return;
    is( $rec->{name}, $NAME, 'the name is stored as typed' )
        or diag( 'stored: ' . join( ' ', map { sprintf '%04x', ord } split //, $rec->{name} )
            . "\nThe field measured \"HervÃ©\": the two UTF-8 bytes were taken "
            . 'as two characters and encoded again on the way to the store.' );
};

subtest 'multipart: the raw UTF-8 body of a text part is decoded once too' => sub {
    my $d  = site();
    my $bd = 'xYzBoundary7';
    my $part = sub { my ( $n, $v ) = @_; "--$bd\r\nContent-Disposition: form-data; name=\"$n\"\r\n\r\n$v\r\n" };
    my $body = join( '',
        $part->( '_form', 'contact' ), $part->( '_ts',  $ts ), $part->( '_tk', $tk ),
        $part->( '_hp',   '' ),        $part->( 'name', $utf8 ) )
        . "--$bd--\r\n";
    my $out = post( $d, "multipart/form-data; boundary=$bd", $body );
    like( $out, qr/"ok":\s*1/, 'accepted' ) or diag($out);
    my $rec = last_record($d);
    ok( $rec, 'a record was stored' ) or return;
    is( $rec->{name}, $NAME, 'the name is stored as typed' );
};

subtest 'ASCII is untouched, and a body that is not UTF-8 is not mangled further' => sub {
    my $d   = site();
    my $out = post( $d, 'application/x-www-form-urlencoded',
        "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Plain%20Ada" );
    like( $out, qr/"ok":\s*1/, 'accepted' );
    is( last_record($d)->{name}, 'Plain Ada', 'a plain value is a plain value' );

    # A lone 0xE9 is Latin-1, not UTF-8. It is stored as the character it is in
    # Latin-1 (é) rather than refused or dropped - the visitor typed something,
    # and this is the one reading of it that loses nothing.
    my $d2   = site();
    my $out2 = post( $d2, 'application/x-www-form-urlencoded',
        "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Herv%E9" );
    like( $out2, qr/"ok":\s*1/, 'accepted' );
    is( last_record($d2)->{name}, "Herv\x{e9}", 'read as Latin-1, which is what it was' );
};

done_testing();
