#!/usr/bin/perl
# SM084: docroot content backups - tarball snapshot under lazysite/backups/,
# excluding the lazysite/ infra, listed for the manager; strict name validation.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups qw(action_backup_list action_backup_create action_backup_download);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");
mkdir "$d/lazysite/secretstuff";
# some served content + an infra file that must NOT be in the backup
_put("$d/index.html",   "<h1>real homepage</h1>\n");
_put("$d/about.html",   "about\n");
_put("$d/lazysite/secretstuff/keep-out.txt", "secret\n");

$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Backups::auth_user    = 'op';

# --- create ---
my $c = action_backup_create();
ok( $c->{ok}, 'backup-create ok' );
like( $c->{name}, qr/^manual-\d{8}T\d{6}Z\.tar\.gz$/, 'manual snapshot name' );
ok( -f "$d/lazysite/backups/$c->{name}", 'tarball written under lazysite/backups' );

# --- contents: includes served content, excludes lazysite/ ---
my @members = `tar tzf "$d/lazysite/backups/$c->{name}" 2>/dev/null`;
ok( ( grep { m{(^|/)index\.html} } @members ), 'backup includes site content' );
ok( !( grep { m{lazysite/} } @members ), 'backup excludes the lazysite/ infra (secrets)' );

# --- list ---
my $l = action_backup_list();
ok( $l->{ok}, 'backup-list ok' );
is( scalar @{ $l->{backups} }, 1, 'one backup listed' );
is( $l->{backups}[0]{kind}, 'manual', 'kind = manual' );
ok( $l->{backups}[0]{size} > 0, 'size reported' );

# --- download name validation (no path traversal, must exist) ---
is( action_backup_download('../../etc/passwd')->{ok}, 0, 'rejects path traversal' );
is( action_backup_download('etc/passwd')->{ok},       0, 'rejects a slashed name' );
is( action_backup_download('nope.tar.gz')->{ok},      0, 'rejects a missing backup' );

done_testing();

sub _put { my ( $p, $c ) = @_; open my $fh, '>', $p or die $!; print {$fh} $c; close $fh }
