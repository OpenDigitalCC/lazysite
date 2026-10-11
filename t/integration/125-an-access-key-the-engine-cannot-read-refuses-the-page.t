#!/usr/bin/perl
# SM980 (ruled 2026-10-11, "Parse it + fail closed"): a page's access keys are
# read in every spelling YAML makes unambiguous, and one that still cannot be
# read refuses the page to everyone.
#
# Reported from a members' area on 0.15.3: `auth: required` with
# `auth_groups: [feedback-readers, sysops]` served a signed-in member of neither
# group the page and its table rows (200). The block list refused the same member
# (403). `lazysite validate` said nothing. The gate's peek
# (lazysite-processor/auth.pm, _peek_md) read auth_groups only as a block list
# (`^auth_groups\s*:\s*$` then `- name` lines), so the flow list was not read at
# all and the page carried no group restriction.
#
# Measured beside it on main (tmp/probe2.pl, .main.out): a bare name, an empty
# list and a broken list did the same; `auth: "required"`, `auth: [required]`
# and an unknown auth value served the page to anonymous visitors; and
# `payment: "required"` or `payment: Required` served a paid page free.
#
# Every request is the real processor, as the auth wrapper calls it: a trusted
# X-Remote-User and X-Remote-Groups, or none for an anonymous visitor.
use strict;
use warnings;
use Test::More;
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $proc = "$root/lazysite-processor.pl";
my $d    = site_tempdir();
make_path("$d/lazysite/auth");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );

sub page {
    my ( $name, $fm ) = @_;
    spit( "$d/$name.md", "---\ntitle: $name\n$fm---\nSECRET-ROWS-$name\n" );
    return "/$name";
}

# ( status, served the body?, stderr )
sub get {
    my ( $uri, $user, $groups ) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    @ENV{qw(DOCUMENT_ROOT REDIRECT_URL REQUEST_METHOD QUERY_STRING)} = ( $d, $uri, 'GET', '' );
    if ( defined $user ) {
        @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)} = ( $user, $groups, 1 );
    }
    my ( $w, $r, $e ) = ( undef, undef, gensym );
    my $pid = open3( $w, $r, $e, $^X, $proc );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, ( $out =~ /SECRET-ROWS/ ? 1 : 0 ), $err // '' );
}
sub anon     { return get( $_[0] ) }
sub outsider { return get( $_[0], 'mallory', 'members' ) }
sub member   { return get( $_[0], 'rita',    'members,feedback-readers' ) }

subtest 'the reported case: a flow list restricts the page as the block list does' => sub {
    my $flow = page( 'inbox-flow', "auth: required\nauth_groups: [feedback-readers, sysops]\n" );
    my $block = page( 'inbox-block', "auth: required\nauth_groups:\n  - feedback-readers\n  - sysops\n" );
    for my $uri ( $flow, $block ) {
        my ( $st, $body ) = outsider($uri);
        is( $st, 403, "$uri: a signed-in member of neither group is refused" );
        ok( !$body, "$uri: and gets none of the page" );
        ( $st, $body ) = member($uri);
        is( $st, 200, "$uri: a member of a listed group gets in" );
        ok( $body, "$uri: and gets the page" );
        ($st) = anon($uri);
        is( $st, 302, "$uri: an anonymous visitor is sent to sign in" );
    }
    my $q = page( 'inbox-quoted', "auth: required\nauth_groups: [\"feedback-readers\", 'sysops']  # who reads it\n" );
    is( ( outsider($q) )[0], 403, 'quoted names and a trailing comment: the outsider is refused' );
    is( ( member($q) )[0], 200, 'and the member gets in' );
    my $c0 = page( 'inbox-col0', "auth: required\nauth_groups:\n- feedback-readers\n" );
    is( ( outsider($c0) )[0], 403, 'a block list at the key\'s own column (valid YAML): refused' );
    is( ( member($c0) )[0], 200, 'and the member gets in' );
};

my %UNREADABLE = (
    'a bare name' => [ "auth: required\nauth_groups: feedback-readers\n", 'auth_groups' ],
    'an empty list' => [ "auth: required\nauth_groups: []\n", 'auth_groups' ],
    'no value'      => [ "auth: required\nauth_groups:\n",    'auth_groups' ],
    'an unclosed list' => [ "auth: required\nauth_groups: [feedback-readers, sysops\n", 'auth_groups' ],
    'a name that is not one' => [ "auth: required\nauth_groups: [feedback readers]\n", 'auth_groups' ],
    'auth as a list'           => [ "auth: [required]\n",                  'auth' ],
    'an unknown auth value'    => [ "auth: members\n",                     'auth' ],
    'an unknown payment value' => [ "payment: maybe\npayment_amount: 1\n", 'payment' ],
    'a bare name on a page with no auth' => [ "auth_groups: feedback-readers\n", 'auth_groups' ],
);

subtest 'a value that still cannot be read refuses the page to everyone, naming the key' => sub {
    for my $case ( sort keys %UNREADABLE ) {
        my ( $fm, $key ) = @{ $UNREADABLE{$case} };
        ( my $slug = $case ) =~ s/\W+/-/g;
        my $uri = page( "bad-$slug", $fm );
        for my $who ( [ 'anonymous', \&anon ], [ 'an outsider', \&outsider ], [ 'a member', \&member ] ) {
            my ( $st, $body, $err ) = $who->[1]->($uri);
            is( $st, 403, "$case: $who->[0] gets 403" );
            ok( !$body, "$case: $who->[0] gets none of the page" );
            like( $err, qr/access key unreadable - page refused to everyone.*key=\Q$key\E|key=\Q$key\E.*access key unreadable/,
                "$case: the log names the key ($key)" )
                if $who->[0] eq 'anonymous';
        }
    }
};

subtest 'the sibling keys are read in the same spellings' => sub {
    my $aq = page( 'auth-quoted', "auth: \"required\"\n" );
    is( ( anon($aq) )[0], 302, 'auth: "required" sends an anonymous visitor to sign in' );
    ok( !( anon($aq) )[1], 'and serves none of the page' );
    my $ac = page( 'auth-comment', "auth: Required # members only\n" );
    is( ( anon($ac) )[0], 302, 'a capitalised value with a comment, likewise' );
    for my $spelling ( '"required"', 'Required', "'required'" ) {
        ( my $slug = $spelling ) =~ s/\W+//g;
        my $p = page( "pay-$slug", "payment: $spelling\npayment_amount: 1\npayment_address: 0xabc\n" );
        my ( $st, $body ) = anon($p);
        is( $st, 402, "payment: $spelling charges for the page" );
        ok( !$body, '  and serves none of it unpaid' );
    }
    my $bypass = page( 'pay-bypass', "payment: required\npayment_amount: 1\npayment_address: 0xabc\nauth_groups: [feedback-readers]\n" );
    is( ( member($bypass) )[0], 200, 'a flow-list auth_groups lets a member past the payment, as the block list does' );
    is( ( outsider($bypass) )[0], 402, 'and charges an outsider' );
};

subtest 'lazysite validate reports what the gate will refuse' => sub {
    my $v = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-validate.pl", '--docroot', $d;
    my $out = qx($v \Q$d/bad-a-bare-name.md\E 2>&1);
    isnt( $? >> 8, 0, 'a page with an unreadable auth_groups fails validation' );
    like( $out, qr/auth_groups.*is one value, not a list/, 'naming the key and why' ) or diag($out);
    like( $out, qr/refused to everyone \(403\)/, 'and what the gate will do about it' );
    $out = qx($v \Q$d/bad-an-unknown-payment-value.md\E 2>&1);
    like( $out, qr/payment: maybe.*not one of required, none/, 'an unreadable payment value too' ) or diag($out);
    $out = qx($v \Q$d/inbox-flow.md\E 2>&1);
    unlike( $out, qr/access-key|auth_groups/, 'the flow list passes' ) or diag($out);
};

subtest 'a page the gate refuses is in no listing' => sub {
    require TestHelper;
    TestHelper::load_processor($d);
    no warnings 'once';
    ok( main::_registry_hidden("$d/bad-a-bare-name-on-a-page-with-no-auth.md"),
        'left out of the registries (sitemap, feeds), with no auth: key to hide it' );
    local $ENV{HTTP_X_REMOTE_USER}   = 'rita';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'members,feedback-readers';
    ok( main::_scan_hidden("$d/bad-an-empty-list.md"), 'and out of a scan, even for a member of the group it meant' );
};

done_testing();
