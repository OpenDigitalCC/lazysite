#!/usr/bin/perl
# SM1213: AN EMPTY FRONT-MATTER KEY, AGAINST THE REAL PROCESSOR.
#
# The render parse read `title:` (no value) as taking the next line, so the key on
# that line was lost to the renderer. The question that matters is whether that
# opens anything. The gate (auth.pm, _peek_md and _access_keys_read) reads each
# line for itself, so a gated page stays gated whatever is above its access key -
# this holds that, signed out and signed in, and that no such page reaches the
# shared cache. In the other direction, an empty key on a gated-by-default site
# makes no `auth: none` appear.
#
# What it DID open is the ADR 0006 boundary: the renderer decides whether a page
# is served verbatim (api:/raw:), the peek decides whether its declared HTML type
# is downgraded to text/plain, and the two read the front matter differently.
#
#     api:                  the renderer: api = 'true', the body served verbatim
#     true                  the peek: no api, so `content_type: text/html` stood
#     content_type: text/html
#
# and likewise `api: "true"` (the renderer strips one pair of quotes, the peek did
# not) and `content_type: "text/html"` (the peek kept the quotes, so the downgrade
# did not match). A raw page now serves no script-capable type in any spelling.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor setup_auth_site setup_test_site site_tempdir);

sub page {
    my ( $d, $name, $fm, $body ) = @_;
    open my $fh, '>', "$d/$name.md" or die "$d/$name.md: $!";
    print {$fh} "---\n$fm---\n" . ( $body // "SECRET-$name\n" );
    close $fh;
}

sub status { ( $_[0] =~ /^Status:\s*(\d{3})/mi )[0] // '' }
sub ct     { ( $_[0] =~ /^Content-type:\s*([^\r\n]+)/mi )[0] // '' }

sub cached_html {
    my ($d) = @_;
    my @f;
    find( sub { push @f, $File::Find::name if /\.html\z/ }, $d );
    return @f;
}

my %bob = ( HTTP_X_REMOTE_USER => 'bob', HTTP_X_REMOTE_GROUPS => 'members' );

subtest 'a gated page stays gated with an empty key above its access key' => sub {
    my $d = site_tempdir();
    setup_auth_site($d);
    my %pages = (
        'e-auth'    => [ "title:\nauth: required\n",            302, 200 ],
        'e-auth-sp' => [ "title:   \nauth: required\n",         302, 200 ],
        'e-groups'  => [ "title:\nauth_groups: [admins]\n",     302, 403 ],
        'e-groupsb' => [ "title:\nauth_groups:\n  - admins\n",  302, 403 ],
        'e-pay'     => [ "title:\npayment: required\npayment_amount: 1\n", 402, 402 ],
        'e-addr'    => [ "title:\naddresses: [office]\n",       403, 403 ],
        'e-authnil' => [ "auth:\nsubtitle: x\n",                403, 403 ],
    );
    page( $d, $_, $pages{$_}[0] ) for keys %pages;
    for my $p ( sort keys %pages ) {
        my ( undef, $anon, $signed ) = @{ $pages{$p} };
        for my $try ( 1, 2 ) {    # the second asks the cache, had the first filled it
            my $out = scalar run_processor( $d, "/$p" );
            is( status($out), $anon, "$p signed out (request $try): $anon" );
            unlike( $out, qr/SECRET-$p/, "$p signed out (request $try): no body" );
        }
        my $out = scalar run_processor( $d, "/$p", %bob );
        is( status($out), $signed, "$p signed in as a member: $signed" );
        like( $out, qr/^Cache-Control: no-store/mi, "$p signed in: no-store" ) if $signed == 200;
        unlike( scalar run_processor( $d, "/$p" ), qr/SECRET-$p/, "$p signed out after a member's render: no body" );
    }
    is_deeply( [ grep { m{/e-[^/]*\.html\z} } cached_html($d) ], [], 'no gated page was written to the page cache' );
};

subtest 'on a gated-by-default site an empty key makes no auth: none' => sub {
    my $d = site_tempdir();
    setup_auth_site($d);
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "auth_default: required\n";
    close $cf;
    page( $d, 'd-empty',   "title:\nsubtitle: none\n" );
    page( $d, 'd-authnil', "auth:\nnone\n" );
    page( $d, 'd-none',    "title:\nauth: none\n" );
    is( status( scalar run_processor( $d, '/d-empty' ) ),   302, '`title:` above `subtitle: none`: still gated' );
    is( status( scalar run_processor( $d, '/d-authnil' ) ), 403, '`auth:` with `none` below it: refused to everyone' );
    my $out = scalar run_processor( $d, '/d-none' );
    is( status($out), 200, '`title:` above `auth: none`: public, as written' );
    like( $out, qr/SECRET-d-none/, '  ...and served' );
};

subtest 'a raw page serves no script-capable type, however it is spelt' => sub {
    my $d = site_tempdir();
    setup_auth_site($d);
    my $js = "<script>alert(1)</script>\n";
    my %pages = (
        'x-next'  => "title: X\napi:\ntrue\ncontent_type: text/html\n",
        'x-rnext' => "title: X\nraw:\ntrue\ncontent_type: text/html\n",
        'x-dq'    => "title: X\napi: \"true\"\ncontent_type: text/html\n",
        'x-sq'    => "title: X\nraw: 'true'\ncontent_type: text/html\n",
        'x-ctq'   => "title: X\napi: true\ncontent_type: \"text/html\"\n",
        'x-plain' => "title: X\napi: true\ncontent_type: text/html\n",
    );
    page( $d, $_, $pages{$_}, $js ) for keys %pages;
    for my $p ( sort keys %pages ) {
        my $out     = scalar run_processor( $d, "/$p" );
        my $verbatim = $out !~ /<!DOCTYPE html>/i;    # no layout around it
        ok( !( $verbatim && ct($out) =~ m{^\s*["']?\s*(?:text/html|application/xhtml\+xml|image/svg\+xml)}i ),
            "$p: not served verbatim as HTML" )
            or diag( 'Content-type: ' . ct($out) );
    }
    like( ct( scalar run_processor( $d, '/x-dq' ) ),  qr{^text/plain}, 'api: "true" + text/html is downgraded' );
    like( ct( scalar run_processor( $d, '/x-ctq' ) ), qr{^text/plain}, 'a quoted "text/html" is downgraded' );
    my $out = scalar run_processor( $d, '/x-next' );
    like( $out, qr/<!DOCTYPE html>/i, '`api:` with `true` below it is an ordinary page, through the layout' );
};

subtest 'the next key is the one the page renders' => sub {
    my $d = site_tempdir();
    setup_test_site($d);
    page( $d, 'n-sub', "title:\nsubtitle: Hello\n", "Body.\n" );
    my $out = scalar run_processor( $d, '/n-sub' );
    unlike( $out, qr{<title>[^<]*subtitle: Hello}, 'the empty title did not take the next line' );
};

done_testing;
