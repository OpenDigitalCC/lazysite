#!/usr/bin/perl
# P4 (WORK-PLAN-0154): approving an account request asks the users tool for one
# field, not every account's full detail.
#
# action_form_submission_approve checked that the name and address were free by
# asking for `users-detail`, which derives every account's effective settings -
# 42.8 s for 695 accounts on the reporting site, so the browser's request gave
# up first. It now asks for `fields => ['email']`, which the tool answers from
# the settings store in one read (t/unit/users/50). Driven here through the real
# action with a users door that records what it was asked and answers as the
# tool would, so the assertion is on the request the approval makes, and the
# refusals the check exists for still happen on the narrow answer.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Manager::Plugins ();
use Lazysite::Handlers         ();

my $d = site_tempdir();
make_path("$d/lazysite/forms/submissions");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: lazysite/forms/submissions\n" );
spit( "$d/lazysite/forms/register.conf", "targets:\n  - handler: jsonl\naccount_email: email\n" );
my @rows = map { encode_json( { name => $_->[0], email => $_->[1] } ) }
    [ 'Ada', 'ada@example.org' ], [ 'Dee', 'dee@example.org' ], [ 'Kit', 'kit@example.org' ];
spit( "$d/lazysite/forms/submissions/register.jsonl", join( '', map { "$_\n" } @rows ) );
my %id = map { $_->[0] => Lazysite::Handlers::submission_row_id( $_->[1] ) }
    [ ada => $rows[0] ], [ dee => $rows[1] ], [ kit => $rows[2] ];

$Lazysite::Manager::Plugins::DOCROOT = $d;
my $STORE = 'lazysite/forms/submissions/register.jsonl';

# The tool's answer to the narrow read: two existing accounts, one holding an
# address a submission asks for.
my ( @asked, $readable );
my $users = sub {
    my ($p) = @_;
    push @asked, $p;
    return { ok => 1, store_readable => ( $readable ? JSON::PP::true() : JSON::PP::false() ),
        users => [ { user => 'Kit', settings => { email => undef } },
            { user => 'zed', settings => { email => 'DEE@example.org' } } ] }
        if $p->{action} eq 'users-detail';
    return { ok => 1, user => $p->{username}, group => [], unplaced => [], claim => 'c',
        path => '/claim' }
        if $p->{action} eq 'account-approve';
    return { ok => 0, error => "unexpected $p->{action}" };
};
sub approve {
    @asked = ();
    return Lazysite::Manager::Plugins::action_form_submission_approve( $STORE, $_[0],
        users => $users, by => 'boss' );
}

$readable = 1;
subtest 'the check asks for the address alone' => sub {
    my $r = approve( $id{ada} );
    ok( $r->{ok}, 'approved' ) or diag( explain $r );
    my ($read) = grep { $_->{action} eq 'users-detail' } @asked;
    ok( $read, 'the account store was asked' ) or return;
    is_deeply( $read->{fields}, ['email'], 'for the one field the check reads' );
};

subtest 'and still refuses what it refused' => sub {
    my $r = approve( $id{dee} );
    ok( !$r->{ok}, 'an address another account holds is refused' );
    like( $r->{error} // '', qr/already recorded on the account 'zed'/, 'naming the account' );
    $r = approve( $id{kit} );
    ok( !$r->{ok}, 'a name taken in another case is refused' );
    like( $r->{error} // '', qr/an account named 'Kit' already exists/, 'naming the account' );
    ok( !( grep { $_->{action} eq 'account-approve' } @asked ), 'and nothing was created' );
};

$readable = 0;
subtest 'an answer from a store it could not read creates nothing' => sub {
    spit( "$d/lazysite/forms/submissions/register.jsonl", join( '', map { "$_\n" } @rows ) );
    my $r = approve( $id{ada} );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/account store could not be read/, 'saying why' );
    ok( !( grep { $_->{action} eq 'account-approve' } @asked ), 'and nothing was created' );
};

done_testing;
