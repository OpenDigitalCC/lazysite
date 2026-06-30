#!/usr/bin/perl
# SM073: .brief sidecars are writable over WebDAV (content + layouts),
# exactly like the file they accompany - a brief is not a blocked
# extension or path. Public serving is denied elsewhere (Apache /
# dev server / processor); here we prove the authoring channel works.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav dav_users_tool grant_caps revoke_caps);

# --- a .brief writes and reads back in the content scope ---------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};

    my $put = run_dav( $s->{docroot}, 'PUT', '/content/about.md.brief',
        body => "# Brief - about.md\nintent: the about page\n",
        HTTP_AUTHORIZATION => $a );
    is( $put->{code}, 201, '.brief PUT (new) => 201, not blocked' );

    my $get = run_dav( $s->{docroot}, 'GET', '/content/about.md.brief',
        HTTP_AUTHORIZATION => $a );
    is( $get->{code}, 200, '.brief GET over dav => 200 (agent reads its own brief)' );
    like( $get->{body}, qr/intent: the about page/, 'brief content round-trips' );

    # append-only edit (overwrite with an extra log line) succeeds
    my $ovr = run_dav( $s->{docroot}, 'PUT', '/content/about.md.brief',
        body => "# Brief - about.md\nintent: the about page\n\n## Log\n- edited\n",
        HTTP_AUTHORIZATION => $a );
    is( $ovr->{code}, 204, '.brief overwrite => 204' );
}

# --- a .brief is writable under a (non-active) theme, with manage_themes ---
{
    my $s = setup_dav_site();
    grant_caps( $s->{docroot}, $s->{user}, 'manage_themes' );
    make_path("$s->{docroot}/lazysite/layouts/draft/themes/dark");
    my $a = $s->{auth};

    my $put = run_dav( $s->{docroot}, 'PUT',
        '/lazysite/layouts/draft/themes/dark/main.css.brief',
        body => "intent: the dark theme palette\n", HTTP_AUTHORIZATION => $a );
    is( $put->{code}, 201,
        '.brief writable under lazysite/layouts/ themes with manage_themes' );
}

done_testing();
