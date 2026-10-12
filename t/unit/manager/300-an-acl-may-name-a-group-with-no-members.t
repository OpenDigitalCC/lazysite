#!/usr/bin/perl
# SM1045: an ACL naming a group that exists and has no members does not call it
# unknown.
#
# Reported from sites.lazysite.io (0.15.4): an operator created `editors`,
# `category-managers`, `commenters`, `account-approvers` and `feedback-readers`
# at /manager/groups, and acl-set listed every one of them under `unknown`
# with the warning "no group with that name" until each had a member - and a
# read list naming ONLY such groups was refused as naming nobody (SM901).
# group_names() read membership alone; it now reads both group stores.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(add_account grant_caps site_tempdir);
use Lazysite::Manager::Files  qw(action_acl_get action_acl_set);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

my $d = Cwd::realpath( site_tempdir() );
make_path( "$d/lazysite/auth", "$d/intranet" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
for my $n ( 1 .. 4 ) {
    open my $nf, '>', "$d/intranet/p$n.md" or die $!;
    print {$nf} "---\ntitle: P$n\n---\nbody\n";
    close $nf;
}

add_account( $d, 'alice' );
grant_caps( $d, 'alice', qw(ui manage_content) );

# The Groups page's record for a new group, with nobody in it: groups-settings
# names it, the groups file does not.
my @EMPTY = qw(editors category-managers commenters account-approvers feedback-readers);
TestHelper::_gc_set_caps( $d, $_, {} ) for @EMPTY;

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::token_auth    = 0;
local $Lazysite::Auth::Acl::auth_user      = 'alice';
local $Lazysite::Manager::Files::auth_user = 'alice';

sub set_read { my ( $p, $l ) = @_; action_acl_set( $p, 'alice', $l, undef ) }
sub rule { my ($p) = @_; my $g = action_acl_get( $p, 'alice' ); $g->{ok} ? $g->{acl} : undef }

subtest 'the reported case: every empty group in a read list' => sub {
    my $r = set_read( '/intranet/p1.md', [ map { "\@$_" } @EMPTY ] );
    ok( $r->{ok},                                     'accepted' ) or diag explain $r;
    ok( !( ref $r->{unknown} && @{ $r->{unknown} } ), 'nothing listed as unknown' )
        or diag explain $r->{unknown};
    unlike( join( ' ', @{ $r->{warnings} || [] } ), qr/no group with that name/,
        'and no warning calls them missing' );
    is_deeply( [ sort @{ ( rule('/intranet/p1.md') || {} )->{read} || [] } ],
        [ sort map { "\@$_" } @EMPTY ], 'stored as written' );
};

subtest 'an empty group beside a member-holding one' => sub {
    my $r = set_read( '/intranet/p2.md', [ '@editors', '@role-alice' ] );
    ok( $r->{ok},                                     'accepted' ) or diag explain $r;
    ok( !( ref $r->{unknown} && @{ $r->{unknown} } ), 'nothing unknown' );
};

subtest 'a name in neither store is still unknown' => sub {
    my $r = set_read( '/intranet/p3.md', [ '@editors', '@editers' ] );
    ok( $r->{ok}, 'accepted, one real group named' ) or diag explain $r;
    is_deeply( $r->{unknown}, ['@editers'], 'the misspelling is named' );
    like( join( ' ', @{ $r->{warnings} || [] } ), qr/\@editers/, 'and warned about' );

    my $none = set_read( '/intranet/p4.md', ['@editers'] );
    ok( !$none->{ok}, 'a list naming only a group in neither store is refused' );
    is( $none->{kind}, 'unknown-principals', '...as naming nobody' );
};

# The store-empty guard (SM901/SM912 P4) is unchanged: a site whose only group
# store is the seeded groups-settings.json - no accounts, nobody in any group,
# as on a site behind an upstream proxy - keeps no principals to check against,
# so a rule is stored unchecked and nothing is refused.
subtest 'a seeded group store alone does not make names checkable' => sub {
    my $p = Cwd::realpath( site_tempdir() );
    make_path( "$p/lazysite/auth", "$p/intranet" );
    open my $pc, '>', "$p/lazysite/lazysite.conf" or die $!;
    print {$pc} "site_name: P\n";
    close $pc;
    open my $pf, '>', "$p/intranet/q.md" or die $!;
    print {$pf} "---\ntitle: Q\n---\nbody\n";
    close $pf;
    TestHelper::_gc_set_caps( $p, 'managers', { ui => 1, manage_users => 1 } );
    local $Lazysite::Manager::Common::DOCROOT = $p;
    local $Lazysite::Manager::Files::DOCROOT  = $p;
    local $Lazysite::Auth::Acl::DOCROOT       = $p;
    my $r = set_read( '/intranet/q.md', ['carol'] );
    ok( $r->{ok}, 'a login the site cannot check is stored' ) or diag explain $r;
    ok( $r->{principals_unchecked}, '...and the result says it was not checked' ) or diag explain $r;
};

done_testing;
