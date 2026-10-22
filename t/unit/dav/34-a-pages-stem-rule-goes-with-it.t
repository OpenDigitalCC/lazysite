#!/usr/bin/perl
# SM1257 and SM1258: over WebDAV, a page's rule keyed by its STEM goes with the
# page. set_permissions on "/content/about" stores `content/about`, which holds
# content/about.md back (a folder's rule covers its landing page).
#
#   DELETE (SM1258)  dropped the page's own key only; the stem rule waited for
#                    the next page written there, born a draft nobody set.
#   MOVE   (SM1257)  re-keyed the page's own key only; the draft stayed behind
#                    and the moved page was published at its new path.
#
# Both now fold the stem rule into the page's own key first, by the one rule the
# manager uses (Acl::fold_page_stem): only while no folder of that name exists.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);
use Lazysite::Auth::Acl ();

sub dest { "http://host/dav$_[0]" }

sub acls {
    my ($s) = @_;
    open my $f, '<', "$s->{docroot}/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = <$f>;
    close $f;
    return decode_json( $j || '{}' );
}

sub set_acls {
    my ( $s, $h ) = @_;
    open my $f, '>', "$s->{docroot}/lazysite/auth/acls.json" or die $!;
    print $f encode_json($h);
    close $f;
}

subtest 'SM1258: DELETE takes the stem rule with the page' => sub {
    my $s = setup_dav_site();
    is( run_dav( $s->{docroot}, 'PUT', '/content/about.md', body => "A\n", HTTP_AUTHORIZATION => $s->{auth} )->{code},
        201, 'the page is written' );
    set_acls( $s, { 'content/about' => { owner => 'deploy', draft => JSON::PP::true() } } );
    my $r = run_dav( $s->{docroot}, 'DELETE', '/content/about.md', HTTP_AUTHORIZATION => $s->{auth} );
    ok( $r->{code} == 204 || $r->{code} == 200, 'deleted' ) or diag explain $r;
    ok( !exists acls($s)->{'content/about'}, 'THE STEM RULE IS GONE TOO' );
};

subtest 'SM1258: a folder\'s stem rule stays when its landing page is deleted' => sub {
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/sect.md', body => "L\n", HTTP_AUTHORIZATION => $s->{auth} );
    make_path("$s->{docroot}/content/sect");
    set_acls( $s, { 'content/sect' => { owner => 'deploy', draft => JSON::PP::true() } } );
    run_dav( $s->{docroot}, 'DELETE', '/content/sect.md', HTTP_AUTHORIZATION => $s->{auth} );
    ok( exists acls($s)->{'content/sect'}, 'the folder\'s rule stays' );
};

subtest 'SM1257: MOVE keeps a stem-drafted page a draft' => sub {
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/about.md', body => "A\n", HTTP_AUTHORIZATION => $s->{auth} );
    set_acls( $s, { 'content/about' => { owner => 'deploy', draft => JSON::PP::true() } } );
    my $r = run_dav( $s->{docroot}, 'MOVE', '/content/about.md',
        HTTP_DESTINATION => dest('/content/other.md'), HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 201, 'moved' ) or diag explain $r;
    ok( defined Lazysite::Auth::Acl::governing_key( $s->{docroot}, 'content/other.md', 'draft' ),
        'THE MOVED PAGE IS STILL A DRAFT' )
        or diag( 'The stem rule stayed at content/about and content/other.md was published.' );
    ok( !exists acls($s)->{'content/about'}, 'and no rule is left at the old stem' );
};

done_testing;
