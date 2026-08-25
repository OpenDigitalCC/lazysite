#!/usr/bin/perl
# SM539: a repeated field name accumulates in a MULTIPART post as it does in a
# urlencoded one (SM401). The multipart branch of parse_post kept only the last
# value, so a form with an upload and a checkbox group lost every tick but the
# final one - and the stored row depended on whether the form carried a file.
#
# The same submission goes in twice through the real handler as a subprocess:
# once urlencoded, once multipart beside a real file part.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/forms");
my $SECRET = 'b' x 64;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} $SECRET;
close $fs;
open my $hc, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hc} "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
    . "    enabled: true\n    path: $docroot/subs\n";
close $hc;
open my $fc, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$fc} "targets:\n  - handler: jsonl\nupload_max_files: 2\n";
close $fc;

my $ts = time - 10;
my $tk = hmac_sha256_hex( $ts, $SECRET );
my @fields = (
    [ '_form', 'contact' ], [ '_ts', $ts ], [ '_hp', '' ], [ '_tk', $tk ],
    [ 'colour', 'red' ], [ 'name', 'Ada' ], [ 'colour', 'blue' ],
);
my $B  = 'XbndSM539';
my $mp = '';
for my $f (@fields) {
    $mp .= "--$B\r\nContent-Disposition: form-data; name=\"$f->[0]\"\r\n\r\n$f->[1]\r\n";
}
$mp .= "--$B\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"a.txt\"\r\n"
    . "Content-Type: text/plain\r\n\r\nhello\r\n";
$mp .= "--$B--\r\n";
my $ue = join '&', map {"$_->[0]=$_->[1]"} @fields;

my $ip = 0;

sub post {
    my ( $body, $ctype ) = @_;
    my $bf = "$docroot/.body";
    open my $w, '>:raw', $bf or die $!;
    print {$w} $body;
    close $w;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => $ctype,
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.' . ( ++$ip ),
        HTTP_ACCEPT    => 'application/json',
    );
    my $out = qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

like( post( $ue, 'application/x-www-form-urlencoded' ), qr/"ok":1/, 'urlencoded post accepted' );
like( post( $mp, "multipart/form-data; boundary=$B" ), qr/"ok":1/, 'multipart post accepted' );

open my $rf, '<', "$docroot/subs/contact.jsonl" or BAIL_OUT('no records written');
my @rows = map { decode_json($_) } <$rf>;
close $rf;
is( scalar @rows, 2, 'two records stored' );
is( $rows[0]{colour}, 'red; blue', 'urlencoded: the repeated key accumulates (SM401)' );
is( $rows[1]{colour}, 'red; blue', 'multipart: the repeated key accumulates too' );
is( $rows[1]{name},   'Ada',       'a field submitted once is unaffected' );
ok( $rows[1]{_files} && @{ $rows[1]{_files} }, 'and the file part beside it was stored' )
    or diag explain $rows[1];

done_testing();
