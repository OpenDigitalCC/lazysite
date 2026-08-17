#!/usr/bin/perl
# SM337: activating a layout that cannot render the site reported success.
#
# WHAT WAS MEASURED, building a real site rather than testing one. Three layouts
# activated in sequence against a site whose navigation was
# `Home / Services / Work / Contact`:
#
#   atelier      rendered Works, About, Explorer
#   consultancy  rendered "Meridian & Co", Services, Approach, Book a briefing
#   lumen        rendered Lumen., Features, Voices, The essay
#
# None rendered the site's own navigation. `consultancy` renders a fictional
# company name on whatever site activates it. A later survey put numbers on it:
# ONE of the 23 catalogue layouts renders `[% nav %]`, and on the instrument 1
# of 11 configured navigation destinations reached a page (SM349).
#
# EVERY SIGNAL SAID IT WORKED. install_layout ok:1, activate_layout ok:1,
# nav-save ok:1 reporting the cache entries it cleared, nav-read returning the
# saved items, and the page 200. The navigation was simply absent - and the only
# way to find out was to install, bind, render and look, which is a step nobody
# inserts after four consecutive successes.
#
# THIS DOES NOT REFUSE ANYTHING, deliberately. A showcase layout is a legitimate
# thing to activate and the caller may want exactly that. What changes is that
# the acknowledgement stops being indistinguishable from binding a layout that
# can carry a site.
#
# SM362 rides along on the same read: the engine resolves `page_meta_title` and
# `page_meta_desc` for a layout to use and every catalogue layout overwrites
# them, so those are reported too rather than needing a second survey.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site repo_root);
use lib repo_root() . '/lib';

require Lazysite::Manager::Themes;

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
# The module reads its tree through LAZYSITE_DIR, not DOCROOT - setting the
# wrong one made every activation return "Layout not found", which reads as a
# product defect and was a fixture pointing at nothing.
$Lazysite::Manager::Themes::DOCROOT      = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$docroot/lazysite";

# And an identity, or acquire_lock reports the layout as "locked by another
# session" - a refusal that looks like contention and is an unset caller.
$Lazysite::Manager::Themes::auth_user = 'tester';

# And a lock directory. $LOCK_DIR is package context the dispatcher sets per
# request; unset, acquire_lock reports "locked by another session" - which reads
# as contention and is an unconfigured fixture. Worth knowing: that message
# cannot distinguish the two.
require Lazysite::Manager::Files;
$Lazysite::Manager::Files::DOCROOT  = $docroot;
$Lazysite::Manager::Files::LOCK_DIR = "$docroot/lazysite/locks";

# Write a layout with a chosen body, so what it renders is the thing under test.
sub layout {
    my ( $name, $body ) = @_;
    my $dir = "$docroot/lazysite/layouts/$name";
    make_path($dir);
    open my $fh, '>', "$dir/layout.tt" or die $!;
    print $fh $body;
    close $fh;
    open my $j, '>', "$dir/layout.json" or die $!;
    print $j qq({"name":"$name","version":"1.0"}\n);
    close $j;
    return $dir;
}

sub renders_of {
    my ($dir) = @_;
    my $v = Lazysite::Manager::Themes::_validate_layout_dir($dir);
    return $v->{renders} || {};
}

subtest 'a site layout is reported as rendering the site' => sub {
    my $dir = layout( 'kestrel', <<'TT' );
<html><head><title>[% page_meta_title %]</title>
<meta name="description" content="[% page_meta_desc %]"></head>
<body>[% nav %]<main>[% content %]</main></body></html>
TT
    my $r = renders_of($dir);
    is( $r->{nav},        1, 'it renders the navigation' );
    is( $r->{content},    1, 'and the page body' );
    is( $r->{meta_title}, 1, 'and the resolved meta title' );
    is( $r->{meta_desc},  1, 'and the resolved meta description' );
};

subtest 'a showcase layout is reported as NOT rendering it' => sub {
    # The catalogue shape: hard-coded links belonging to the gallery it was
    # built for, and the page body present - which is why this was so hard to
    # see. The content renders; only the navigation is somebody else's.
    my $dir = layout( 'atelier', <<'TT' );
<html><body>
<nav><a href="#works">Works</a> <a href="#about">About</a></nav>
<main>[% content %]</main></body></html>
TT
    my $r = renders_of($dir);
    is( $r->{nav}, 0, 'no navigation' )
        or diag( 'A layout with hard-coded links renders SOMETHING that looks '
            . 'like a menu, which is why installing it and looking at the page '
            . 'was not enough to notice.' );
    is( $r->{content},    1, 'but the body is there - the content was never lost' );
    is( $r->{meta_title}, 0, 'and the resolved meta title is discarded (SM362)' );
};

subtest 'the directive is matched however it is written' => sub {
    # A layout that filters the navigation still renders it. Matching the exact
    # string `[% nav %]` would report a working layout as broken, and a warning
    # that fires on correct layouts is one people learn to ignore.
    for my $form ( '[%nav%]', '[% nav %]', '[%- nav -%]', '[% nav | trim %]' ) {
        my $dir = layout( 'form', "<html><body>$form [% content %]</body></html>" );
        is( renders_of($dir)->{nav}, 1, "'$form' counts as rendering the nav" );
    }
};

subtest 'activation says what it bound, and warns without refusing' => sub {
    layout( 'showcase', '<html><body><nav>Demo</nav>[% content %]</body></html>' );
    my $res = Lazysite::Manager::Themes::action_layout_activate('showcase');

    ok( $res->{ok}, 'a showcase layout still activates - this is not a refusal' )
        or diag( 'Refusing would be wrong: activating a showcase is a '
            . 'legitimate choice, and a tool that refuses legitimate choices '
            . 'gets worked around.' );
    is( $res->{renders}{nav}, 0, 'and the response says it renders no nav' );
    like( $res->{warning}, qr/nav\.conf will have no effect/,
        'with a warning naming the consequence, not just the absence' )
        or diag( 'The operator does not need to be told a directive is missing. '
            . 'They need to be told their navigation will not appear.' );
};

subtest 'a working layout activates without a warning' => sub {
    # The other direction. A warning that fires on a correct layout is noise,
    # and noise is what taught everyone to ignore the four ok:1 responses.
    layout( 'proper', '<html><body>[% nav %][% content %]</body></html>' );
    my $res = Lazysite::Manager::Themes::action_layout_activate('proper');
    ok( $res->{ok}, 'it activates' );
    is( $res->{renders}{nav}, 1, 'reported as rendering the nav' );
    ok( !$res->{warning}, 'and carries no warning' );
};

done_testing();
