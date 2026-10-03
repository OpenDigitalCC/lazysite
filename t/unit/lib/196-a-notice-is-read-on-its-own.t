#!/usr/bin/perl
# SM938 D3: THE BELL'S READ STATE IS SAID, NOT INFERRED.
#
# The operator's words: "the bell is confusing - it shows but doesn't do
# anything ... requires some kind of mark as read." Measured before this was
# built: a per-principal last-seen marker existed and worked, and the ONLY thing
# that set it was opening the panel - so opening the list marked everything read,
# including what was below the fold, and the badge measured "has opened the
# panel" rather than outstanding work. The operator who filed this had acted on
# none of the notices and had already lost the count.
#
# The report's three asks, in its own order, each pinned here:
#   1. per-notice read state - marking one does not mark the rest;
#   2. an explicit "mark all read", instead of marking on open;
#   3. dismiss - out of the panel, KEPT in the store ("the bell store is the
#      record and should stay one").
#
# And the two properties that keep it safe to deploy over an existing site:
#   - a marker written before this (principal => epoch) still reads, so nobody's
#     position is lost;
#   - state is per principal, so one operator's reading is not another's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir repo_root);

use Lazysite::Manager::Notices ();

my $root = site_tempdir();
my $lz   = "$root/lazysite";
make_path("$lz/logs");
$Lazysite::Manager::Notices::DOCROOT = $root;

my $NOTICES = "$lz/logs/notices.jsonl";
my $SEEN    = "$lz/logs/notices-seen.json";
my $now     = time();

open my $fh, '>', $NOTICES or die $!;
print {$fh} encode_json($_) . "\n" for (
    { ts => $now - 300, type => 'submission', message => 'first',  url => '/manager/handlers' },
    { ts => $now - 200, type => 'submission', message => 'second', url => '/manager/handlers' },
    { ts => $now - 100, type => 'reset-request', message => 'third' },
);
close $fh;

sub bell   { Lazysite::Manager::Notices::action_notices( $_[0] ) }
sub mark   { Lazysite::Manager::Notices::action_notices_seen(@_) }
sub by_msg { my ($r) = @_; return { map { $_->{message} => $_ } @{ $r->{notices} } } }
sub store_lines { open my $f, '<', $NOTICES or die; my @l = <$f>; return scalar @l }

my $start = bell('op');
my %id    = map { $_->{message} => $_->{id} } @{ $start->{notices} };

subtest 'every notice has a stable identity' => sub {
    is( scalar keys %id, 3, 'three notices, three ids' );
    like( $_, qr/\A[0-9a-f]{12}\z/, "id $_ has the documented shape" ) for values %id;
    is_deeply( { map { $_->{message} => $_->{id} } @{ bell('op')->{notices} } }, \%id,
        'and the same notice gets the same id on the next read' )
        or diag( 'An id that changed between reads would make "mark this one" '
            . 'mark nothing.' );
    is( $start->{unread}, 3, 'a principal with no marker has three unread' );
};

subtest 'ask 1: marking one notice does not mark the rest' => sub {
    my $r = mark( 'op', id => $id{first} );
    ok( $r->{ok}, 'marked' ) or diag explain $r;
    is( $r->{unread}, 2, 'the reply carries the new unread count' );

    my $b = by_msg( bell('op') );
    ok( $b->{first}{read},   'the marked notice reads as read' );
    ok( !$b->{second}{read}, 'the second does NOT' )
        or diag( 'This is the reported fault: one act of reading took the '
            . 'whole list with it.' );
    ok( !$b->{third}{read},  'nor the third' );
};

subtest 'ask 3: a dismissed notice leaves the panel and stays in the store' => sub {
    my $before = store_lines();
    my $r = mark( 'op', id => $id{second}, dismiss => 1 );
    ok( $r->{ok}, 'dismissed' ) or diag explain $r;
    is( $r->{unread}, 1, 'and it no longer counts as unread' );

    my $b = bell('op');
    ok( !by_msg($b)->{second}, 'it is gone from the list' );
    is( $b->{dismissed}, 1, 'which says how many are dismissed' );
    is( store_lines(), $before, 'and the STORE still has every line' )
        or diag( 'Dismissal is a second marker, not a delete - the store is the '
            . 'record. A dismiss that deleted would destroy the trail.' );
};

subtest 'ask 2: mark all read is an explicit act' => sub {
    my $r = mark('op');
    is( $r->{unread}, 0, 'mark-all leaves nothing unread' );
    ok( by_msg( bell('op') )->{third}{read}, 'including the one never marked singly' );
};

subtest 'opening the panel no longer marks anything' => sub {
    # Against the source, because the panel is browser code: the toggle that
    # opens the panel must not call the marker. This is the line the fault was.
    my $tt = do {
        open my $t, '<', repo_root() . '/starter/lazysite/manager/layout.tt' or die $!;
        local $/;
        <$t>;
    };
    my ($toggle) = $tt =~ /(window\.mgToggleNotif = function\(\)\{.*?\n    \};)/s;
    ok( $toggle, 'found the panel toggle' ) or return;
    unlike( $toggle, qr/notices-seen/,
        'and opening the panel does not mark notices read' )
        or diag( 'Opening a list is reading it only when the list is short '
            . '(the report). A badge that clears on open measures panel '
            . 'openings, not work.' );
    like( $tt, qr/Mark all read/, 'the panel offers mark-all explicitly' );
    like( $tt, qr/data-notif-dismiss/, 'and a dismiss control per notice' );
};

subtest 'state is per principal' => sub {
    is( bell('other')->{unread}, 3,
        "another operator's bell is untouched by 'op' reading everything" );
    is( scalar @{ bell('other')->{notices} }, 3,
        "and 'op' dismissing one did not dismiss it for them" );
};

subtest 'a marker written before this still reads' => sub {
    my $h = decode_json( do { open my $s, '<', $SEEN or die; local $/; <$s> } );
    $h->{legacy} = $now - 150;    # the old shape: principal => epoch
    open my $w, '>', $SEEN or die;
    print {$w} encode_json($h);
    close $w;
    my $b = by_msg( bell('legacy') );
    ok( $b->{first}{read} && $b->{second}{read}, 'notices before the old mark are read' );
    ok( !$b->{third}{read}, 'the one after it is not' );
    is( bell('legacy')->{unread}, 1, 'so an upgrade loses nobody\'s position' );
};

subtest 'an id that names nothing is refused, by name' => sub {
    my $r = mark( 'op', id => 'deadbeef0000' );
    ok( !$r->{ok}, 'an unknown id is refused' );
    is( $r->{kind}, 'not-found', 'as not-found' );
    like( $r->{error}, qr/deadbeef0000/, 'naming the id' );
    ok( !mark( 'op', id => '../etc' )->{ok}, 'a malformed one too' );
};

subtest 'the marker does not grow without bound' => sub {
    my $h = decode_json( do { open my $s, '<', $SEEN or die; local $/; <$s> } );
    $h->{op}{read}{'aaaaaaaaaaaa'} = 1;    # an id that is not in the window
    open my $w, '>', $SEEN or die;
    print {$w} encode_json($h);
    close $w;
    mark( 'op', id => $id{third} );
    my $after = decode_json( do { open my $s, '<', $SEEN or die; local $/; <$s> } );
    ok( !exists $after->{op}{read}{'aaaaaaaaaaaa'},
        'an id that has aged out of the window is dropped on the next write' );
};

done_testing();
