#!/usr/bin/perl
# SM479: acl-set accepted a read list, discarded it, and reported success.
#
# REPORTED FROM THE FIELD ON 0.10.26. Gating a folder:
#
#   POST ?action=acl-set&path=/probe&read=@team
#   -> {"ok":true,"acl":{"owner":"..."},"content_moved":1,
#       "content_moved_note":"content moved out of the document root..."}
#
#   GET https://.../probe/  -> 200, the page in full, to anyone.
#
# Seven spellings were tried - read=, readers=, read_groups=, groups=, allow=,
# url-encoded, read[]= - and every one returned ok:true and left the rule
# owner-only. Every signal available to the caller said protected. The page was
# public.
#
# TWO SEPARATE FAULTS, and the second is the one that made it dangerous.
#
# 1. `read` belongs in the JSON BODY; sent in the query it was silently
#    dropped. The symmetric mistake - a `path` in the body - has been REFUSED
#    with a helpful message since SM306. One direction was guarded and the
#    other was not, so the capability worked and was unreachable by the route
#    somebody naturally tried.
#
# 2. An owner and no read list is a legitimate rule that governs WRITES and
#    leaves reading open. Paired with `content_moved`, it produced a reply in
#    which everything visible said protected. That combination now says
#    plainly that reads are not restricted.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/probe" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $pg, '>', "$docroot/probe/index.md" or die $!;
print {$pg} "---\ntitle: Probe\n---\n\nSecret-ish.\n";
close $pg;

my $users = "$root/tools/lazysite-users.pl";
qx($^X \Q$users\E --docroot \Q$docroot\E setup-manager pw123456789 2>/dev/null);

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'setup-manager',
        LAZYSITE_AUTH_TRUSTED => 1,
    );
}

# A REAL CSRF TOKEN, because the POST path requires one and a test that skips
# it measures the CSRF gate instead of the thing it came to measure - which is
# what the first version of this file did, reporting "Invalid or missing CSRF
# token" for every case.
my $TOKEN = do {
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET',
        QUERY_STRING => 'action=csrf-token' );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    ( eval { decode_json($out) } || {} )->{token};
};
ok( $TOKEN, 'a CSRF token was obtained' ) or BAIL_OUT('no token, nothing below is testing acl-set');

sub api {
    my ( $qs, $body ) = @_;
    return do {
        local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
        my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
        $out =~ s/\A.*?\r?\n\r?\n//s;
        eval { decode_json($out) } || { _raw => $out };
    } unless defined $body;

    my $json = encode_json($body);
    my $tmp  = "$docroot/.post-body";
    open my $bf, '>', $tmp or die $!;
    print {$bf} $json;
    close $bf;

    local %ENV = (
        cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length($json),
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$tmp\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { _raw => $out };
}

subtest 'A LIST SENT IN THE QUERY IS REFUSED, NOT DISCARDED' => sub {
    my $d = api( 'action=acl-set&path=/probe&read=@team', {} );
    ok( !$d->{ok}, 'the call is refused' )
        or diag( 'This returned ok:true and wrote a rule with no read list, '
            . 'while telling the caller content had been moved. The caller '
            . 'had no way to learn the page was still public.' );
    is( $d->{kind}, 'misrouted-argument', 'as a misrouted argument' );
    like( $d->{error}, qr/\bbody\b/, 'saying where the lists belong' );
    like( $d->{error}, qr/read/,     'and naming the one that was misrouted' );

    # AND IT WROTE NOTHING. A refusal that had already applied a half-rule
    # would be worse than the silence it replaces.
    my $g = api('action=acl-get&path=/probe');
    ok( !( $g->{acl} && $g->{acl}{owner} ), 'no rule was written' );
};

subtest 'every list is checked, not just the first' => sub {
    for my $k (qw(write owner draft)) {
        my $d = api( "action=acl-set&path=/probe&$k=x", {} );
        ok( !$d->{ok}, "a misrouted '$k' is refused too" )
            or diag( 'Guarding only `read` would leave three more ways to '
                . 'write a rule that is not the rule you asked for.' );
    }
};

subtest 'THE ROUTE THAT WORKS STILL WORKS' => sub {
    # The capability was never missing - the field agent put path AND read in
    # the body, which is refused for the path, and concluded the route was
    # closed. Path in the query, lists in the body.
    my $d = api( 'action=acl-set&path=/probe', { read => ['@team'] } );
    ok( $d->{ok}, 'path in the query, read in the body: accepted' )
        or diag( 'Reply: ' . encode_json($d) );

    my $g = api('action=acl-get&path=/probe');
    is_deeply( $g->{acl}{read}, ['@team'], 'and the read list is stored' );

    ok( !$d->{reads_unrestricted},
        'a rule that DOES restrict reads is not flagged as open' )
        or diag( 'A caveat that fires on a correct rule trains people to '
            . 'ignore it.' );
};

subtest 'A RULE THAT RESTRICTS NO READS SAYS SO' => sub {
    # An owner and no read list is legitimate - it governs writes. What made it
    # dangerous was the reply: ok:1, an acl object, and a note about content
    # leaving the document root, with nothing saying reading was still open.
    my $d = api( 'action=acl-set&path=/probe', { owner => 'setup-manager' } );
    ok( $d->{ok}, 'the rule is accepted - it is a legitimate rule' );
    ok( $d->{reads_unrestricted}, 'and the reply says reads are NOT restricted' )
        or diag( 'Without this the caller sees ok:1, an acl, and "content '
            . 'moved out of the document root" - and concludes the page is '
            . 'protected, which is what happened.' );
    like( $d->{reads_unrestricted_note}, qr/anyone may still fetch/,
        'in words that say what it means for a visitor' );
    like( $d->{reads_unrestricted_note}, qr/read/,
        'and what to pass to gate it' );

    # NOT IN `warnings`: nothing went wrong, and a caller filtering warnings
    # for failures should not find a caveat about a successful call there.
    ok( !( grep { /restrict/i } @{ $d->{warnings} || [] } ),
        'and it is not filed as a warning' );
};

done_testing();
