#!/usr/bin/perl
# SM575: a page belongs to the SITE, not to the principal who typed it. THIS IS
# THE DECISION - a deliberate permission, pinned here so that adding ownership
# to the content store is a change somebody has to argue for rather than one
# that slips in as an obvious improvement.
#
# WHY CONTENT IS SHARED. A lazysite site is one docroot with one set of pages,
# one navigation and one link graph. The pages are not separable possessions:
# an about page links to a contact page, a nav entry points at both, an alias
# redirects an old URL to a successor. If the principal who created a page were
# the only one who could edit it, then the ordinary operations of running a site
# - fixing a typo an agent left, retiring a page a departed partner wrote,
# reorganising a section - would each become a request to whoever happened to
# save the file first, and a site would silently accumulate pages nobody left
# on the estate can touch. That failure mode is worse than the one ownership
# would prevent, because it is PERMANENT and grows with time, whereas an
# unwanted edit is visible in the content history and restorable from it.
#
# The site is shared, so the CAPABILITY is the gate: manage_content is the
# operator's statement that this principal may write this site's content, and
# it means all of it. That is the same answer briefs and data tables give
# (t/unit/manager/114, t/unit/data/26); ACLs and themes are the two stores where
# the answer is different, and each of those says why in its own file.
#
# OWNERSHIP IS AVAILABLE, AS AN OPT-IN. The last subtest is the other half of
# the decision and the reason it is defensible: a per-file ACL is exactly how a
# principal says "this page is mine", and the moment one exists, the second
# principal is refused. Sharing is the DEFAULT, not the only setting - so a site
# that needs an owned section has a supported way to have one, and this file
# pins that route as well as the default.
#
# WHAT THE FIELD MEASURED (SM570, edge, 2026-08-25): a second principal holding
# manage_content wrote over and deleted another principal's page, with no
# refusal at any layer. Nothing in the suite held that, in either direction.
#
# THIS TEST PINS A DELIBERATE PERMISSION. It would FAIL if an ownership check
# were added to the content store: the two "MAY" subtests assert ok:1 from a
# non-author. Anyone making that change should come here first, read the
# reasoning above, and either rebut it or leave the store shared.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(dav_users_tool grant_caps);
use Lazysite::Manager::Files  qw(action_save action_read action_delete action_acl_set);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/auth", "$d/lazysite/locks", "$d/content" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# The same two-principal rig as t/unit/manager/112: real accounts, capabilities
# through a role group, `ui` making the site SECURED so that neither principal
# is treated as an operator. Both hold manage_content and nothing more - if the
# store gated on ownership, this is precisely the pair that would be separated.
dav_users_tool( $d, 'add', 'alice',   'alice-pw-0123456789' );
dav_users_tool( $d, 'add', 'mallory', 'mallory-pw-0123456789' );
grant_caps( $d, 'alice',   qw(ui manage_content) );
grant_caps( $d, 'mallory', qw(ui manage_content) );

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Files::LOCK_DIR = "$d/lazysite/locks";
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::token_auth    = 0;

sub as_principal {
    my ( $user, $code ) = @_;
    local $Lazysite::Auth::Acl::auth_user      = $user;
    local $Lazysite::Manager::Files::auth_user = $user;
    return $code->();
}

my $PAGE = '/content/launch.md';

subtest 'the rig is honest: neither principal is an operator' => sub {
    for my $u (qw(alice mallory)) {
        my $op = as_principal( $u, sub { Lazysite::Auth::Acl::_is_operator() } );
        ok( !$op, "$u is a plain principal, not an operator" )
            or diag( 'If this passed, an operator bypass - not the shared-store '
                . 'decision - would be what let the writes through.' );
    }
};

subtest 'alice writes the page' => sub {
    my $r = as_principal( 'alice',
        sub {
            action_save( $PAGE, 'alice', "---\ntitle: Launch\n---\nBY-ALICE\n" );
        } );
    ok( $r->{ok},                  'saved' ) or diag explain $r;
    ok( -f "$d/content/launch.md", 'and the file exists' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY overwrite it' => sub {
    my $r = as_principal( 'mallory',
        sub {
            action_save( $PAGE, 'mallory', "---\ntitle: Launch\n---\nBY-MALLORY\n" );
        } );
    ok( $r->{ok}, 'mallory saves over a page alice wrote' ) or diag explain $r;

    my $back = as_principal( 'alice', sub { action_read( $PAGE, 'alice' ) } );
    like( $back->{content}, qr/BY-MALLORY/,
        'and the site carries the second principal\'s text' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY delete it' => sub {
    my $r = as_principal( 'mallory', sub { action_delete( $PAGE, 'mallory' ) } );
    ok( $r->{ok}, 'mallory deletes a page alice created' ) or diag explain $r;
    ok( !-e "$d/content/launch.md", 'and it is gone' );
};

subtest 'the store keeps NO record of an author to check against' => sub {

    # Not just "the check is absent" but "there is nothing to check WITH". A
    # theme carries created_by and an ACL carries owner; a saved page carries
    # neither, which is what makes the sharing structural rather than an
    # oversight in one code path. If a future change adds such a field, this is
    # the assertion that will notice.
    as_principal( 'alice',
        sub { action_save( $PAGE, 'alice', "---\ntitle: Launch\n---\nBY-ALICE\n" ) } );
    open my $fh, '<', "$d/content/launch.md" or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    unlike( $raw, qr/^(?:created_by|owner|author):/m,
        'the saved page front matter records no owning principal' );

    my $acls = Lazysite::Auth::Acl::load_acls();
    is_deeply( $acls, {},
        'and saving a page writes no ACL record - an unclaimed page is unowned' );
};

subtest 'THE OPT-IN: an ACL is how a page becomes owned, and then it IS' => sub {

    # The other half of the decision. Sharing being the default is defensible
    # BECAUSE this route exists; without it the store would be shared with no
    # way to say otherwise, which is a different (and much weaker) position.
    my $claim = as_principal( 'alice',
        sub { action_acl_set( $PAGE, 'alice', 'alice', 'alice' ) } );
    ok( $claim->{ok}, 'alice claims the page with a per-file rule' )
        or diag explain $claim;

    my $w = as_principal( 'mallory',
        sub { action_save( $PAGE, 'mallory', "---\ntitle: X\n---\nBLOCKED\n" ) } );
    ok( !$w->{ok}, 'the second principal is now refused the write' ) or diag explain $w;
    is( $w->{kind} // '', 'permission', 'as a permission refusal' );

    my $del = as_principal( 'mallory', sub { action_delete( $PAGE, 'mallory' ) } );
    ok( !$del->{ok}, 'and refused the delete' ) or diag explain $del;

    my $back = as_principal( 'alice', sub { action_read( $PAGE, 'alice' ) } );
    like( $back->{content}, qr/BY-ALICE/, 'the claimed page is untouched' );
};

done_testing();
