#!/usr/bin/perl
# SM530: the manager's own make_path calls returned nothing on failure - they
# CROAKED (File::Path), so `make_path($full) or return {...}` in action_mkdir
# never reached its `or`, and the bare `make_path($dir) unless -d $dir` before
# the writes in save, binary save, move and copy died the same way. The CGI
# died with "mkdir ...: Permission denied", the caller saw a tool error and no
# audit line was written - the SM296 lesson recorded in Private.pm, repeated on
# the manager's own directories.
#
# A refusal names what was refused and why; a die leaves a bare server error
# exactly where a permissions problem needs diagnosing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

plan skip_all => 'root ignores directory modes' if $> == 0;

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/manager/locks", "$d/content", "$d/ro" );
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Files::LOCK_DIR = "$d/lazysite/manager/locks";
$ENV{DOCUMENT_ROOT}                 = $d;

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
spit( "$d/content/src.md", "body\n" );
chmod 0555, "$d/ro";
END { chmod 0755, "$d/ro" if defined $d }

# Each call is made inside an eval: the defect was a die, and a test that
# died with it would report nothing about the other four.
my @cases = (
    [ 'a mkdir into an unwritable parent returns a refusal',
        sub { Lazysite::Manager::Files::action_mkdir('ro/child') } ],
    [ 'a save into an unwritable parent returns a refusal',
        sub { Lazysite::Manager::Files::action_save( 'ro/new/p.md', 'alice', "x\n", undef ) } ],
    [ 'a binary save into an unwritable parent returns a refusal',
        sub { Lazysite::Manager::Files::action_save_binary( 'ro/new/b.bin', 'alice', "\x00\x01" ) } ],
    [ 'a move into an unwritable parent returns a refusal',
        sub { Lazysite::Manager::Files::action_move( 'content/src.md', 'ro/new/src.md', 'alice' ) } ],
    [ 'a copy into an unwritable parent returns a refusal',
        sub { Lazysite::Manager::Files::action_copy( 'content/src.md', 'ro/new/copy.md', 'alice' ) } ],
);

for my $case (@cases) {
    my ( $name, $call ) = @$case;
    subtest $name => sub {
        my $r    = eval { $call->() };
        my $died = $@;
        ok( !$died, 'the call returns rather than dying' )
            or diag( ( split /\n/, $died )[0] );
        is( ref $r, 'HASH', 'and returns a result hash' );
        ok( ref $r eq 'HASH' && !$r->{ok}, 'which is a refusal' );
        like( ( ref $r eq 'HASH' ? $r->{error} : '' ) // '', qr/director|folder/i,
            'that says the directory could not be created' );
        ok( !-e "$d/ro/child" && !-e "$d/ro/new", 'nothing was created under the parent' );
    };
}
ok( -f "$d/content/src.md", 'the move source is still where it was' );

done_testing();
