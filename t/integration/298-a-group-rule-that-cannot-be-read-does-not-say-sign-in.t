#!/usr/bin/perl
# SM1201 (open note of SM1189): a bare `auth_groups: staff` (a value that is not a
# list) refused the page to everyone with "You need to sign in to view this page",
# to a signed-in member too, which no sign-in can help. SM1189 gave an unreadable
# address rule the one ruled address sentence; this is the same treatment for the
# group rule: a plain sentence that names no key and no group and does not send the
# reader to sign in. The page is still refused to everyone (fail closed), and a
# page whose unreadable key is `auth` or `payment` keeps its sign-in refusal.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

my $SENTENCE = 'This page is not available.';

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
spit( "$d/lazysite/lazysite.conf", "site_name: Test\nsite_url: http://localhost\nlayout: test\n" );
spit( "$d/bare.md",    "---\ntitle: Bare\nauth_groups: staff\n---\nBARE-BODY\n" );
spit( "$d/mixed.md",   "---\ntitle: Mixed\nauth_groups: staff\naddresses: office\n---\nMIXED-BODY\n" );
spit( "$d/mgr.md",     "---\ntitle: Mgr\nauth: manager\n---\nMGR-BODY\n" );
spit( "$d/good.md",    "---\ntitle: Good\nauth_groups: [staff]\n---\nGOOD-BODY\n" );

sub hit {
    my ($uri) = @_;
    my $out = run_processor( $d, $uri );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return { status => $st // 200, body => $body // '', head => $head // '' };
}

subtest 'a bare auth_groups is refused in a plain sentence, not "sign in"' => sub {
    for my $p (qw(/bare /mixed)) {
        my $r = hit($p);
        is( $r->{status}, 403, "$p is refused (fail closed)" );
        like( $r->{body}, qr/\Q$SENTENCE\E/, '  saying the plain sentence' );
        unlike( $r->{body}, qr/sign in|Authentication required|log in/i, '  and not sending the reader to sign in' );
        unlike( $r->{body}, qr/auth_groups|staff/, '  naming no key and no group' );
        unlike( $r->{body}, qr/(?:BARE|MIXED)-BODY/, '  and not the page' );
    }
};

subtest 'controls' => sub {
    my $m = hit('/mgr');
    is( $m->{status}, 403, 'auth: manager on a content page is still refused' );
    like( $m->{body}, qr/sign in|Authentication required/i, '  with the existing sign-in sentence' );
    unlike( $m->{body}, qr/\Q$SENTENCE\E/, '  not the new one' );
    my $g = hit('/good');
    isnt( $g->{status}, 200, 'a well-formed group rule still asks an anonymous visitor to sign in (redirect, not the page)' );
    unlike( $g->{body}, qr/GOOD-BODY/, '  and does not serve the page' );
};

# The shipped 403 page has the branch; a site's own older copy has not, and the
# sentence is put into it, as SM1139 does for the address sentence.
subtest 'with the shipped 403 page, and with a site copy that has no such branch' => sub {
    require File::Copy;
    File::Copy::copy( "$FindBin::Bin/../../starter/lazysite/templates/system/403.md", "$d/403.md" ) or die "copy: $!";
    my $r = hit('/bare');
    is( $r->{status}, 403, 'refused' );
    like( $r->{body}, qr/\Q$SENTENCE\E/, 'the shipped page says the sentence' );
    unlike( $r->{body}, qr/sign in/i, '...and does not say sign in' );
    unlink "$d/403.html";
    spit( "$d/403.md", "---\ntitle: Old\n---\n# Denied\n\nYou need to sign in to view this page.\n" );
    $r = hit('/mixed');
    is( $r->{status}, 403, 'refused with an old site copy' );
    like( $r->{body}, qr/\Q$SENTENCE\E/, 'the sentence is put into it' );
};

done_testing();
