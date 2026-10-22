#!/usr/bin/perl
# WORK-PLAN-0153 Q16b (ruled 2026-10-10, "Keep audit, print nothing"): a
# streamed response is recorded in the audit trail, and nothing is printed after
# its body.
#
# page-pdf's dispatch branch fell through to respond() after streaming, which
# printed a second header block and {"ok":true,"streamed":1} past the PDF's
# Content-Length: a client reading to the end got a PDF with JSON after it. The
# other streaming downloads exited before the audit block instead, so none was
# ever recorded - not a POSTed one, not a refused one - though each is declared
# `audited => 1`, and backup-download's refusal (the action's error hash) was
# dropped, answering nothing at all. All six now return to the dispatcher
# through one streamed path (Manager::Upload::stream_attachment / stream_bytes):
# audited by the trail's rule, nothing after the body.
#
# THE TRAIL'S RULE, UNCHANGED: every POST is recorded, and a GET only when it is
# refused or fails (SM943 ruling 1). A successful GET download writes no row, as
# before; a refused one now does.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir grant_caps run_child);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;
my $d      = site_tempdir( plugins => 1 );
( my $t = $d ) =~ s{/site/public_html\z}{};
make_path( "$d/lazysite/auth", "$d/lazysite/backups", "$d/content", "$t/bin" );
my $audit = "$d/lazysite/logs/audit.log";

open my $sb, '>', "$t/bin/md-to-pdf" or die $!;
print $sb "#!/bin/sh\nprintf '%%PDF-1.4 stand-in' > out.pdf\nexit 0\n";
close $sb;
chmod 0755, "$t/bin/md-to-pdf";

sub w {
    my ( $p, $text ) = @_;
    open my $f, '>:raw', "$d/$p" or die "$p: $!";
    print $f $text;
    close $f;
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}

# One cookie-channel request through the CGI, as `op`. Returns the raw bytes.
sub call {
    my ( $method, $qs, $body ) = @_;
    $body //= $method eq 'POST' ? '{}' : '';
    local %ENV = %ENV;
    $ENV{PATH}                  = "$t/bin:$ENV{PATH}";
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = $method;
    $ENV{CONTENT_LENGTH}        = length $body;
    $ENV{QUERY_STRING}          = $qs;
    $ENV{HTTP_X_REMOTE_USER}    = 'op';
    $ENV{HTTP_X_REMOTE_GROUPS}  = 'role-op';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( 'csrf:op:' . int( time() / 3600 ), $secret );
    $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    my $out = run_child( [ $^X, $mapi ], stdin => $body )->{out};
    return $out // '';
}

sub audit_rows {
    open my $fh, '<', $audit or return ();
    return grep { /\S/ } <$fh>;
}

# The response is ONE header block and exactly Content-Length bytes after it.
sub streamed_ok {
    my ( $label, $out, $want_type, $want_body ) = @_;
    my ( $head, $body ) = split /\r\n\r\n/, $out, 2;
    $body //= '';
    my ($cl) = ( $head // '' ) =~ /^Content-Length:\s*(\d+)\r?$/m;
    like( $head // '', qr/^Status: 200 OK\r?$/m,           "$label: 200" );
    like( $head // '', qr/^Content-Type: \Q$want_type\E/m, "$label: $want_type" );
    ok( defined $cl, "$label: a Content-Length" );
    is( length $body, $cl // -1, "$label: the bytes after the headers are exactly Content-Length" )
        or diag 'tail: ' . substr( $body, $cl // 0, 200 );
    unlike( $body, qr/"streamed"|Status: /, "$label: no JSON and no second header block after the body" );
    is( $body, $want_body, "$label: the body is the file" ) if defined $want_body;
    return;
}

w( 'lazysite/lazysite.conf', "site_name: Downloads\nplugins:\n  - plugins/data.pl\n" );
w( 'lazysite/auth/.secret',  $secret );
w( 'content/page.md',        "---\ntitle: Page\n---\n\nBody\n" );
w( 'content/a.txt',          "alpha bytes\n" );
w( 'lazysite/backups/lazysite-backup-20261010T000000Z.tar.gz',    "backup bytes" );
w( 'lazysite/backups/lazysite-site-test-20261010T000000Z.tar.gz', "package bytes" );
uapi( { action => 'add', username => 'op', password => 'x-long-enough' } );
grant_caps( $d, 'op', qw(ui manage_users manage_content manage_config manage_domains manage_data) );

my @CASES = (
    [ 'page-pdf', 'action=page-pdf&path=content/page.md', 'application/pdf', '%PDF-1.4 stand-in', 'content/page.md' ],
    [ 'file-download', 'action=file-download&path=content/a.txt', 'text/plain', "alpha bytes\n", 'content/a.txt' ],
    [ 'file-zip-download', 'action=file-zip-download&paths=content/a.txt', 'application/zip', undef, undef ],
    [ 'backup-download', 'action=backup-download&name=lazysite-backup-20261010T000000Z.tar.gz', 'application/gzip', 'backup bytes', undef ],
    [ 'site-backup-download', 'action=site-backup-download&name=lazysite-site-test-20261010T000000Z.tar.gz', 'application/gzip', 'package bytes', undef ],
);

subtest 'POST: one response, ending at Content-Length, and the audit row' => sub {
    for my $c (@CASES) {
        my ( $act, $qs, $type, $body, $target ) = @$c;
        my $before = () = audit_rows();
        streamed_ok( "$act POST", call( 'POST', $qs ), $type, $body );
        my @new = ( audit_rows() )[ $before .. 1e6 ];
        @new = grep { defined } @new;
        is( scalar( grep { /\| op \| \Q$act\E \|.*\| ok \| ui/ } @new ), 1, "$act POST: one audit row, ok" )
            or diag explain \@new;
        like( $new[0] // '', qr/\| \Q$target\E \|/, "$act POST: it names the file" ) if defined $target;
    }
};

subtest 'GET: the same bytes; a success writes no row, a refusal does' => sub {
    for my $c ( grep { $_->[0] ne 'page-pdf' } @CASES ) {    # page-pdf is POST-only
        my ( $act, $qs, $type, $body ) = @$c;
        my $before = () = audit_rows();
        streamed_ok( "$act GET", call( 'GET', $qs ), $type, $body );
        my $after = () = audit_rows();
        is( $after, $before, "$act GET: a successful download writes no row (the trail's GET rule)" );
    }
    for my $miss (
        [ 'file-download',     'action=file-download&path=content/none.txt' ],
        [ 'file-zip-download', 'action=file-zip-download&paths=content/none.txt' ],
        [ 'backup-download', 'action=backup-download&name=lazysite-backup-none.tar.gz' ],
        [ 'site-backup-download', 'action=site-backup-download&name=lazysite-site-none.tar.gz' ],
    ) {
        my ( $act, $qs ) = @$miss;
        my $before = () = audit_rows();
        my $out    = call( 'GET', $qs );
        my ( $head, $body ) = split /\r\n\r\n/, $out, 2;
        like( $head // '', qr{^Content-Type: application/json}m, "$act GET refused: a JSON answer" );
        my $j = eval { decode_json( $body // '' ) };
        ok( $j && !$j->{ok} && length( $j->{error} // '' ), "$act GET refused: ok false, saying why" )
            or diag $out;
        my @new = grep { defined } ( audit_rows() )[ $before .. 1e6 ];
        is( scalar( grep { /\| op \| \Q$act\E \|.*\| fail \| ui/ } @new ), 1, "$act GET refused: audited as a failure" )
            or diag explain \@new;
    }
};

SKIP: {
    skip 'DBI / DBD::SQLite / YAML::PP not available', 1
        unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
    subtest 'data-export: the same path for a body in memory' => sub {
        my $save = call( 'POST', 'action=data-table-save',
            encode_json( { table => 'notes', descriptor => "title: Notes\nkey: slug\nfields:\n  slug:\n    type: text\n" } ) );
        like( $save, qr/"ok":true/, 'a table to export' ) or diag $save;
        my $before = () = audit_rows();
        my $out    = call( 'POST', 'action=data-export&table=notes&format=json' );
        streamed_ok( 'data-export POST', $out, 'application/json' );
        my @new = grep { defined } ( audit_rows() )[ $before .. 1e6 ];
        is( scalar( grep { /\| op \| data-export \| notes \|.*\| ok \| ui/ } @new ), 1, 'data-export POST: one audit row naming the table' )
            or diag explain \@new;
    };
}

done_testing();
