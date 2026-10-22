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
#    with a helpful message since SM306 (and accepted since SM1047, which
#    resolves the path once for the scope check and the write - see
#    t/integration/205). One direction was guarded and the
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
# n562: the account has to EXIST - an 11-character password was refused (SM1041),
# so every call below ran on an unsecured site, as any name at all.
my $made = qx($^X \Q$users\E --docroot \Q$docroot\E setup-sysop --user sjm pw123456789-long-enough 2>&1);
is( $?, 0, 'the sysop account was made - every call below is made as it' ) or diag($made);
# SM901: @team has to be a group the store knows - a read list naming nobody
# who exists is refused, and that is the point of this file's other probe.
open my $gf, '>>', "$docroot/lazysite/auth/groups" or die $!;
print {$gf} "team: sjm\n";
close $gf;

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'sjm',      # SM1057: the sysop setup-sysop made
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
    my $d = api( 'action=acl-set&path=/probe', { owner => 'sjm' } );
    ok( $d->{ok},                 'the rule is accepted - it is a legitimate rule' );
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

subtest 'SM937: A DRAFT RULE DOES RESTRICT READS, AND IS NOT CALLED OPEN' => sub {
    # The caveat above is right about an owner-only rule and WAS WRONG about this
    # one. `draft: true` 404s the pages to the public - a stronger restriction
    # than gating, not a weaker one - and the reply still said
    # `reads_unrestricted: 1` with "anyone may still fetch these pages" about
    # pages nobody could fetch.
    #
    # The sites agent named the shape: the defect that makes a CORRECT operator
    # do the wrong thing. A reader either adds a read list the rule does not need,
    # or concludes the draft did not take and goes looking for a fault that is not
    # there.
    #
    # The cause was two rules for one question: this reply tested the read LIST,
    # while _acl_gates_public - which already counted draft, with the reasoning
    # written beside it - answered the read OUTCOME. It now asks that one.
    my $d = api( 'action=acl-set&path=/probe',
        { owner => 'sjm', draft => JSON::PP::true() } );
    ok( $d->{ok}, 'the rule is accepted' ) or diag( $d->{error} // '' );

    my $stored = api('action=acl-get&path=/probe');
    ok( $stored->{acl} && $stored->{acl}{draft},
        'draft really was stored - otherwise the assertion below passes for the '
            . 'wrong reason' );

    ok( !$d->{reads_unrestricted},
        'and the reply does NOT claim reads are unrestricted' )
        or diag( 'A draft section 404s to the public. Telling the operator '
            . '"anyone may still fetch these pages" about pages that 404 is the '
            . 'reported defect.' );
    ok( !defined $d->{reads_unrestricted_note},
        'and carries no note saying anyone may fetch them' );
    # SM1242: and says what a draft with no read list does.
    like( $d->{draft_note} // '', qr/404 to the public/, 'it says the pages answer 404 to the public' );
    like( $d->{draft_note} // '', qr/any signed-in account may preview/, 'and who may preview them' );
};

subtest 'SM1242: A PAGE INSIDE A DRAFT OR GATED FOLDER IS NOT CALLED OPEN' => sub {
    # #372a, from the xisl.com site agent: the reply judged the page's OWN record.
    # A page's owner-only rule inside a draft folder was told "anyone may still
    # fetch these pages" about a page that 404s; the same under a folder's read
    # list, about a page that bounces to sign-in.
    for my $dir (qw(held gated)) {
        make_path("$docroot/$dir");
        open my $fh, '>', "$docroot/$dir/page.md" or die $!;
        print {$fh} "---\ntitle: P\n---\n\nP.\n";
        close $fh;
    }
    ok( api( 'action=acl-set&path=/held', { draft => JSON::PP::true() } )->{ok}, 'the folder is a draft' );
    ok( api( 'action=acl-set&path=/gated', { read => ['@team'] } )->{ok}, 'the other folder has a read list' );

    my $d = api( 'action=acl-set&path=/held/page.md', { owner => 'sjm' } );
    ok( $d->{ok}, 'an owner-only rule on a page in the draft folder is accepted' ) or diag( $d->{error} // '' );
    ok( !$d->{reads_unrestricted}, 'and the reply does NOT say reads are unrestricted' );
    like( $d->{draft_note} // '', qr/held back as a draft by the rule on 'held\/?'/,
        'it names the folder rule that holds the page back' );
    like( $d->{draft_note} // '', qr/404 to the public/, 'and says what that does' );

    $d = api( 'action=acl-set&path=/gated/page.md', { owner => 'sjm' } );
    ok( $d->{ok}, 'an owner-only rule on a page in the gated folder is accepted' );
    ok( !$d->{reads_unrestricted}, 'and the reply does NOT say reads are unrestricted' );
    ok( !defined $d->{draft_note}, 'and says nothing about a draft' );

    $d = api( 'action=acl-set&path=/probe', { owner => 'sjm', draft => JSON::PP::false() } );
    ok( $d->{reads_unrestricted}, 'an owner-only rule with nothing above it still says reads are open' );
    ok( !defined $d->{draft_note}, 'and carries no draft note' );
};

done_testing();
