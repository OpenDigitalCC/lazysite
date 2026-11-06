#!/usr/bin/perl
# SM1365: a signed-in visitor outside an acls.json read list who opens a page in
# the governed directory gets the SITE'S 403 - 403.md in the layout, naming the
# rule's groups - the page a front-matter group gate already gives. It got a bare
# 103-byte "<h1>Forbidden</h1>" with no layout, no theme and no way back.
#
# A file the page embeds (an image) keeps the short plain 403: rendering a page
# for an <img> is wrong. Both carry the security header set. A draft section
# still answers 404, and an anonymous visitor is still bounced to sign in.
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $d = site_tempdir();
setup_test_site($d);
spit( "$d/lazysite/layouts/test/layout.tt",
    '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
        . '<body><header class="site-chrome">SITE-CHROME</header>[% content %]</body></html>' );
copy( "$FindBin::Bin/../../starter/lazysite/templates/system/403.md", "$d/403.md" ) or die "copy: $!";

spit( "$d/panel/index.md",   "---\ntitle: Panel\n---\nPANEL-INDEX\n" );
spit( "$d/panel/notes.md",   "---\ntitle: Notes\n---\nPANEL-NOTES\n" );
spit( "$d/panel/photo.png",  "PNGBYTES" );
spit( "$d/held/index.md",    "---\ntitle: Held\n---\nHELD-INDEX\n" );
spit( "$d/lazysite/auth/acls.json",
    encode_json(
        {   'panel' => { read => [ '@reviewers', 'carol', '@leads' ] },
            'held'  => { read => ['@reviewers'], draft => JSON::PP::true },
        }
    ) );

sub hit {
    my ( $uri, %env ) = @_;
    unlink glob("$d/panel/*.html"), glob("$d/held/*.html"), "$d/403.html";
    my $out = run_processor( $d, $uri, %env );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return { status => $st // 200, body => $body // '', head => $head // '' };
}

my %OUTSIDER = (
    LAZYSITE_AUTH_TRUSTED => '1',
    HTTP_X_REMOTE_USER    => 'bob',
    HTTP_X_REMOTE_GROUPS  => 'visitors',
);
my %MEMBER = (
    LAZYSITE_AUTH_TRUSTED => '1',
    HTTP_X_REMOTE_USER    => 'dana',
    HTTP_X_REMOTE_GROUPS  => 'reviewers',
);
my $NAV = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
my $IMG = 'image/avif,image/webp,image/png,image/*,*/*;q=0.8';

subtest 'a signed-in outsider opening the directory gets the site 403' => sub {
    for my $p ( '/panel/', '/panel/notes' ) {
        my $r = hit( $p, %OUTSIDER, HTTP_ACCEPT => $NAV );
        is( $r->{status}, 403, "$p is refused with 403" );
        like( $r->{body}, qr/SITE-CHROME/, '  in the site layout' );
        like( $r->{body}, qr/You are signed in as\s*<strong>bob<\/strong>/, '  saying who is signed in' );
        like( $r->{body}, qr/one of these groups:.*\breviewers\b/s, '  naming the first group' );
        like( $r->{body}, qr/one of these groups:.*\bleads\b/s,     '  and the second' );
        unlike( $r->{body}, qr/carol/,       '  never a user named on the list' );
        unlike( $r->{body}, qr/\@reviewers/, '  and a group without its @' );
        unlike( $r->{body}, qr/PANEL-(?:INDEX|NOTES)/, '  and not the page' );
        unlike( $r->{body}, qr/You do not have access to this file/, '  not the bare body' );
        like( $r->{head}, qr/^X-Content-Type-Options: nosniff/mi, '  with the security headers' );
    }
    my $r = hit( '/panel/', %OUTSIDER );
    is( $r->{status}, 403, 'with no Accept header at all the directory still gets it' );
    like( $r->{body}, qr/SITE-CHROME/, '  (a directory is a page)' );
};

subtest 'an image under the same rule keeps the short 403' => sub {
    for my $accept ( $IMG, undef ) {
        my $r = hit( '/panel/photo.png', %OUTSIDER, HTTP_ACCEPT => $accept );
        my $as = defined $accept ? 'asked for as an image' : 'with no Accept';
        is( $r->{status}, 403, "refused, $as" );
        like( $r->{body}, qr/You do not have access to this file/, '  the short body' );
        unlike( $r->{body}, qr/SITE-CHROME/, '  not a rendered page' );
        unlike( $r->{body}, qr/PNGBYTES/,    '  and not the file' );
        like( $r->{head}, qr/^X-Content-Type-Options: nosniff/mi, '  with the security headers' );
    }
};

subtest 'unchanged: members, drafts and anonymous visitors' => sub {
    my $m = hit( '/panel/', %MEMBER, HTTP_ACCEPT => $NAV );
    is( $m->{status}, 200, 'a member reads the directory' );
    like( $m->{body}, qr/PANEL-INDEX/, '  and its page' );

    my $dr = hit( '/held/', %OUTSIDER, HTTP_ACCEPT => $NAV );
    is( $dr->{status}, 404, 'a draft section is a 404 to a signed-in outsider' );
    unlike( $dr->{body}, qr/reviewers/, '  naming no group' );
    is( hit( '/held/', HTTP_ACCEPT => $NAV )->{status}, 404, '  and to the public' );

    my $an = hit( '/panel/', HTTP_ACCEPT => $NAV );
    is( $an->{status}, 302, 'an anonymous visitor is still sent to sign in' );
    like( $an->{head}, qr{^Location: /login\?next=}m, '  at the login page' );
    is( hit('/panel/photo.png')->{status}, 302, '  and so is an anonymous image request' );
};

done_testing();
