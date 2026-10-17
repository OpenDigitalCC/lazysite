#!/usr/bin/perl
# SM1137 (left open by SM1130, SM1128 phase 1): THE DATA ENDPOINT AGREES WITH THE
# WRAPPER ABOUT WHO A TRUSTED PROXY SAYS THE VISITOR IS.
#
# lazysite-data.pl verifies a session cookie of its own and treated a request with
# none as anonymous, so on a site behind an identity provider (auth_proxy_trusted)
# a visitor the directory had signed in read a page the proxy's headers opened
# and got "no such table" from the page's own data call - and a visitor holding a
# stale cookie was the cookie's account rather than the directory's. SM1130 made
# the proxy's identity win over the cookie in lazysite-auth.pl only.
#
# The table `members` is private and its read rule names one account (carol) and
# one group (@staff), so who the endpoint believes decides the answer:
#
#   - a trusted proxy user, NO cookie                    is that user
#   - a trusted proxy user AND a cookie for someone else is the proxy's user
#   - the proxy's groups (`Staff|Other`, mapped to `staff`) satisfy @staff
#   - no proxy user, a cookie                            is the cookie's account (unchanged)
#   - a peer outside auth_proxy_trusted_from, or the flag off: the headers are nobody
#   - a proxy user may fetch a CSRF token, and it is theirs
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

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/db/tables", "$d/lazysite/auth" );
    spit( "$d/lazysite/lazysite.conf",
        "site_name: T\nplugins:\n  - plugins/data.pl\n"
            . "auth_header_user: X-Authentik-Username\n"
            . "auth_header_groups: X-Authentik-Groups\n"
            . "auth_header_groups_separator: |\n"
            . ( $o{flag_off} ? '' : "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n" ) );
    spit( "$d/lazysite/db/tables/members.yaml",
        "key: code\nfields:\n  code:\n    type: text\n    required: true\n  name:\n    type: text\n" );
    apply_schema( $d, 'members' );
    insert_row( $d, 'members', { code => 'M1', name => 'Member row' } );
    spit( "$d/lazysite/auth/acls.json",
        encode_json( { 'lazysite/db/tables/members' => { read => [ 'carol', '@staff' ] } } ) );
    spit( "$d/lazysite/auth/.secret", 'a' x 64 );
    chmod 0600, "$d/lazysite/auth/.secret";
    spit( "$d/lazysite/auth/groups", "local: nobody\n" );
    # The cookie path verifies the account against the local store (SM1128 fact 7),
    # so the two who hold a cookie below have one; a proxy user needs none.
    my $users = "$root/tools/lazysite-users.pl";
    qx($^X \Q$users\E --docroot \Q$d\E add $_ pw123456789-long-enough 2>/dev/null) for qw(carol eric);
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
    delete $ENV{$_} for grep { !defined $env{$_} } keys %env;
    my $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my ($st)   = $out =~ /Status:\s*(\d+)/;
    my ($body) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 200, ( eval { decode_json( $body // '' ) } || {} ) );
}

my %CAROL = ( HTTP_X_AUTHENTIK_USERNAME => 'carol', HTTP_X_AUTHENTIK_GROUPS => 'Other' );
my %DAVE  = ( HTTP_X_AUTHENTIK_USERNAME => 'dave',  HTTP_X_AUTHENTIK_GROUPS => 'Staff|Other' );
my %ERIC  = ( HTTP_X_AUTHENTIK_USERNAME => 'eric',  HTTP_X_AUTHENTIK_GROUPS => 'Other' );

subtest 'a trusted proxy user with NO cookie is that user' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %CAROL );
    is( $st, 200, 'carol (named in the read rule) reads the private table' ) or diag( explain $b );
    is( $b->{rows}[0]{name}, 'Member row', 'and gets its rows' );
    ( $st, $b ) = hit( $d, %ERIC );
    is( $st, 404, 'eric (named nowhere) is told there is no such table' );
    ( $st, $b ) = hit( $d, %DAVE );
    is( $st, 200, 'dave reads it through @staff: the proxy\'s `Staff` is the group staff' ) or diag( explain $b );
};

subtest 'the proxy\'s identity wins over a cookie for someone else' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %CAROL, HTTP_COOKIE => cookie_for( $d, 'eric' ) );
    is( $st, 200, 'carol with a cookie for eric (who may not read) is carol' ) or diag( explain $b );
    ( $st, $b ) = hit( $d, %ERIC, HTTP_COOKIE => cookie_for( $d, 'carol' ) );
    is( $st, 404, 'eric with a cookie for carol (who may) is eric: the cookie is not consulted' );
};

subtest 'with no proxy user the session check is unchanged' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, HTTP_COOKIE => cookie_for( $d, 'carol' ) );
    is( $st, 200, 'a cookie for carol reads' ) or diag( explain $b );
    ( $st, $b ) = hit( $d, HTTP_COOKIE => cookie_for( $d, 'eric' ) );
    is( $st, 404, 'a cookie for eric does not' );
    ( $st, $b ) = hit($d);
    is( $st, 404, 'and nobody does not' );
};

subtest 'the headers are nobody unless the proxy is trusted for this request' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %CAROL, REMOTE_ADDR => '10.9.9.9' );
    is( $st, 404, 'a peer outside auth_proxy_trusted_from: carol\'s header is no identity' );
    my $off = site( flag_off => 1 );
    ( $st, $b ) = hit( $off, %CAROL );
    is( $st, 404, 'auth_proxy_trusted off: the same headers are no identity' );
    # The fixed names a client might send are never believed either.
    ( $st, $b ) = hit( $d, HTTP_X_REMOTE_USER => 'carol' );
    is( $st, 404, 'and X-Remote-User from the client is not believed' );
};

subtest 'a proxy user may fetch a CSRF token, and it is theirs' => sub {
    my $d = site();
    my ( $st, $b ) = hit( $d, %CAROL, QUERY_STRING => 'csrf=1', HTTP_COOKIE => cookie_for( $d, 'eric' ) );
    is( $st, 200, 'a token is minted for the proxy user' ) or diag( explain $b );
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";
    ok( Lazysite::Auth::Session::verify_csrf_token( $b->{token}, 'carol' ), 'it verifies for carol' );
    ok( !Lazysite::Auth::Session::verify_csrf_token( $b->{token}, 'eric' ), 'and not for the cookie\'s eric' );
    ( $st, $b ) = hit( $d, QUERY_STRING => 'csrf=1' );
    is( $st, 403, 'with no identity at all there is no token' );
};

# SM1135 (R1) beside it: a write needs manage_data, and a proxy user holds it only
# through a group the operator marked `directory_grants`.
subtest 'a proxy user writes only through a marked group' => sub {
    for my $marked ( 1, 0 ) {
        my $d = site();
        spit( "$d/lazysite/auth/groups-settings.json",
            encode_json( { 'data-staff' => { label => 'x', manage_data => 1, ( $marked ? ( directory_grants => 1 ) : () ) } } ) );
        my %FRANK = ( HTTP_X_AUTHENTIK_USERNAME => 'frank', HTTP_X_AUTHENTIK_GROUPS => 'Data Staff' );
        my ( $ct, $cd ) = hit( $d, %FRANK, QUERY_STRING => 'csrf=1' );
        is( $ct, 200, 'a token is minted' ) or next;
        my $body = encode_json( { row => { code => 'F1', name => 'by frank' } } );
        open my $bf, '>', "$d/.body" or die $!;
        print {$bf} $body;
        close $bf;
        local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'table=members',
            REMOTE_ADDR => '127.0.0.1', CONTENT_LENGTH => length($body), HTTP_X_CSRF_TOKEN => $cd->{token}, %FRANK );
        my $out = qx($^X \Q$root/lazysite-data.pl\E < \Q$d/.body\E 2>/dev/null);
        my ($st) = $out =~ /Status:\s*(\d+)/;
        if ($marked) { is( $st // 200, 200, 'marked: the row is written' ) or diag($out) }
        else          { is( $st, 403, 'unmarked: refused, the group grants no capability' ) or diag($out) }
    }
};

done_testing();
