#!/usr/bin/perl
# SM1274 (ruling 26, 2026-10-23): "Mark all read" also DISMISSES.
#
# It marked everything read and left it all in the panel, so the panel never
# emptied. Now it marks every notice in the bell read and takes it out of the
# panel; the store keeps every line, as a single dismiss leaves it (SM938 D3).
# A notice that arrives after it is unread and in the panel. The count and the
# panel agree on the reply and on a fresh read - the SM1100 shape (the bell
# cleared on screen and came back on the next page) must not come back.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Manager::Notices ();

my $root = site_tempdir();
my $lz   = "$root/lazysite";
make_path("$lz/logs");
$Lazysite::Manager::Notices::DOCROOT = $root;

my $NOTICES = "$lz/logs/notices.jsonl";
my $now     = time();

sub append {
    open my $fh, '>>', $NOTICES or die $!;
    print {$fh} encode_json($_) . "\n" for @_;
    close $fh;
}
sub bell  { Lazysite::Manager::Notices::action_notices(@_) }
sub mark  { Lazysite::Manager::Notices::action_notices_seen(@_) }
sub store { open my $f, '<', $NOTICES or die; my @l = <$f>; close $f; return join '', @l }

append(
    { ts => $now - 300, type => 'submission',    message => 'first' },
    { ts => $now - 200, type => 'submission',    message => 'second' },
    { ts => $now - 100, type => 'reset-request', message => 'third' },
    { ts => $now - 50,  type => 'submission',    message => 'for-mia', to => 'mia' },
);

subtest 'the operator\'s Dismiss all empties the panel and the count' => sub {
    is( scalar @{ bell('op')->{notices} }, 3, 'three notices in the panel to start' );
    mark( 'op', id => bell('op')->{notices}[0]{id} );    # one already read: both kinds go
    my $before = store();

    my $r = mark('op');
    ok( $r->{ok}, 'answers ok' ) or diag explain $r;
    is( $r->{unread}, 0, 'the reply\'s count is 0' );

    my $b = bell('op');    # a fresh read, as the next page load makes
    is_deeply( $b->{notices}, [], 'a fresh read finds the panel empty' )
        or diag explain $b->{notices};
    is( $b->{unread},    0, 'and the count 0, agreeing with it' );
    is( $b->{dismissed}, 3, 'all three are counted as dismissed' );
    is( store(), $before, 'and the store still holds every line, unchanged' );
};

subtest 'a notice that arrives after it is unread, in the same second too' => sub {
    append( { ts => time(), type => 'submission', message => 'later' } );
    my $b = bell('op');
    is( scalar @{ $b->{notices} }, 1, 'the panel shows the one that arrived' );
    is( $b->{notices}[0]{message}, 'later', 'and only it' );
    ok( !$b->{notices}[0]{read}, 'as unread' );
    is( $b->{unread}, 1, 'and the count says 1' );
};

subtest 'it is this principal\'s alone' => sub {
    is( scalar @{ bell('other')->{notices} }, 4, 'another operator\'s panel is untouched' );
    is( bell('other')->{unread}, 4, 'and so is their count' );
};

subtest 'a member\'s Dismiss all empties their own bell' => sub {
    my %m = ( addressed_only => 1 );
    is( scalar @{ bell( 'mia', %m )->{notices} }, 1, 'mia has her one notice' );
    my $r = mark( 'mia', %m );
    is( $r->{unread}, 0, 'the reply\'s count is 0' );
    is_deeply( bell( 'mia', %m )->{notices}, [], 'and her bell is empty on a fresh read' );
};

done_testing();
