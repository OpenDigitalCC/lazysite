#!/usr/bin/perl
# SM775, from 131E-05 on 0.13.6. Three complaints, one cause: the manager knew
# what an account could open and did not act on it in three places.
#
#   1. `/manager/` redirected to `/manager/config` unconditionally, so an
#      account without manage_config arrived at a heading and an empty body.
#   2. Nothing said why it was empty - the page renders, its reader is
#      refused, and the refusal went to a dismissible warning bar.
#   3. The nav's locked marker was gated on `manager_caps.manage_users`, so
#      only an account that could GRANT a capability was shown the page it was
#      missing. For everyone else the item simply vanished, and a menu that
#      silently differs per account reads as a manager that has lost a feature.
#
# All three are rendered output, so all three are asserted by RENDERING - the
# lesson of SM686/SM689/SM697, each of which was correct in source and wrong in
# the browser because nobody looked at the rendering.
use strict;
use warnings;
use Test::More;
use Template;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                   qw(repo_root);
use Lazysite::Manager::StartPage ();

my $root = repo_root();

sub render {
    my ( $file, $caps ) = @_;
    my $src = do { open my $fh, '<', "$root/$file" or die "$file: $!"; local $/; <$fh> };
    my $t   = Template->new( EVAL_PERL => 0 ) or die Template->error;
    my $out = '';
    $t->process( \$src,
        { manager_caps => $caps, request_uri => '/manager/', enabled_plugins => {},
            content => '', page_title => '', auth_user => 'u', query => {} },
        \$out ) or die "$file: " . $t->error;
    return $out;
}
sub nav_of { my ($h) = @_; my ($n) = $h =~ /(<nav class="mg-nav".*?<\/nav>)/s; return $n // '' }

subtest 'the index does not send an account to a page it cannot read' => sub {
    my $with = render( 'starter/manager/index.md', { manage_config => 1 } );
    like( $with, qr{location\.replace\('/manager/config'},
        'an account holding Configuration is still forwarded to the settings page' );

    my $without = render( 'starter/manager/index.md', {} );
    unlike( $without, qr{location\.replace},
        'an account without it is NOT forwarded - that was the empty page' );
    like( $without, qr/mgOpenAccount/,
        'it lands on its own account sheet instead, where a sign-in with no '
            . 'destination already lands (SM724), so the two arrivals agree' );
    like( $without, qr/Configuration/,
        'and the page names the capability rather than showing nothing' );
};

subtest 'a page whose reader cannot read it says so, naming the capability' => sub {
    my $without = render( 'starter/manager/config.md', {} );
    like( $without, qr/mg-note/, 'the refusal is in the page body, not only a warning bar' );
    like( $without, qr/Configuration/, 'and names the capability' );
    unlike( $without, qr/action=config-read/,
        'and the page does not ask for what it already knows it will be refused' );

    my $with = render( 'starter/manager/config.md', { manage_config => 1 } );
    like( $with, qr/action=config-read/, 'while the holder gets the page it always had' );
};

# The heart of it: ONE answer to "what can this account open". The nav is
# rendered for a capability set and compared against _page_reachable, the same
# answer the start-page dropdown uses.
subtest 'the nav marks what the account cannot reach - for EVERY account' => sub {
    my %GATED = (
        files      => 'manage_content',
        nav        => 'manage_nav',
        appearance => 'manage_themes',
        domains    => 'manage_domains',
        audit      => 'audit',
    );

    for my $case ( [ 'an account holding nothing', {} ],
        [ 'a user manager',   { manage_users   => 1 } ],
        [ 'a content editor', { manage_content => 1 } ] )
    {
        my ( $name, $caps ) = @$case;
        my $nav = nav_of( render( 'starter/lazysite/manager/layout.tt', $caps ) );
        for my $page ( sort keys %GATED ) {
            my $held      = $caps->{ $GATED{$page} } ? 1 : 0;
            my $reachable = Lazysite::Manager::StartPage::_page_reachable(
                $page, { %{$caps}, ui => 1 } );
            is( $reachable, $held, "$name: _page_reachable agrees about $page" );

            # The marked item carries the page's LABEL, whichever element it is.
            my $label  = $Lazysite::Manager::StartPage::PAGES{$page}{label};
            my $marked = $nav =~ /mg-nav-locked[^>]*>\s*\Q$label\E/ ? 1 : 0;
            is( $marked, $held ? 0 : 1,
                "$name: $page is " . ( $held ? 'a link' : 'marked' ) );
        }
    }
};

subtest 'the marker is a class, and the style guide is the contract' => sub {
    my $tt = do {
        open my $fh, '<', "$root/starter/lazysite/manager/layout.tt" or die $!;
        local $/;
        <$fh>;
    };
    my $nav = ( $tt =~ /(<nav class="mg-nav".*?<\/nav>)/s )[0];
    unlike( $nav, qr/style="/,
        'no inline style survives in the nav - six copies of '
            . 'opacity:0.55;font-style:italic is what the guide exists to stop' );

    my $guide = do {
        open my $fh, '<', "$root/starter/manager/style-guide.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $guide, qr/mg-nav-locked/, 'the locked item is registered in the guide' );
    like( $guide, qr/mg-nav-lock\b/, 'and so is its marker' );

    # SM686: a title attribute alone is mouse-only, so the marker is focusable
    # and labelled - the shape the guide already registers for a hint marker.
    like( $nav, qr/class="mg-nav-lock" tabindex="0" role="img" aria-label=/,
        'the marker is reachable and labelled, not a mouse-only tooltip' );
};

subtest 'a locked item points somewhere the reader can act, or nowhere' => sub {
    my $mgr = nav_of( render( 'starter/lazysite/manager/layout.tt', { manage_users => 1 } ) );
    like( $mgr, qr/<a href="\/manager\/groups" class="mg-nav-locked"[^>]*grant/,
        'a user manager is sent to the page where the capability is granted' );

    my $plain = nav_of( render( 'starter/lazysite/manager/layout.tt', {} ) );
    unlike( $plain, qr/<a href="\/manager\/groups" class="mg-nav-locked"/,
        'an account that cannot grant is NOT offered a link it can do nothing with' );
    like( $plain, qr/<span class="mg-nav-locked"[^>]*does not hold/,
        'it is told the account does not hold the capability, and that is all' );
};

done_testing;
