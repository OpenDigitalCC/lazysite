#!/usr/bin/perl
# SM1188 (found by SM1181 S1): THE DATA ENDPOINT KEEPS A PROXY USER'S GROUPS UNDER
# THE DEFAULT HEADER NAMES.
#
# lazysite-data.pl deleted every HTTP_X_REMOTE_* and only then read the groups
# through the identity reader. A proxy that uses the DEFAULT names (X-Remote-User,
# X-Remote-Groups) had its groups deleted before the read, so a table restricted
# to a group refused the proxy user (fail closed). t/integration/272 renames the
# headers, which is why nothing saw it.
#
#   - trusted peer, default names, user in @staff     reads the row
#   - trusted peer, default names, user not in @staff refused
#   - the same headers from an untrusted peer         stripped, anonymous, refused
#   - a cookie user                                   unchanged
#   - a write through a marked directory group        works under default names
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough site_tempdir);
use Lazysite::Data::Tables  qw(apply_schema insert_row);
use Lazysite::Auth::Session ();

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

# No auth_header_* keys: the DEFAULT names are in force.
sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/db/tables", "$d/lazysite/auth" );
    spit( "$d/lazysite/lazysite.conf",
        "site_name: T\nplugins:\n  - plugins/data.pl\n"
            . "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n" );
    spit( "$d/lazysite/db/tables/members.yaml",
        "key: code\nfields:\n  code:\n    type: text\n    required: true\n  name:\n    type: text\n" );
    apply_schema( $d, 'members' );
    insert_row( $d, 'members', { code => 'M1', name => 'Member row' } );
    spit( "$d/lazysite/auth/acls.json",
        encode_json( { 'lazysite/db/tables/members' => { read => ['@staff'] } } ) );
    spit( "$d/lazysite/auth/.secret", 'a' x 64 );
    chmod 0600, "$d/lazysite/auth/.secret";
    spit( "$d/lazysite/auth/groups", "local: nobody\n" );
    my $users = "$root/tools/lazysite-users.pl";
    qx($^X \Q$users\E --docroot \Q$d\E add carol pw123456789-long-enough 2>/dev/null);
    spit( "$d/lazysite/auth/groups", "staff: carol\n" );
    return $d;
}

sub cookie_for {
    my ( $d, $user ) = @_;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";
    require Digest::SHA;
    my $pay = "$user:" . time . ':';
    return 'lazysite_auth=' . $pay . ':' . Digest::SHA::hmac_sha256_hex( $pay, Lazysite::Auth::Session::_auth_secret_read() );
}

sub hit {
    my ( $d, %env ) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
        QUERY_STRING => 'table=members', REMOTE_ADDR => '127.0.0.1', %env );
    my $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my ($st)   = $out =~ /Status:\s*(\d+)/;
    my ($body) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 200, ( eval { decode_json( $body // '' ) } || {} ) );
}

my %DAVE = ( HTTP_X_REMOTE_USER => 'dave', HTTP_X_REMOTE_GROUPS => 'Staff,Other' );
my %ERIC = ( HTTP_X_REMOTE_USER => 'eric', HTTP_X_REMOTE_GROUPS => 'Other' );

subtest 'a trusted proxy user\'s groups reach the table check under the default names' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %DAVE );
    is( $st, 200, 'dave, in @staff by the proxy\'s X-Remote-Groups, reads the table' ) or diag( explain $b );
    is( $b->{rows}[0]{name}, 'Member row', 'and gets its rows' );
    ( $st, $b ) = hit( $d, %ERIC );
    is( $st, 404, 'eric, in no listed group, is refused' );
};

subtest 'the same headers from an untrusted peer are stripped' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %DAVE, REMOTE_ADDR => '10.9.9.9' );
    is( $st, 404, 'dave\'s headers from a peer outside auth_proxy_trusted_from are nobody' );
    ( $st, $b ) = hit( $d, HTTP_X_REMOTE_GROUPS => 'staff', REMOTE_ADDR => '10.9.9.9' );
    is( $st, 404, 'a groups header alone from an untrusted peer grants nothing' );
    ( $st, $b ) = hit( $d, HTTP_X_REMOTE_GROUPS => 'staff' );
    is( $st, 404, 'and from the trusted peer with no user it is still nobody' );
};

subtest 'a cookie user is unchanged' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, HTTP_COOKIE => cookie_for( $d, 'carol' ) );
    is( $st, 200, 'a cookie for carol (staff in the local store) reads' ) or diag( explain $b );
    ( $st, $b ) = hit( $d, HTTP_COOKIE => cookie_for( $d, 'carol' ), HTTP_X_REMOTE_GROUPS => 'staff', REMOTE_ADDR => '10.9.9.9' );
    is( $st, 200, 'an untrusted peer\'s forged group header neither adds nor removes anything' );
};

subtest 'a write through a marked directory group works under the default names' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/groups-settings.json",
        encode_json( { 'data-staff' => { label => 'x', manage_data => 1, directory_grants => 1 } } ) );
    my %FRANK = ( HTTP_X_REMOTE_USER => 'frank', HTTP_X_REMOTE_GROUPS => 'Data Staff' );
    my ( $ct, $cd ) = hit( $d, %FRANK, QUERY_STRING => 'csrf=1' );
    is( $ct, 200, 'a token is minted' ) or return;
    my $body = encode_json( { row => { code => 'F1', name => 'by frank' } } );
    open my $bf, '>', "$d/.body" or die $!;
    print {$bf} $body;
    close $bf;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'table=members',
        REMOTE_ADDR => '127.0.0.1', CONTENT_LENGTH => length($body), HTTP_X_CSRF_TOKEN => $cd->{token}, %FRANK );
    my $out = qx($^X \Q$root/lazysite-data.pl\E < \Q$d/.body\E 2>/dev/null);
    my ($st) = $out =~ /Status:\s*(\d+)/;
    is( $st // 200, 200, 'the row is written: the marked group\'s capability reached the write gate' ) or diag($out);
};

done_testing();
