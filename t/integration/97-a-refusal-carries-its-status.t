#!/usr/bin/perl
# SM854: the refusals an agent meets most carry their status.
#
# SM670 gave the control API real HTTP statuses, derived from each refusal's
# `kind` - and a refusal with no kind answers 400 by rule. The 1313E pass found
# the two an agent meets most often had no kind at all: asking for an action the
# account lacks the capability for, and mistyping an action name. Both answered
# 400 - a permission problem and a spelling problem reported identically, and
# neither as what it was. The mapping was right; these refusals were not using it.
#
# Driven through the real CGI over token auth, asserting the STATUS LINE, because
# that is the thing the filing is about and no unit test of the map can see it.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough setup_dav_site grant_caps);

my $root = repo_root();

# A REAL store, a SECURED site, and the channel switched on. Without all three
# the control API refuses every token client before it reaches the gates this
# test is about - with a bootstrap message, or "the control API is not enabled",
# and the test would pass or fail for the wrong reason.
my $site    = setup_dav_site( user => 'tester', password => 'secret' );
my $docroot = $site->{docroot};
make_path("$docroot/lazysite/auth");
grant_caps( $docroot, 'boss', qw(ui manage_users) );
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "control_api_enabled: true\n";
close $cf;

# A grant with the api channel and manage_content, and nothing else: enough to
# call the API, not enough for the actions asked for below.
sub stub {
    my (%settings) = @_;
    my $path = "$docroot/users-stub-" . join( '-', map { "$_$settings{$_}" } sort keys %settings ) . '.pl';
    open my $sf, '>', $path or die $!;
    # It READS STDIN first: the credential check pipes the request in, and a tool
    # that never reads it does not answer - which reads as "Authentication
    # required" and sends you looking for the wrong thing.
    print {$sf} "#!/usr/bin/perl\nuse strict; use warnings;\n"
        . "use JSON::PP qw(encode_json decode_json);\n"
        . "my \$in = do { local \$/; <STDIN> };\n"
        . "print encode_json({ ok => 1, settings => { "
        . join( ', ', map { "$_ => $settings{$_}" } sort keys %settings ) . " } });\n";
    close $sf;
    chmod 0755, $path;
    return $path;
}

sub api {
    my ( $stub, $query, %opt ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        LAZYSITE_USERS_TOOL => $stub,
        # BASIC, not Bearer: the control API's token front path is
        # `Authorization: Basic base64(user:lzs_...)`. Bearer is MCP's, and a
        # Bearer header here authenticates nothing - every call answers
        # "Authentication required", which looks like a broken fixture.
        HTTP_AUTHORIZATION => 'Basic ' . MIME::Base64::encode_base64( 'tester:lzs_x', '' ),
        # One place, or a later key silently wins: a mutating action sent as GET
        # meets the "must be sent as POST" gate and never reaches the question.
        REQUEST_METHOD => ( $opt{post} ? 'POST' : 'GET' ),
        ( $opt{post} ? ( CONTENT_LENGTH => 0 ) : () ),
        QUERY_STRING => $query,
    );
    my $out      = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    my ($status) = $out =~ /^Status:\s*(\d+)/m;
    ( my $json = $out ) =~ s/\A.*?\r?\n\r?\n//s;
    return ( $status // 200, eval { decode_json($json) } || {} );
}

my $agent  = stub( api => 1, manage_content => 1 );
my $capped = stub( api => 1 );                        # the channel, no capabilities
my $nochan = stub( manage_content => 1 );             # capabilities, no channel

subtest 'an unknown action is not found, not a bad request' => sub {
    my ( $status, $body ) = api( $agent, 'action=nosuchthing' );
    is( $status, 404, 'a name the server does not recognise answers 404' )
        or diag( 'A spelling mistake answered 400 with no kind, exactly as a '
            . 'permission problem did. The two point opposite ways: fix your '
            . 'request, versus ask for a grant.' );
    is( $body->{ok},   0,           'and still refuses in the body' );
    is( $body->{kind}, 'not-found', 'with the kind that says which it is' );
    like( $body->{error}, qr/check the spelling/, 'the wording is unchanged' );
};

subtest 'a capability refusal is forbidden' => sub {
    my ( $status, $body ) = api( $capped, 'action=data-tables' );
    is( $status,       403,          'an action the account may not call answers 403' );
    is( $body->{kind}, 'permission', 'with kind permission' );
    like( $body->{error}, qr/Insufficient capability/, 'the wording is unchanged' );
};

subtest 'the channel gate and a cookie-only action are forbidden too' => sub {
    my ( $s1, $b1 ) = api( $nochan, 'action=data-tables' );
    is( $s1,         403,          'a token without the api capability answers 403' );
    is( $b1->{kind}, 'permission', 'kind permission' );

    # POST, because it mutates: sent as GET it meets the "must be sent as POST"
    # gate first, and that refusal is a different question.
    my ( $s2, $b2 ) = api( $agent, 'action=form-submission-delete', post => 1 );
    is( $s2,         403,         'an action served only to the manager UI answers 403' );
    is( $b2->{kind}, 'forbidden', 'kind forbidden' );
    like( $b2->{error}, qr/only to the manager UI/, 'and says so' );
};

subtest 'the controls: what must NOT move' => sub {
    my ( $ok_status, $ok_body ) = api( $agent, 'action=whoami' );
    is( $ok_status, 200, 'a call that succeeds still answers 200' );
    ok( $ok_body->{ok}, 'and says ok' );

    # A validation refusal has no kind ON PURPOSE: 400 is what it is.
    my ( $bad_status, $bad_body ) = api( $agent, 'action=acl-set' );
    is( $bad_status,     400, 'a malformed request is still 400' );
    is( $bad_body->{ok}, 0,   'and refuses' );
};

done_testing();
