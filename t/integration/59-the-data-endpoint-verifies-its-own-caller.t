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
# `public: true` because THIS file is about identity, not publication (SM476).
# Leaving it unpublished would make every assertion here pass or fail for the
# publication rule instead of the one being tested - which is how a test starts
# measuring something other than its own subject.
print {$df} "public: true\nkey: code\nfields:\n  code:\n    type: text\n"
    . "    required: true\n  name:\n    type: text\n";
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
    # THIS USED TO GREP THE SOURCE for `account_disabled` and `session_revoked`,
    # and it passed for a reason that had nothing to do with the behaviour:
    # the endpoint carried a redundant re-check whose only effect was to put
    # those two words in the file. Removing the redundancy - the verifier
    # already decides both, and the re-check called session_revoked() with no
    # arguments - turned this red while the behaviour was unchanged and
    # correct.
    #
    # A test that asserts a STRING IS PRESENT cannot tell a working check from
    # a dead one. So it now disables an account and asks the endpoint.
    my $secret = "$docroot/lazysite/auth/.secret";
    unless ( -f $secret ) {
        open my $sf, '>', $secret or die $!;
        print {$sf} 'a' x 64;
        close $sf;
    }
    my $users = "$root/tools/lazysite-users.pl";
    qx($^X \Q$users\E --docroot \Q$docroot\E add lapsed pw123456789 2>/dev/null);

    require Lazysite::Auth::Session;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$docroot/lazysite";
    require Digest::SHA;
    my $sec = Lazysite::Auth::Session::_auth_secret_read();
    my $mint = sub {
        my $pay = "$_[0]:" . time . ':';
        return 'lazysite_auth=' . $pay . ':'
            . Digest::SHA::hmac_sha256_hex( $pay, $sec );
    };

    my ( $st, $d ) = hit( QUERY_STRING => 'csrf=1',
        HTTP_COOKIE => $mint->('lapsed') );
    is( $st, 200, 'while enabled, the account is signed in' )
        or diag( 'If this fails the fixture never signed in, so the '
            . 'disable below would prove nothing.' );

    qx($^X \Q$users\E --docroot \Q$docroot\E account-disable lapsed 2>/dev/null);

    my ( $st2, $d2 ) = hit( QUERY_STRING => 'csrf=1',
        HTTP_COOKIE => $mint->('lapsed') );
    is( $st2, 403, 'the SAME cookie is refused once the account is disabled' )
        or diag( 'A cookie outlives the account. A verified signature is not '
            . 'on its own an answer to "may this person read".' );
    ok( !$d2->{token}, 'and no token is minted for it' );
};

subtest 'POST is a write surface, and anonymous is not welcome on it' => sub {
    # This asserted 405 while the read half was all there was. The write half
    # makes POST meaningful, so the assertion that matters changes with it:
    # what must stay true is that an anonymous POST WRITES NOTHING - which is
    # a stronger statement than "the method is refused".
    my ( $st, $d ) = hit( REQUEST_METHOD => 'POST',
        QUERY_STRING => 'table=products' );
    is( $st, 403, 'an anonymous POST is refused' );
    is( $d->{kind}, 'anonymous', 'as anonymous, not as a bad request' )
        or diag( 'The kind is what a page uses to decide whether to say '
            . '"sign in" or "something went wrong".' );

    my $rows = Lazysite::Data::Tables::read_rows( $docroot, 'products', as => 'operator' );
    is( scalar @{ $rows->{rows} }, 1, 'and the table is untouched' );
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
