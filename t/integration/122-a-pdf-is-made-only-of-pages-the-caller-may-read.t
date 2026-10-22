#!/usr/bin/perl
# SM978 (ruled 2026-10-10, "Scope it + composed parts"): page-pdf makes a PDF
# only of pages the caller may read - the caller's scope and the content ACL,
# asked of the page and of every part a composed document pulls in.
#
# page-pdf was declared `mutates` with no `scoped`, so _confine_scope never saw
# its path: a cookie manager confined to content/clientA got content/clientB's
# page as a PDF where `read` of the same path answered "outside your assigned
# scope" (tmp/sm944-s29-scope-probe.out). A composed document's parts were asked
# the content ACL alone, and the page itself not even that: any manage_content
# account got a page whose read rule named someone else (tmp/q16b-acl-probe.out).
#
# A PART OUTSIDE THE SCOPE REFUSES THE DOCUMENT, naming the part - fail closed,
# as the page's own refusal does, and as the plugin already refuses a part the
# ACL denies ("refused rather than built without that part"). Excluding it would
# hand back a document that looks complete and is not.
#
# The test 31 fixture: client is confined to content/clientA (the domain
# clienta.com allows its group); content/clientB is another domain's. md-to-pdf
# is a stand-in on PATH that records each run. No network.
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
make_path( "$d/lazysite/auth", "$d/content/clientA", "$d/content/clientB", "$t/bin" );

open my $sb, '>', "$t/bin/md-to-pdf" or die $!;
print $sb "#!/bin/sh\necho \"\$@\" >> '$t/ran'\nprintf '%%PDF-1.4 stand-in' > out.pdf\nexit 0\n";
close $sb;
chmod 0755, "$t/bin/md-to-pdf";

sub w {
    my ( $p, $text ) = @_;
    open my $f, '>', "$d/$p" or die "$p: $!";
    print $f $text;
    close $f;
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}

# One cookie-channel POST through the CGI. Returns (status, headers, body).
sub post {
    my ( $user, $qs, $body ) = @_;
    $body //= '{}';
    local %ENV = %ENV;
    $ENV{PATH}                  = "$t/bin:$ENV{PATH}";
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = 'POST';
    $ENV{CONTENT_LENGTH}        = length $body;
    $ENV{QUERY_STRING}          = $qs;
    $ENV{HTTP_X_REMOTE_USER}    = $user;
    $ENV{HTTP_X_REMOTE_GROUPS}  = "role-$user";
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:$user:" . int( time() / 3600 ), $secret );
    $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    my $out = run_child( [ $^X, $mapi ], stdin => $body )->{out};
    my ( $head, $rest ) = split /\r?\n\r?\n/, $out, 2;
    my ($status) = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    return ( $status // 200, $head // '', $rest // '' );
}

sub pdf {
    my ( $user, $path ) = @_;
    unlink "$t/ran";
    my ( $st, $head, $body ) = post( $user, "action=page-pdf&path=$path" );
    my $json = $head =~ m{^Content-Type: application/json}m ? eval { decode_json($body) } : undef;
    return { status => $st, pdf => ( $head =~ m{^Content-Type: application/pdf}m ? 1 : 0 ),
        ran => ( -f "$t/ran" ? 1 : 0 ), json => $json };
}

w( 'lazysite/lazysite.conf',
    "site_name: Agency\nalias_hosts: clienta.com, clientb.com\n"
        . "alias.clienta.com.content_root: content/clientA\nalias.clienta.com.allowed_groups: role-client\n"
        . "alias.clientb.com.content_root: content/clientB\nalias.clientb.com.allowed_groups: clientb-team\n" );
w( 'lazysite/auth/.secret', $secret );
w( "content/clientA/$_.md", "---\ntitle: \u$_\n---\n\n$_ body\n" ) for qw(ok two locked);
w( 'content/clientB/secret.md', "---\ntitle: Secret\n---\n\nB body\n" );
w( 'content/clientA/book.md',
    "---\ntitle: Book\nparts:\n  - content/clientA/ok.md\n  - content/clientB/secret.md\n---\n\nBook\n" );
w( 'content/clientA/own-book.md',
    "---\ntitle: Own book\nparts:\n  - content/clientA/ok.md\n  - content/clientA/two.md\n---\n\nOwn\n" );

uapi( { action => 'add', username => 'op', password => 'x-long-enough' } );
grant_caps( $d, 'op', 'manage_users', 'manage_content', 'ui' ); # SM1057: uses the manager
uapi( { action => 'add', username => 'client', password => 'y-long-enough' } );
grant_caps( $d, 'client', 'manage_content', 'ui' );    # SM1057: a manager-UI client

subtest 'the page itself: inside the scope it renders, outside it is refused' => sub {
    my $own = pdf( 'client', 'content/clientA/ok.md' );
    is( $own->{status}, 200, 'own domain: 200' );
    ok( $own->{pdf} && $own->{ran}, '...a PDF, converted' );

    my $other = pdf( 'client', 'content/clientB/secret.md' );
    is( $other->{status}, 403, "another domain's page: 403" );
    like( $other->{json}{error} // '', qr/outside your assigned scope/, '...saying why, as read does' );
    ok( !$other->{pdf} && !$other->{ran}, '...and nothing was converted' );
};

subtest 'a composed document with one part outside the scope is refused, naming it' => sub {
    my $r = pdf( 'client', 'content/clientA/book.md' );
    is( $r->{status},     403,         'refused, 403' );
    is( $r->{json}{kind}, 'forbidden', 'kind forbidden, as the page refusal is' );
    like( $r->{json}{error} // '', qr{'content/clientB/secret\.md'.*outside your assigned scope}s,
        'the refusal names the part and why' );
    ok( !$r->{pdf} && !$r->{ran}, 'nothing was converted' );

    my $in = pdf( 'client', 'content/clientA/own-book.md' );
    is( $in->{status}, 200, 'a document of parts inside the scope renders' );
    ok( $in->{pdf} && $in->{ran}, '...converted' );

    my $op = pdf( 'op', 'content/clientA/book.md' );
    is( $op->{status}, 200, 'the unconfined operator gets the document with both parts' );
    ok( $op->{pdf}, '...a PDF' );
};

subtest "the page's own read rule is asked" => sub {
    my ( $st, undef, $body ) = post( 'op', 'action=acl-set&path=content/clientA/locked.md',
        '{"read":["op"],"write":["op"],"owner":"op"}' );
    is( $st, 200, 'op restricts content/clientA/locked.md to itself' ) or diag $body;

    my $r = pdf( 'client', 'content/clientA/locked.md' );
    is( $r->{status}, 403, 'client, whose scope holds it but whose rule does not: 403' );
    is( $r->{json}{kind}, 'permission', '...the refusal read gives' );
    ok( !$r->{pdf} && !$r->{ran}, '...nothing converted' );

    my $op = pdf( 'op', 'content/clientA/locked.md' );
    is( $op->{status}, 200, 'op, whom the rule names: 200' );
    ok( $op->{pdf} && $op->{ran}, '...converted' );
};

done_testing();
