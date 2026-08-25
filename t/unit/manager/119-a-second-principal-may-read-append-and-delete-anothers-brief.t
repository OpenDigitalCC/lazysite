#!/usr/bin/perl
# SM575: a brief belongs to the FILE, not to the principal who wrote an entry
# in it. THIS IS THE DECISION - a deliberate permission, pinned here so that
# adding ownership to the brief store is a change somebody has to argue for.
#
# WHY BRIEFS ARE SHARED. A brief is the record of intent for one content path -
# what the page is for, what was decided about it, what not to undo. It exists
# precisely so that the NEXT person to touch that page can read why it looks the
# way it does, and the next person is by definition not the person who wrote the
# entry. An owned brief would be readable only by the principal who least needs
# it. Worse, the store is keyed by content path and its entries are carried by
# every move and delete of that path (SM507): the record follows the FILE
# through renames and through the departure of whoever created it, so tying it
# to an author would strand exactly the entries a site most needs - the ones
# left behind by an agent or partner no longer on the estate. The lifecycle
# SM508 completed (list, then delete) exists to CLEAR that debris; ownership
# would make the orphans undeletable, which is the gap SM508 closed reopening
# under a different name.
#
# WHAT PRESERVES ACCOUNTABILITY INSTEAD. The store is append-only and every
# entry carries its own date and actor, stamped at append time from the
# authenticated principal. So a shared brief does not lose track of who said
# what - it records it per line rather than per file, which is the correct
# granularity for a document several principals contribute to. The middle
# subtest asserts that stamping directly: if attribution were dropped, the
# sharing decision would lose its justification, and this test would fail.
#
# This is the same answer content and data tables give (t/unit/manager/113,
# t/unit/data/26). ACLs and themes are the two stores where the answer differs;
# each says why in its own file.
#
# WHAT THE FIELD MEASURED: SM575 recorded the brief store as UNVERIFIED - SM508
# and SM515 shipped list and delete behind a capability gate and nothing had
# ever asked whether one partner could delete another partner's brief. The
# answer, measured here, is that it can, and this file makes that an answer
# rather than an absence.
#
# THIS TEST PINS A DELIBERATE PERMISSION. It would FAIL if an ownership check
# were added to the brief store: three subtests assert ok:1 from a principal who
# wrote nothing in the brief they are reading, extending and removing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(dav_users_tool grant_caps);
use Lazysite::Manager::Briefs
    qw(action_brief_read action_brief_append action_briefs_list action_brief_delete);
use Lazysite::Manager::Common ();

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/auth", "$d/content" );

# The briefs plugin owns these actions and gates every one of them on being
# enabled (ADR 0009 / SM469), so the rig has to enable it or the whole file
# would assert nothing but "the plugin is off".
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/briefs.pl\n";
close $cf;

open my $pf, '>', "$d/content/launch.md" or die $!;
print {$pf} "---\ntitle: Launch\n---\nbody\n";
close $pf;

# The same two-principal rig as t/unit/manager/112 and 113: real accounts,
# capabilities through a role group, `ui` making the site SECURED. Both hold
# manage_content and nothing more.
dav_users_tool( $d, 'add', 'alice',   'alice-pw-0123456789' );
dav_users_tool( $d, 'add', 'mallory', 'mallory-pw-0123456789' );
grant_caps( $d, 'alice',   qw(ui manage_content) );
grant_caps( $d, 'mallory', qw(ui manage_content) );

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Briefs::DOCROOT = $d;

sub as_principal {
    my ( $user, $code ) = @_;
    local $Lazysite::Manager::Briefs::auth_user = $user;
    return $code->();
}

my $PAGE = '/content/launch.md';

subtest 'alice records the intent behind her page' => sub {
    my $r = as_principal( 'alice',
        sub { action_brief_append( $PAGE, 'ALICE-INTENT: keep the hero copy short' ) } );
    ok( $r->{ok}, 'appended' ) or diag explain $r;
    ok( -f "$d/lazysite/briefs/content/launch.md",
        'held under lazysite/, engine-owned and never served' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY read it' => sub {
    my $r = as_principal( 'mallory', sub { action_brief_read($PAGE) } );
    ok( $r->{ok} && $r->{exists}, 'mallory reads a brief alice wrote' )
        or diag explain $r;
    like( $r->{brief}, qr/ALICE-INTENT/,
        'and gets the intent - which is the entire purpose of writing one down' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY append to it' => sub {
    my $r = as_principal( 'mallory',
        sub { action_brief_append( $PAGE, 'MALLORY-NOTE: shortened it, kept the CTA' ) } );
    ok( $r->{ok}, 'mallory extends alice\'s brief' ) or diag explain $r;
};

subtest 'ACCOUNTABILITY: attribution is per ENTRY, which is what makes sharing safe' =>
    sub {
    my $r = as_principal( 'mallory', sub { action_brief_read($PAGE) } );
    like( $r->{brief}, qr/alice \x{b7} ALICE-INTENT/,
        'alice\'s entry is stamped alice' );
    like( $r->{brief}, qr/mallory \x{b7} MALLORY-NOTE/,
        'mallory\'s entry is stamped mallory' );
    like( $r->{brief}, qr/^- \d{4}-\d{2}-\d{2} \x{b7} alice \x{b7} /m,
        'each entry carries its own date and actor' );

    # The store is APPEND-ONLY: a second principal contributing did not rewrite
    # or displace the first principal's line. Sharing without this would be
    # sharing that loses the record.
    like( $r->{brief}, qr/ALICE-INTENT.*MALLORY-NOTE/s,
        'both entries survive, in the order they were written' );
    };

subtest 'PERMITTED BY DESIGN: a second principal MAY list and delete it' => sub {
    my $l = as_principal( 'mallory', sub { action_briefs_list() } );
    ok( $l->{ok}, 'mallory lists the store' ) or diag explain $l;
    is_deeply( [ map { $_->{path} } @{ $l->{briefs} } ],
        ['/content/launch.md'], 'and sees an entry she did not open' );

    my $del = as_principal( 'mallory', sub { action_brief_delete($PAGE) } );
    ok( $del->{ok} && $del->{deleted}, 'mallory deletes it' ) or diag explain $del;
    ok( !-e "$d/lazysite/briefs/content/launch.md", 'and it is gone' );

    # SM508's reason, restated as an assertion: the entries that most need
    # deleting are precisely the ones whose author has gone.
    my $after = as_principal( 'alice', sub { action_brief_read($PAGE) } );
    ok( $after->{ok} && !$after->{exists},
        'the store honestly reports no entry rather than a stale one' );
};

subtest 'the store keeps NO owner to check against' => sub {

    # Structural, not an omission in one code path: a theme carries created_by
    # and an ACL carries owner; a brief carries a per-line actor and nothing
    # file-level. If a future change adds an owning field, this notices.
    as_principal( 'alice', sub { action_brief_append( $PAGE, 'second life' ) } );
    open my $fh, '<:utf8', "$d/lazysite/briefs/content/launch.md" or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    unlike( $raw, qr/^(?:owner|created_by):/m,
        'the brief file records no owning principal' );
    like( $raw, qr/\A\# Brief - content\/launch\.md/,
        'only the content path it belongs to - the brief follows the FILE' );
};

done_testing();
