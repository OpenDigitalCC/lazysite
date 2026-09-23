#!/usr/bin/perl
# SM901: a read or write list is checked against the store. Names that do not
# exist are REPORTED; a list that resolves to nobody is REFUSED.
#
# From the 0.14.4 W5b re-walk on edge: {"read":["agent-ai","edge-testing"]} -
# two GROUP names written without the @ - was accepted with ok:true and no
# remark, and a signed-in member of edge-testing got Forbidden. action_acl_set
# took the list through _to_list, which drops only empty strings, and wrote it;
# _acl_allows later read each bare name as a LOGIN. The rule was "owner, and
# nobody", silently. The manager's picker (SM305) cannot make this mistake;
# the typed surfaces - control API, MCP set_permissions, `lazysite acl` - can.
#
# THE RULING (release manager, 2026-09-23): keep ok:true, carry `unknown`, and
# refuse only a list that resolves to nobody at all. A login that will exist
# tomorrow is a legitimate thing to write today; a list that reads to nobody
# can only be a mistake.
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
for my $n ( 1 .. 6 ) {
    open my $nf, '>', "$d/intranet/p$n.md" or die $!;
    print {$nf} "---\ntitle: P$n\n---\nbody\n";
    close $nf;
}

# Two REAL accounts (a line in auth/users) and one REAL group: grant_caps puts
# alice in `role-alice`, so `@role-alice` is a group the store knows.
add_account( $d, 'alice' );
add_account( $d, 'bob' );
grant_caps( $d, 'alice', qw(ui manage_content) );

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::token_auth    = 0;
local $Lazysite::Auth::Acl::auth_user      = 'alice';
local $Lazysite::Manager::Files::auth_user = 'alice';

sub set_read  { my ( $p, $l ) = @_; action_acl_set( $p, 'alice', $l,    undef ) }
sub set_write { my ( $p, $l ) = @_; action_acl_set( $p, 'alice', undef, $l ) }
sub rule { my ($p) = @_; my $g = action_acl_get( $p, 'alice' ); $g->{ok} ? $g->{acl} : undef }

subtest 'the measured case: two group names without the @ - REFUSED, naming them' => sub {
    my $r = set_read( '/intranet/p1.md', [ 'agent-ai', 'edge-testing' ] );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'unknown-principals', 'with its own kind' );
    like( $r->{error}, qr/agent-ai/,     'naming the first' );
    like( $r->{error}, qr/edge-testing/, 'and the second' );
    like( $r->{error}, qr/\@/,           'and saying how a group is spelt' );
    is_deeply( $r->{unknown}, [ 'agent-ai', 'edge-testing' ], 'the unknown list is on the result' );
    ok( !rule('/intranet/p1.md'), 'and NOTHING was written' )
        or diag('A rule that reads to nobody, stored, is the whole of the defect.');
};

subtest 'a real group, spelt as one - accepted, nothing unknown' => sub {
    my $r = set_read( '/intranet/p2.md', ['@role-alice'] );
    ok( $r->{ok},                                     'accepted' ) or diag explain $r;
    ok( !( ref $r->{unknown} && @{ $r->{unknown} } ), 'no unknown names' );
    is_deeply( rule('/intranet/p2.md')->{read}, ['@role-alice'], 'and stored' );
};

subtest 'a real login beside a future one - accepted, and the future one is NAMED' => sub {
    # A login that will exist tomorrow is a legitimate thing to write today:
    # provisioning scripts set rules before they create the accounts.
    my $r = set_read( '/intranet/p3.md', [ 'bob', 'carol-not-yet' ] );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    is_deeply( $r->{unknown}, ['carol-not-yet'], 'the name the store does not know is reported' );
    ok( ( grep { /carol-not-yet/ } @{ $r->{warnings} || [] } ),
        'and it is in the warnings too, so the CLI prints it and a reader of the JSON sees it' )
        or diag explain $r->{warnings};
    is_deeply( rule('/intranet/p3.md')->{read}, [ 'bob', 'carol-not-yet' ], 'both stored, as written' );
};

subtest 'a group that does not exist, alone - REFUSED' => sub {
    my $r = set_read( '/intranet/p4.md', ['@nosuchgroup'] );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is_deeply( $r->{unknown}, ['@nosuchgroup'], 'naming it' );
    ok( !rule('/intranet/p4.md'), 'nothing written' );
};

subtest 'the same rule on the WRITE list' => sub {
    my $r = set_write( '/intranet/p5.md', ['nobody-here'] );
    ok( !$r->{ok}, 'a write list naming nobody is refused' ) or diag explain $r;
    like( $r->{error}, qr/write/, 'and the refusal says which list' );
    my $ok = set_write( '/intranet/p6.md', [ 'alice', 'dave-later' ] );
    ok( $ok->{ok}, 'a write list with one real login is accepted' ) or diag explain $ok;
    is_deeply( $ok->{unknown}, ['dave-later'], 'with the future one named' );
};

subtest 'an EMPTY list is not "nobody" - it is no restriction, and stays accepted' => sub {
    # _acl_allows: an empty list means no restriction. Refusing it would turn
    # "clear the read list" into an error.
    my $r = action_acl_set( '/intranet/p2.md', 'alice', [], undef );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
};

subtest 'a site with NO accounts and NO groups checks nothing - there is nothing to check against' => sub {
    # An unsecured dev site, or a site being provisioned before its first
    # account: refusing every rule there would make a rule impossible to write
    # before an account exists. Nothing known means nothing checked.
    my $e = Cwd::realpath( site_tempdir() );
    make_path( "$e/lazysite/auth", "$e/intranet" );
    open my $ec, '>', "$e/lazysite/lazysite.conf" or die $!;
    print {$ec} "site_name: E\n";
    close $ec;
    open my $ep, '>', "$e/intranet/q.md" or die $!;
    print {$ep} "---\ntitle: Q\n---\nbody\n";
    close $ep;
    local $Lazysite::Manager::Common::DOCROOT = $e;
    local $Lazysite::Manager::Files::DOCROOT  = $e;
    local $Lazysite::Auth::Acl::DOCROOT       = $e;
    my $r = action_acl_set( '/intranet/q.md', 'alice', [ 'agent-ai', 'edge-testing' ], undef );
    ok( $r->{ok},              'accepted' ) or diag explain $r;
    ok( !exists $r->{unknown}, 'and nothing reported unknown - the store cannot say' );
};

done_testing();
