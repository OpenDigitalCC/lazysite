#!/usr/bin/perl
# SM1100: "Mark all read" is kept, or the answer says it was not.
#
# The release manager on edge, 2026-10-16: marking all notifications read "doesnt
# work". action_notices_seen wrote the per-account marker with a bare open '>'
# and answered ok whether or not the file opened. Where the marker belonged to
# another account than the web server's - on edge, a host where the engine's
# files are written by more than one account - the open failed, the bell cleared
# on screen and every notice came back unread on the next page.
#
# What this holds:
#
# - a marker file this process cannot open for writing (mode 0444, the shape of
#   a file owned by another account) is still replaced, through a sibling
#   renamed over it in the writable logs/ folder, and the mark is kept
# - where even that cannot be done, the answer is an error naming the file,
#   never ok
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

plan skip_all => 'running as root: file modes do not refuse root' if $> == 0;

my $root = site_tempdir();
my $lz   = "$root/lazysite";
make_path("$lz/logs");
$Lazysite::Manager::Notices::DOCROOT = $root;

my $SEEN = "$lz/logs/notices-seen.json";
my $now  = time();
open my $fh, '>', "$lz/logs/notices.jsonl" or die $!;
print {$fh} encode_json($_) . "\n"
    for map { { ts => $now - $_, type => 'submission', message => "n$_" } } 300, 200, 100;
close $fh;

sub bell { Lazysite::Manager::Notices::action_notices( $_[0] ) }
sub mark { Lazysite::Manager::Notices::action_notices_seen(@_) }

subtest 'a marker this process cannot open is still replaced, and the mark kept' => sub {
    open my $s, '>', $SEEN or die $!;
    print {$s} encode_json( { other => { mark => 0 } } );
    close $s;
    chmod 0444, $SEEN;
    is( bell('op')->{unread}, 3, 'three unread to start' );

    my $r = mark('op');
    ok( $r->{ok}, 'mark all read answers ok' ) or diag explain $r;
    is( bell('op')->{unread}, 0, 'and the next read of the bell finds none unread' );
    is( ( stat $SEEN )[2] & 07777, 0444, 'the marker keeps its mode' );
    like( do { local ( @ARGV, $/ ) = $SEEN; <> }, qr/"other"/,
        'and another account\'s position survives' );
};

subtest 'a marker that cannot be written at all is an error, not ok' => sub {
    chmod 0555, "$lz/logs";
    my $r = mark('op2');
    chmod 0775, "$lz/logs";
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'not-saved', 'as not-saved' );
    like( $r->{error} // '', qr/notices-seen\.json could not be written/, 'naming the file' );
    is( bell('op2')->{unread}, 3, 'and nothing was marked' );
};

done_testing;
