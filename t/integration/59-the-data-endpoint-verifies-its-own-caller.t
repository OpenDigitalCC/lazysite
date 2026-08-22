#!/usr/bin/perl
# DP-3: the data endpoint, and the identity it must not take on trust.
#
# THE DEFECT THIS IS BUILT TO AVOID, named in SM410's audit before a line of it
# existed: the front door routes lazysite-*.pl, but only the processor and
# manager-api are WRAPPED. A direct-CGI plugin therefore sees X-Remote-User
# exactly as the client sent it - so an endpoint that trusted the header would
# be SM402's defect reintroduced BY SPECIFICATION. That is why SM411 extracted
# the session verifier, and why this endpoint validates its own cookie.
#
# The test that matters is the second one: a request that CLAIMS to be an
# authorised user, with no cookie, must be treated as anonymous.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough);
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/products.yaml" or die $!;
print {$df} "key: code\nfields:\n  code:\n    type: text\n    required: true\n"
    . "  name:\n    type: text\n";
close $df;
apply_schema( $docroot, 'products' );
insert_row( $docroot, 'products', { code => 'W1', name => 'Widget' } );

sub hit {
    my (%env) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $docroot,
        REQUEST_METHOD => 'GET', QUERY_STRING => '', %env );
    my $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    my ($body)   = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 0, ( eval { decode_json( $body // '' ) } || {} ), $out );
}

subtest 'an anonymous visitor reads an ungated table' => sub {
    my ( $st, $d ) = hit( QUERY_STRING => 'table=products' );
    is( $st, 200, 'it answers' );
    ok( $d->{ok}, 'with rows' ) or diag( $d->{error} // '' );
    is( $d->{rows}[0]{name}, 'Widget', 'the row is there' );
};

subtest 'A CLAIMED IDENTITY IS NOT AN IDENTITY' => sub {
    # The header anybody can set. If this endpoint believed it, every ACL on
    # every table would be one request header away from irrelevant.
    my ( $st, $d, $raw ) = hit(
        QUERY_STRING       => 'table=products',
        HTTP_X_REMOTE_USER => 'alice',
    );
    is( $st, 200, 'the request is answered' );

    # The proof is not in the reply - an ungated table answers either way -
    # so it is asserted where the decision is made: the endpoint must clear
    # what arrived and set only what it verified.
    my $src = do {
        open my $fh, '<', "$root/lazysite-data.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/delete \$ENV\{\$_\} for grep \{ \/\\AHTTP_X_REMOTE_\/ \}/,
        'the endpoint CLEARS any identity the client sent' )
        or diag( 'The front door routes this script but does not wrap it, so '
            . 'X-Remote-User arrives exactly as the client wrote it.' );
    like( $src, qr/verify_session_cookie/,
        'and verifies a session cookie of its own' );
    my ($set) = $src =~ /(\$ENV\{HTTP_X_REMOTE_USER\} = [^\n]*)/;
    like( $set, qr/\$user/,
        'setting the identity from the VERIFIED user, not the request' );
};

subtest 'a disabled account is anonymous, not its former self' => sub {
    my $src = do {
        open my $fh, '<', "$root/lazysite-data.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/account_disabled/, 'a disabled account is checked' );
    like( $src, qr/session_revoked/,  'and a revoked session' )
        or diag( 'A cookie outlives both, so a verified signature is not on '
            . 'its own an answer to "may this person read".' );
};

subtest 'it reads, and refuses to be a write surface' => sub {
    my ( $st, $d ) = hit( REQUEST_METHOD => 'POST',
        QUERY_STRING => 'table=products' );
    is( $st, 405, 'POST is refused' )
        or diag( 'A read endpoint that accepts POST invites a write to be '
            . 'added later without the CSRF question being asked.' );
};

subtest 'a missing table and a forbidden one answer the same way' => sub {
    my ( $st, $d ) = hit( QUERY_STRING => 'table=nosuchtable' );
    is( $st, 404, 'an unknown table is 404' );
    like( $d->{error}, qr/no such table, or not available to you/,
        'and the wording does not distinguish the two' )
        or diag( 'Distinguishing them tells an anonymous caller which tables '
            . 'exist, which is the disclosure the gate exists to prevent.' );
};

subtest 'a disabled plugin refuses here too' => sub {
    open my $off, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$off} "site_name: T\n";
    close $off;
    my ( $st, $d ) = hit( QUERY_STRING => 'table=products' );
    is( $st, 403, 'the endpoint refuses while the plugin is off' )
        or diag( 'ADR 0009: every dispatch path consults the enabled state, '
            . 'and a direct-CGI plugin refuses its own requests.' );
    like( $d->{error}, qr/disabled/, 'saying so' );
    open my $on, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$on} "site_name: T\nplugins:\n  - plugins/data.pl\n";
    close $on;
};

subtest 'nothing in front may cache the answer' => sub {
    my ( $st, $d, $raw ) = hit( QUERY_STRING => 'table=products' );
    like( $raw, qr/Cache-Control: no-store/,
        'the response says no-store' )
        or diag( 'What a visitor may see depends on who they are, so a shared '
            . 'cache holding one answer would hand it to the next person.' );
};

done_testing();
