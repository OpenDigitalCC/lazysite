#!/usr/bin/perl
# SM1068's security half. The ruling narrows what "governed" means to the rules
# that change what a viewer sees - a read list or a draft flag - so each of the
# things a governed page was protected by is checked here to be unchanged for
# those rules, whatever write-only rules sit beside or around them.
#
#   * a page under a READ rule is never cached and never served to a reader the
#     rule excludes, including after a permitted reader has rendered it;
#   * a draft is still hidden;
#   * an undecodable or unreadable acls.json still fails closed (SM1024):
#     refused, never cached;
#   * a file in the private store is never written to, or served from, the
#     public path.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site site_tempdir run_processor);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub cache_control { my ($r) = @_; my ($cc) = $r =~ /^Cache-Control:\s*([^\r\n]*)/mi; return $cc // '' }
sub status        { my ($r) = @_; my ($s) = $r =~ /^Status:\s*(\d+)/mi; return $s // 200 }

my @ALICE = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
my @BOB   = ( HTTP_X_REMOTE_USER => 'bob',   HTTP_X_REMOTE_GROUPS => 'members' );

# A write-only rule on / and an owner-and-write rule on the page itself sit
# around every gated page below, so the narrowing is exercised where it could
# have hidden the read rule.
sub site {
    my ($rules) = @_;
    my $docroot = site_tempdir();
    setup_auth_site($docroot);
    mkdir "$docroot/sec";
    put( "$docroot/sec/page.md", "---\ntitle: Gated\n---\nGATED-BODY-1068\n" );
    put( "$docroot/lazysite/auth/acls.json", $rules );
    return $docroot;
}

subtest 'a READ rule: never cached, never served to a reader it excludes' => sub {
    my $d = site( '{"/":{"owner":"root","write":["@admins"]},'
            . '"sec":{"read":["alice"]},'
            . '"sec/page.md":{"owner":"bob","write":["bob"]}}' );
    my $a = run_processor( $d, '/sec/page', @ALICE );
    like( $a, qr/GATED-BODY-1068/, 'a reader on the list is served' );
    like( cache_control($a), qr/no-store, private/, 'no-store, private' );
    ok( !-f "$d/sec/page.html", 'no render written to the page cache' );

    my $anon = run_processor( $d, '/sec/page' );
    unlike( $anon, qr/GATED-BODY-1068/, 'anonymous, after a permitted render: not served' );
    like( status($anon), qr/30[23]/, 'and sent to log in' );

    my $b = run_processor( $d, '/sec/page', @BOB );
    unlike( $b, qr/GATED-BODY-1068/, 'the page owner, outside the read list: not served' );
    is( status($b), 403, 'and refused' );
};

subtest 'a DRAFT is still hidden, and still listed nowhere' => sub {
    my $d = site( '{"/":{"owner":"root","write":["@admins"]},'
            . '"sec":{"draft":true},'
            . '"sec/page.md":{"owner":"bob","write":["bob"]}}' );
    my $anon = run_processor( $d, '/sec/page' );
    unlike( $anon, qr/GATED-BODY-1068/, 'anonymous: not served' );
    is( status($anon), 404, 'answered as not found' );
    my $a = run_processor( $d, '/sec/page', @ALICE );
    like( $a, qr/GATED-BODY-1068/, 'a signed-in reader may preview it' );
    like( cache_control($a), qr/no-store, private/, 'and the preview is no-store' );
    ok( !-f "$d/sec/page.html", 'and is not cached' );
};

for my $case ( [ 'an undecodable store', '{"sec":{"read":["alice"]}' ], [ 'a JSON array', '["sec"]' ] ) {
    my ( $what, $bytes ) = @$case;
    subtest "FAILS CLOSED on $what (SM1024)" => sub {
        my $d = site($bytes);
        my $anon = run_processor( $d, '/sec/page' );
        unlike( $anon, qr/GATED-BODY-1068/, 'the gated page is refused' );
        my $home = run_processor( $d, '/' );
        unlike( $home, qr/Home page\./, 'and so is a page no rule names' );
        unlike( cache_control($home), qr/^(?:no-cache|public)/, 'never a cacheable answer' );
        ok( !-f "$d/index.html" && !-f "$d/sec/page.html", 'nothing written to the page cache' );
    };
}

SKIP: {
    skip 'running as root: chmod 000 does not refuse root', 1 if $> == 0;
    subtest 'FAILS CLOSED on an unreadable store' => sub {
        my $d = site('{"/":{"owner":"root","write":["@admins"]}}');
        chmod 0, "$d/lazysite/auth/acls.json";
        my $home = run_processor( $d, '/' );
        chmod 0644, "$d/lazysite/auth/acls.json";
        unlike( $home, qr/Home page\./, 'refused' );
        ok( !-f "$d/index.html", 'and not cached' );
    };
}

subtest 'a page in the PRIVATE STORE is never written to or served from the public path' => sub {
    my $d = site( '{"/":{"owner":"root","write":["@admins"]},"sec":{"read":["alice"]}}' );
    my $priv = "$d-lazysite-private";
    mkdir $priv;
    mkdir "$priv/sec";
    rename "$d/sec/page.md", "$priv/sec/page.md" or die "move to store: $!";
    my $a = run_processor( $d, '/sec/page', @ALICE );
    like( $a, qr/GATED-BODY-1068/, 'the reader is served from the store' );
    ok( !-f "$d/sec/page.html",    'no render in the document root' );
    ok( !-f "$priv/sec/page.html", 'nor in the store, since it is governed' );
    my $anon = run_processor( $d, '/sec/page' );
    unlike( $anon, qr/GATED-BODY-1068/, 'and anonymous is refused' );
};

done_testing();
