#!/usr/bin/perl
# SM1411: EVERY MANAGER PAGE FETCHES A MUTATING ACTION AS A POST.
#
# The editor took its lock with `fetch(API + '?action=lock&path=...')`, a GET.
# `lock` is declared mutating in Lazysite::ControlApi::Actions and the manager
# API refuses a mutating action sent as GET ("This action must be sent as
# POST.", SM475), so from 0.7.19 every editor open was refused its lock and
# nothing said so until the 0.16.7 edge run read the lock label. The bell's
# notices-seen was the same defect (SM957).
#
# This reads every `fetch(...)` call in the manager pages (starter/manager/*.md)
# and the shared manager files (starter/lazysite/manager/), takes each action
# the call names literally (`action=NAME`), and asks the action table - the one
# declaration of what mutates - whether it writes. A call naming a mutating
# action must say `method: 'POST'` in its own arguments. A call whose action is
# built at run time (`'?action=' + name`) names no action here and is not
# judged; the canary below keeps the reader from going quiet.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my %MUT  = Lazysite::ControlApi::Actions::mutating();
cmp_ok( scalar keys %MUT, '>=', 50, 'the canary: the action table declares the mutating actions' );
ok( $MUT{lock} && $MUT{'renew-lock'}, 'lock and renew-lock are among them' );

my @files = sort glob("$root/starter/manager/*.md");
File::Find::find( { no_chdir => 1, wanted => sub { push @files, $_ if -f $_ } },
    "$root/starter/lazysite/manager" );
cmp_ok( scalar @files, '>=', 15, 'the canary: found the manager pages' );

# Every fetch( ... ) call, to its balanced closing parenthesis.
sub fetch_calls {
    my ($src) = @_;
    my @calls;
    while ( $src =~ /\bfetch\s*\(/g ) {
        my $start = pos $src;
        my ( $depth, $i ) = ( 1, $start );
        while ( $depth && $i < length $src ) {
            my $c = substr( $src, $i++, 1 );
            $depth++ if $c eq '(';
            $depth-- if $c eq ')';
        }
        my $line = 1 + ( () = substr( $src, 0, $start ) =~ /\n/g );
        push @calls, [ $line, substr( $src, $start, $i - $start ) ];
        pos($src) = $start;
    }
    return @calls;
}

my ( $named, $writes, @bad ) = ( 0, 0 );
for my $f (@files) {
    open my $fh, '<', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    for my $c ( fetch_calls($src) ) {
        my ( $line, $call ) = @$c;
        for my $act ( $call =~ /action=([a-z][a-z0-9_-]*)/g ) {
            $named++;
            next unless $MUT{$act};
            $writes++;
            push @bad, "$rel:$line fetches '$act' (mutating) without method: 'POST'"
                unless $call =~ /\bmethod\s*:\s*['"]POST['"]/;
        }
    }
}
cmp_ok( $named,  '>=', 30, "the canary: $named fetches name an action" );
cmp_ok( $writes, '>=', 10, "the canary: $writes of them name a mutating one" );
is_deeply( \@bad, [], 'every fetch of a mutating action is a POST' ) or diag join "\n", @bad;

done_testing;
