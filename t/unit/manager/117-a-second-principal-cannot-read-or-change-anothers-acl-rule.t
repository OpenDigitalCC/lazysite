#!/usr/bin/perl
# SM575: an ACL rule belongs to the principal who set it. THIS IS THE DECISION,
# not an accident of where a check happened to be written - and this file is
# what makes a future reader argue with the reason before removing it.
#
# WHY OWNERSHIP IS ENFORCED HERE AND NOWHERE ELSE IN THE FIVE STORES.
#
# Content, briefs and data tables are the SITE'S - one docroot, one set of
# pages, one database, shared by every principal the operator has issued (the
# sibling files t/unit/manager/113, t/unit/manager/114 and t/unit/data/26 pin
# that sharing, deliberately). An ACL record is the one thing in that list which
# is not a piece of the site: it is the statement of who may touch a piece of
# the site. A permission record that anyone holding manage_content may rewrite
# is not a permission record - the weakest principal on the estate could name
# itself owner of the strongest one's private section and read it, and every
# other gate in the engine would be working exactly as designed while that
# happened. So ownership here is not "the store that happens to check": it is
# the store where a shared answer would dissolve the other four.
#
# WHAT THE FIELD MEASURED (SM570, edge, 2026-08-25) and what this pins:
# a second principal issued by the operator was refused acl-get ("Not the owner
# of this file"), acl-set ("Only the owner may change permissions") and
# acl-remove ("Only the owner may remove permissions") on a rule another
# principal owned. Every one of those was measured by hand on a live site and
# held by nothing in the suite until this file.
#
# SABOTAGE-VERIFIED: with the three owner comparisons in
# lib/Lazysite/Manager/Files.pm relaxed to always match, in a scratch copy of
# the tree, every refusal assertion below fails.
#
# THE TWO CONTROLS matter as much as the refusals. Without them a build that
# refused EVERY acl call would look like a passing ownership test:
#   - alice may still read, change and remove HER OWN rule;
#   - mallory may still claim an UNGOVERNED path, because claiming the first
#     rule on a file needs write access to that file, not ownership of a rule
#     that does not yet exist. That is how ownership is acquired at all, and
#     narrowing it would make gated content unreachable for the principal who
#     wrote it.
#
# The site is SECURED on purpose (a group carries `ui`, so site_grants_manager
# is true). On an unsecured/dev site every authenticated user is an operator and
# the ownership question never arises - a rig that forgot this would assert
# nothing while appearing to pass.
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
use Lazysite::Manager::Files  qw(action_acl_get action_acl_set action_acl_remove);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/auth", "$d/intranet" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

open my $nf, '>', "$d/intranet/note.md" or die $!;
print {$nf} "---\ntitle: Note\n---\nOWNED-BY-ALICE\n";
close $nf;

# The two-principal rig the suite already has: real accounts through the real
# users tool, capabilities through a role group (TestHelper::grant_caps).
# `ui` on the groups is what makes this a SECURED site; NEITHER principal holds
# manage_users, so neither is an operator and ownership is the only thing
# separating them.
dav_users_tool( $d, 'add', 'alice',   'alice-pw-0123456789' );
dav_users_tool( $d, 'add', 'mallory', 'mallory-pw-0123456789' );
grant_caps( $d, 'alice',   qw(ui manage_content) );
grant_caps( $d, 'mallory', qw(ui manage_content) );

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::token_auth    = 0;

sub as_principal {
    my ( $user, $code ) = @_;
    local $Lazysite::Auth::Acl::auth_user      = $user;
    local $Lazysite::Manager::Files::auth_user = $user;
    return $code->();
}

subtest 'the rig is honest: neither principal is an operator' => sub {
    for my $u (qw(alice mallory)) {
        my $op = as_principal( $u, sub { Lazysite::Auth::Acl::_is_operator() } );
        ok( !$op, "$u is a plain principal, not an operator" )
            or diag( 'If this passed, the site is unsecured/dev and every '
                . 'refusal below would be vacuous.' );
    }
};

# alice governs her own file.
my $set = as_principal( 'alice',
    sub { action_acl_set( '/intranet/note.md', 'alice', 'alice', 'alice' ) } );
ok( $set->{ok}, 'alice sets a rule on her page' ) or diag explain $set;

subtest 'REFUSED: a second principal may not READ another principal\'s rule' => sub {
    my $r = as_principal( 'mallory',
        sub { action_acl_get( '/intranet/note.md', 'mallory' ) } );
    ok( !$r->{ok}, 'acl-get is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/Not the owner/i, 'and names ownership as the reason' );
};

subtest 'REFUSED: a second principal may not CHANGE another principal\'s rule' => sub {
    my $r = as_principal( 'mallory',
        sub { action_acl_set( '/intranet/note.md', 'mallory', 'mallory', 'mallory' ) } );
    ok( !$r->{ok}, 'acl-set is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/Only the owner may change permissions/i,
        'with the measured wording' );

    my $after = as_principal( 'alice',
        sub { action_acl_get( '/intranet/note.md', 'alice' ) } );
    is( $after->{acl}{owner}, 'alice', 'the owner is unchanged' );
    is_deeply( $after->{acl}{read}, ['alice'],
        'and the read list was not rewritten to the caller' );
};

subtest 'REFUSED: a second principal may not REMOVE another principal\'s rule' => sub {
    my $r = as_principal( 'mallory',
        sub { action_acl_remove( '/intranet/note.md', 'mallory' ) } );
    ok( !$r->{ok}, 'acl-remove is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/Only the owner may remove permissions/i,
        'with the measured wording' );

    my $after = as_principal( 'alice',
        sub { action_acl_get( '/intranet/note.md', 'alice' ) } );
    ok( $after->{acl}, 'the rule survives the attempt' );
};

subtest 'CONTROL: the owner still holds all three verbs on her own rule' => sub {
    my $g = as_principal( 'alice',
        sub { action_acl_get( '/intranet/note.md', 'alice' ) } );
    ok( $g->{ok}, 'alice reads her rule' ) or diag explain $g;

    my $s = as_principal( 'alice',
        sub {
            action_acl_set( '/intranet/note.md', 'alice', [qw(alice bob)], 'alice' );
        } );
    ok( $s->{ok}, 'alice widens her own read list' ) or diag explain $s;

    my $rm = as_principal( 'alice',
        sub { action_acl_remove( '/intranet/note.md', 'alice' ) } );
    ok( $rm->{ok},      'alice removes her own rule' ) or diag explain $rm;
    ok( $rm->{removed}, 'and it is gone' );
};

subtest 'CONTROL: an UNGOVERNED path may still be claimed by either principal' =>
    sub {
    my $r = as_principal( 'mallory',
        sub { action_acl_set( '/intranet/note.md', 'mallory', 'mallory', 'mallory' ) } );
    ok( $r->{ok}, 'with no rule in force, write access is enough to claim one' )
        or diag explain $r;
    my $back = as_principal( 'mallory',
        sub { action_acl_get( '/intranet/note.md', 'mallory' ) } );
    is( $back->{acl}{owner}, 'mallory',
        'ownership is ACQUIRED by claiming an ungoverned path, never taken from an owner' );

    my $undo =
        as_principal( 'mallory', sub { action_acl_remove( '/intranet/note.md', 'mallory' ) } );
    ok( $undo->{ok}, 'and released again' );
    };

subtest 'the SITE-WIDE rule is the same answer on its own code path' => sub {

    # acl-get and acl-remove branch separately for the root key (SM287/SM310),
    # so the root has to be asserted, not assumed - a check present on one
    # branch and absent on the other is exactly the drift this file exists for.
    my $s = as_principal( 'alice', sub { action_acl_set( '/', 'alice', 'alice', 'alice' ) } );
    ok( $s->{ok}, 'alice sets a site-wide rule' ) or diag explain $s;

    my $g = as_principal( 'mallory', sub { action_acl_get( '/', 'mallory' ) } );
    ok( !$g->{ok}, 'a second principal may not read it' ) or diag explain $g;
    like( $g->{error} // '', qr/Not the owner/i, 'same reason at the root' );

    my $rm = as_principal( 'mallory', sub { action_acl_remove( '/', 'mallory' ) } );
    ok( !$rm->{ok}, 'nor remove it' ) or diag explain $rm;
    like( $rm->{error} // '', qr/Only the owner may remove permissions/i,
        'same reason at the root' );

    my $still = as_principal( 'alice', sub { action_acl_get( '/', 'alice' ) } );
    is( $still->{acl}{owner}, 'alice', 'and the site-wide rule stands' );
};

done_testing();
