#!/usr/bin/perl
# SM555: opening /lazysite in the file browser wrote one "blocked lazysite
# tree" WARN per hidden entry - is_blocked_path logs on every hit, and the
# listing asks it once per entry. Six warnings per ordinary folder open read as
# a traversal attempt in a log review and bury the warning that would matter.
#
# The listing sweep is the filter doing its job, so it is quiet and reports
# once. A DIRECT touch of a blocked path is still an attempt, and still warns.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

my $d = tempdir( CLEANUP => 1 );
make_path( map { "$d/lazysite/$_" } qw(auth cache manager forms/submissions layouts templates backups) );
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::LOCK_DIR = "$d/lazysite/manager/locks";
$ENV{DOCUMENT_ROOT}                 = $d;
delete $ENV{LAZYSITE_LOG_LEVEL};

# log_event prints to STDERR; capture it around one call.
sub captured {
    my ($code) = @_;
    my $log = "$d/captured.log";
    my $r;
    {
        open my $save, '>&', \*STDERR or die $!;
        open STDERR,   '>',  $log     or die $!;
        $r = $code->();
        open STDERR, '>&', $save or die $!;
    }
    open my $fh, '<', $log or die $!;
    my @lines = <$fh>;
    close $fh;
    unlink $log;
    return ( $r, @lines );
}

subtest 'listing the engine tree logs once' => sub {
    my ( $r, @lines ) = captured( sub { Lazysite::Manager::Files::action_list('/lazysite') } );
    ok( $r->{ok}, 'the listing succeeds' ) or diag( $r->{error} // '' );
    my %shown = map { $_->{name} => 1 } @{ $r->{entries} || [] };
    ok( $shown{layouts} && $shown{forms}, 'the carve-outs are still shown' )
        or diag( 'shown: ' . join ',', sort keys %shown );
    ok( !$shown{auth} && !$shown{cache}, 'and the sensitive entries are still hidden' );

    my @warns = grep { /\[WARN\].*blocked/ } @lines;
    is( scalar @warns, 0, 'no per-entry blocked WARN line' )
        or diag(@warns);
    my @once = grep { /listing hid blocked entries/ } @lines;
    is( scalar @once, 1, 'one line says how many entries the sweep hid' )
        or diag(@lines);
    like( $once[0] // '', qr/hidden=[1-9]\d*/, 'and carries the count' );
    like( $once[0] // '', qr{path=/lazysite},  'and names the folder' );
};

subtest 'a direct touch of a blocked path still warns' => sub {
    my ( $r, @lines ) = captured( sub { Lazysite::Manager::Files::action_list('/lazysite/auth') } );
    ok( !$r->{ok}, 'listing the auth tree itself is refused' );
    my @warns = grep { /\[WARN\].*blocked lazysite tree/ } @lines;
    is( scalar @warns, 1, 'with the WARN the reviewer relies on' ) or diag(@lines);
};

done_testing();
