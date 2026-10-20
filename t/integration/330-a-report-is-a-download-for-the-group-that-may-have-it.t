#!/usr/bin/perl
# SM1225: A REPORT IS A DOWNLOAD, and the binding's access rules decide who gets it.
#
# The payslip of L-22 is one person's document. A download binding gated to a group is
# answered with the document to a signed-in member, and to nobody else: a signed-out GET,
# a signed-in account outside the group and a stranger with a forged cookie each get the
# JSON refusal and not a byte of the document. The document is binary (a NUL, high bytes
# and a blank line in it) and comes back whole. Driven in-process as t/integration/170
# does, on OOM's fake Odoo.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Auth::Session ();

my $root = repo_root();
require "$root/lazysite-odoo.pl";

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'payslip', operation => 'shop.document', modes => 'authenticated', callers => 'hr',
    params => 'name=name', answer => 'download', download_max_kb => 8, rate_per_hour => 3, rate_per_visitor_hour => 3 );

make_path("$d/lazysite/auth");
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sf} 'a' x 64;
close $sf;
open my $gf, '>', "$d/lazysite/auth/groups" or die $!;
print {$gf} "hr: harriet\nstaff: sam\n";
close $gf;
open my $uf, '>', "$d/lazysite/auth/users" or die $!;
print {$uf} "harriet:x\nsam:x\n";
close $uf;

sub session_cookie {
    my ($user) = @_;
    require Digest::SHA;
    my $payload = "$user:" . time . ':';
    return 'lazysite_auth=' . $payload . ':' . Digest::SHA::hmac_sha256_hex( $payload, 'a' x 64 );
}

sub hit {
    my (%o) = @_;
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => $o{qs} // '',
            REMOTE_ADDR => '203.0.113.5', ( defined $o{cookie} ? ( HTTP_COOKIE => $o{cookie} ) : () ) );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $body ) = split /\r\n\r\n/, $out, 2;
    my ($st) = $head =~ /Status:\s*(\d+)/;
    return ( $st // 0, $head, $body // '' );
}

my $DOC = "%PDF-1.4\n" . ( 'p' x 83 ) . "\x00\xFF\x80\r\n\r\n\x1a";

subtest 'a member of the group is given the document, whole, with its headers' => sub {
    my ( $st, $h, $body ) = hit( qs => 'binding=payslip&name=Payslip+June.pdf', cookie => session_cookie('harriet') );
    is( $st, 200, 'answered' ) or diag "$h\n$body";
    is( $body, $DOC, 'the bytes, binary and whole' );
    like( $h, qr/^Content-Type: application\/pdf\r?$/m, 'its type' );
    like( $h, qr/^Content-Disposition: attachment; filename="Payslip June\.pdf"\r?$/m, 'saved under its name' );
    like( $h, qr/^Content-Length: \Q${\ length $DOC}\E\r?$/m, 'its length' );
    like( $h, qr/^Cache-Control: private, no-store\r?$/m, 'kept by nothing in between' );
};

subtest 'nobody else is' => sub {
    my $c0 = scalar @{ $fake->calls };
    for my $case ( [ 'signed out', undef ], [ 'signed in, outside the group', session_cookie('sam') ],
        [ 'a forged cookie', 'lazysite_auth=harriet:1:' . ( '0' x 64 ) ] )
    {
        my ( $label, $cookie ) = @$case;
        my ( $st, $h, $body ) = hit( qs => 'binding=payslip', cookie => $cookie );
        is( $st, 403, "$label: 403" );
        like( $h, qr/application\/json/, "$label: a JSON refusal" );
        unlike( $body, qr/%PDF/, "$label: not a byte of the document" );
    }
    is( scalar @{ $fake->calls }, $c0, 'and Odoo was not asked' );
};

subtest 'the rate cap and the size cap are the binding\'s' => sub {
    my $c = session_cookie('harriet');
    my @st = map { ( hit( qs => 'binding=payslip', cookie => $c ) )[0] } 1 .. 3;
    is_deeply( \@st, [ 200, 200, 429 ], 'three an hour: the first subtest\'s was the first, a refusal by mode counted for nothing, the fourth is 429' );
};

done_testing();
