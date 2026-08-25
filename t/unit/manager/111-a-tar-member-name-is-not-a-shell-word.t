#!/usr/bin/perl
# SM516 BP-16: the two places that listed a backup's members ran tar through a
# shell - a qx() with \Q quoting in _archive_scope and a backtick in the
# restore's private-store pass - against the doctrine action_backup_create's
# own tar call states in the same file: LIST FORM, NO SHELL. Both now go
# through _archive_members, which forks and execs.
#
# The proof a shell is gone is that names a shell would act on come back
# untouched: a member (and an archive path) carrying $(...), a semicolon, a
# backtick, a glob or a space lists exactly as tar stored it, and the scope
# derived from it is the same one the ordinary names produce.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups ();

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/backups");
$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
my $bk = "$d/lazysite/backups";

# Names a shell would expand, split or execute.
my @awkward = ( 'a;rm -rf x.md', 'b$(touch pwned).md', 'c`id`.md', 'd*.md', 'e f.md' );

subtest 'a member name a shell would act on lists exactly as tar stored it' => sub {
    make_path("$d/sites/edge");
    spit( "$d/sites/edge/$_", "x\n" ) for @awkward;
    my $arch = "$bk/lazysite-manual-20260101T000000Z.tar.gz";
    system( 'tar', 'czf', $arch, '-C', $d, './sites' ) == 0 or die 'tar failed';

    my @got   = Lazysite::Manager::Backups::_archive_members($arch);
    my @want  = sort map  { "./sites/edge/$_" } @awkward;
    my @files = sort grep { m{\A\./sites/edge/[^/]} } @got;
    is_deeply( \@files, \@want, 'every awkward name came back whole' )
        or diag explain \@got;
    ok( !-e "$d/pwned", 'and nothing in a member name was executed' );
    is( Lazysite::Manager::Backups::_archive_scope($arch),
        'sites/edge', 'the scope derived from them is the ordinary one' );
};

subtest 'and so does an archive PATH a shell would act on' => sub {
    my $arch = "$bk/lazysite-manual-20260101T000001Z\$(touch owned) ;x.tar.gz";
    system( 'tar', 'czf', $arch, '-C', $d, './sites' ) == 0 or die 'tar failed';
    my @got = Lazysite::Manager::Backups::_archive_members($arch);
    ok( scalar( grep { $_ eq './sites/' } @got ),
        'the archive was read through its own name, unquoted' )
        or diag explain \@got;
    ok( !-e "$d/owned", 'and no part of the name reached a shell' );
};

subtest 'a missing archive is an empty list, not a die' => sub {
    my @got = eval { Lazysite::Manager::Backups::_archive_members("$bk/absent.tar.gz") };
    is( $@, '', 'no exception' );
    is_deeply( \@got, [], 'no members' );
};

done_testing;
