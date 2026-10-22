#!/usr/bin/perl
# SM993 (ruled 2026-10-12, Findings 3+4, "Fix both as recommended"): auth_groups
# always means signed in, and `auth: manager` on a content page refuses
# everyone.
#
# Found while building SM980 (t/integration/125) and filed for a ruling:
#
#   3. check_auth returned before its group test for `auth: none` (the default)
#      and, for an anonymous visitor, for `auth: optional` - so a page naming
#      auth_groups went to the public while a signed-in non-member was refused.
#      The scan and the registries listed it the same way.
#   4. `auth: manager` is enforced only by the manager path's own gate; on any
#      other page it enforced nothing - 200 with the body to anyone.
#
# A paid page is the one exception to 3, by the payment docs: its auth_groups
# is the list that skips payment, and everyone else is charged (402).
#
# Every request is the real processor, as the auth wrapper calls it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root = repo_root();
my $proc = "$root/lazysite-processor.pl";
my $d    = site_tempdir();
make_path("$d/lazysite/auth");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );

sub page {
    my ( $name, $fm ) = @_;
    my $f = "$d/$name.md";
    make_path( $f =~ s{/[^/]+\z}{}r );
    spit( $f, "---\ntitle: $name\n$fm---\nSECRET-BODY-$name\n" );
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
    my ( $out, $err ) = @{ run_child( [ $^X, $proc ] ) }{qw(out err)};
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, ( $out =~ /SECRET-BODY/ ? 1 : 0 ), $err // '' );
}
sub anon     { return get( $_[0] ) }
sub outsider { return get( $_[0], 'mallory', 'members' ) }
sub member   { return get( $_[0], 'rita',    'members,readers' ) }

subtest 'Finding 3: a page naming auth_groups is a signed-in page' => sub {
    my %pages = (
        'no auth key, flow list' => page( 'g-none', "auth_groups: [readers]\n" ),
        'auth: none, block list' => page( 'g-none-blk', "auth: none\nauth_groups:\n  - readers\n" ),
        'auth: optional' => page( 'g-optional', "auth: optional\nauth_groups: [readers]\n" ),
        'auth: required (as was)' => page( 'g-required', "auth: required\nauth_groups: [readers]\n" ),
    );
    for my $what ( sort keys %pages ) {
        my $uri = $pages{$what};
        my ( $st, $body ) = anon($uri);
        is( $st, 302, "$what: an anonymous visitor is sent to sign in" );
        ok( !$body, "$what: and gets none of the page" );
        ( $st, $body ) = outsider($uri);
        is( $st, 403, "$what: a signed-in non-member is refused" );
        ok( !$body, "$what: and gets none of it" );
        ( $st, $body ) = member($uri);
        is( $st, 200, "$what: a member gets in" );
        ok( $body, "$what: and gets the page" );
    }
    my $open = page( 'no-groups', "auth: optional\n" );
    my ( $st, $body ) = anon($open);
    ok( $st == 200 && $body, 'a page naming no groups is as it was: auth: optional serves an anonymous visitor' );
};

subtest 'a paid page keeps its bypass list: everyone else pays' => sub {
    my $paid = page( 'paid', "payment: required\npayment_amount: 1\npayment_address: 0xabc\nauth_groups: [readers]\n" );
    my ( $st, $body ) = anon($paid);
    ok( $st == 402 && !$body, 'an anonymous visitor is charged (402), not sent to sign in' );
    ( $st, $body ) = outsider($paid);
    ok( $st == 402 && !$body, 'a signed-in non-member is charged' );
    ( $st, $body ) = member($paid);
    ok( $st == 200 && $body, 'a member skips the payment' );
};

subtest 'Finding 4: auth: manager on a content page refuses everyone' => sub {
    my $p = page( 'panel', "auth: manager\n" );
    for my $who ( [ 'anonymous', [] ], [ 'a signed-in account', [ 'mallory', 'members' ] ],
        [ 'a member of everything', [ 'rita', 'members,readers,sysops' ] ] )
    {
        my ( $st, $body, $err ) = get( $p, @{ $who->[1] } );
        is( $st, 403, "$who->[0]: 403" );
        ok( !$body, "$who->[0]: and none of the page" );
        like( $err, qr/access key unreadable - page refused to everyone(?=.*key=auth\b)(?=.*auth: manager)/,
            "$who->[0]: logged, naming the key and why" );
    }
    my $deep = page( 'docs/deep/panel', "auth: \"Manager\"\n" );
    is( ( anon($deep) )[0], 403, 'quoted and capitalised, deeper in the site: refused too' );
};

subtest 'lazysite validate reports auth: manager outside the manager path' => sub {
    my $v = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-validate.pl", '--docroot', $d;
    my $out = qx($v \Q$d/panel.md\E 2>&1);
    isnt( $? >> 8, 0, 'a content page with auth: manager fails validation' );
    like( $out, qr/auth: manager.*applies only to the manager's own pages/, 'saying why' ) or diag($out);
    like( $out, qr/refused to everyone \(403\)/, 'and what the gate will do about it' );

    make_path("$d/manager");
    spit( "$d/manager/tool.md", "---\ntitle: Tool\nauth: manager\n---\nx\n" );
    $out = qx($v \Q$d/manager/tool.md\E 2>&1);
    unlike( $out, qr/access-key|auth: manager/, 'a page under the manager path passes' ) or diag($out);

    my $bare = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-validate.pl";
    $out = qx($bare \Q$root/starter/manager/users.md\E 2>&1);
    unlike( $out, qr/auth: manager/, 'a shipped manager page, named with no docroot, passes' ) or diag($out);
    $out = qx($bare \Q$d/panel.md\E 2>&1);
    like( $out, qr/applies only to the manager's own pages/, 'and a content page named the same way is reported' );
};

subtest 'neither is in any listing' => sub {
    require TestHelper;
    TestHelper::load_processor($d);
    no warnings 'once';
    ok( main::_registry_hidden("$d/g-none.md"), 'an auth_groups page is out of the registries (sitemap, feeds)' );
    ok( main::_registry_hidden("$d/panel.md"), 'an auth: manager page too' );
    ok( !main::_registry_hidden("$d/paid.md"), 'a paid page is listed as before' );
    # The scan reads its identity once a process, so the anonymous one is asked
    # in a child.
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        local $ENV{HTTP_X_REMOTE_USER}   = '';
        local $ENV{HTTP_X_REMOTE_GROUPS} = '';
        exit( main::_scan_hidden("$d/g-none.md") ? 0 : 1 );
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'an anonymous scan leaves the auth_groups page out' );
    local $ENV{HTTP_X_REMOTE_USER}   = 'rita';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'members,readers,sysops';
    ok( !main::_scan_hidden("$d/g-none.md"), 'a member\'s scan lists it' );
    ok( main::_scan_hidden("$d/panel.md"), 'an auth: manager page is in no scan, for anyone' );
};

subtest 'the shipped pages carry no auth: manager outside the manager' => sub {
    my @bad;
    for my $f ( sort glob("$root/starter/docs/*.md"), glob("$root/starter/*.md") ) {
        open my $fh, '<', $f or next;
        my $head = '';
        while ( my $l = <$fh> ) { last if $. > 1 && $l =~ /^---/; $head .= $l }
        close $fh;
        push @bad, $f =~ s{^\Q$root\E/}{}r if $head =~ /^auth:\s*["']?manager/mi;
    }
    is_deeply( \@bad, [], 'every shipped content page states an access level the engine enforces' );
};

done_testing();
