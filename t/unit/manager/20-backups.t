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
use Lazysite::Manager::Backups qw(action_backup_list action_backup_create action_backup_download action_backup_restore action_backup_delete);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");
mkdir "$d/lazysite/secretstuff";
# some served content + an infra file that must NOT be in the backup
_put( "$d/index.html",                        "<h1>real homepage</h1>\n" );
_put( "$d/about.html",                        "about\n" );
_put( "$d/lazysite/secretstuff/keep-out.txt", "secret\n" );

$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Backups::auth_user    = 'op';

# --- create ---
my $c = action_backup_create();
ok( $c->{ok}, 'backup-create ok' );
like( $c->{name}, qr/^lazysite-manual-\d{8}T\d{6}Z\.tar\.gz$/, 'manual snapshot name' );
ok( -f "$d/lazysite/backups/$c->{name}", 'tarball written under lazysite/backups' );

# --- contents: includes served content, excludes lazysite/ ---
my @members = `tar tzf "$d/lazysite/backups/$c->{name}" 2>/dev/null`;
ok( ( grep { m{(^|/)index\.html} } @members ), 'backup includes site content' );
ok( !( grep { m{lazysite/} } @members ), 'backup excludes the lazysite/ infra (secrets)' );

# --- list ---
my $l = action_backup_list();
ok( $l->{ok}, 'backup-list ok' );
is( scalar @{ $l->{backups} }, 1,        'one backup listed' );
is( $l->{backups}[0]{kind},    'manual', 'kind = manual' );
ok( $l->{backups}[0]{size} > 0, 'size reported' );

# --- SM782: the installer's pre-upgrade archive is listed as what it is,
# and can be removed here. It was listed as `manual`, counted toward no cap,
# and refused by backup-delete as "Not a lazysite snapshot name".
{
    my $up = 'lazysite-backup-20260908-092453-pre-0.13.7.tar.gz';
    _put( "$d/lazysite/backups/$up", "not really a tarball\n" );
    my ($row) = grep { $_->{name} eq $up } @{ action_backup_list()->{backups} };
    ok( $row, 'the installer archive is listed' );
    is( $row->{kind},  'upgrade', 'as kind upgrade' );
    is( $row->{scope}, 'engine',  'with scope engine - the engine files, not content' );
    my $bad = action_backup_delete('lazysite-else-20260908T000000Z.tar.gz');
    ok( !$bad->{ok}, 'an unknown name shape is refused' );
    like( $bad->{error}, qr/lazysite-<manual\|prerestore\|full>-<stamp>.*lazysite-backup-<date>-<time>-pre-<version>/, 'naming both shapes this action manages' );
    my $del = action_backup_delete($up);
    ok( $del->{ok}, 'and the installer archive can be deleted' ) or diag $del->{error};
    ok( !-e "$d/lazysite/backups/$up", 'gone' );
}

# --- download name validation (no path traversal, must exist) ---
is( action_backup_download('../../etc/passwd')->{ok}, 0, 'rejects path traversal' );
is( action_backup_download('etc/passwd')->{ok},       0, 'rejects a slashed name' );
is( action_backup_download('nope.tar.gz')->{ok},      0, 'rejects a missing backup' );

# --- full-system backup: includes the lazysite/ infra (auth) for migration/DR ---
mkdir "$d/lazysite/auth";
_put( "$d/lazysite/auth/.secret",  "hmac-secret\n" );
_put( "$d/lazysite/lazysite.conf", "domain: temp.example.com\n" );
my $full = action_backup_create('full');
ok( $full->{ok}, 'full backup-create ok' );
like( $full->{name}, qr/^lazysite-full-\d{8}T\d{6}Z\.tar\.gz$/, 'full snapshot name' );
is( $full->{scope}, 'full', 'scope reported as full' );
my @fm = `tar tzf "$d/lazysite/backups/$full->{name}" 2>/dev/null`;
ok( ( grep { m{lazysite/auth/\.secret} } @fm ), 'full backup includes the auth secret (for migration)' );
ok( ( grep { m{(^|/)index\.html} } @fm ),   'full backup includes content too' );
ok( !( grep { m{lazysite/backups/} } @fm ), 'full backup does not nest the backups dir' );

# --- list categorises the full backup ---
my ($fl) = grep { $_->{kind} eq 'full' } @{ action_backup_list()->{backups} };
ok( $fl, 'full backup listed' );
is( $fl->{scope}, 'full', 'listed full backup carries scope=full' );

# --- a full backup is NOT restorable in-app (CLI-only) ---
my $rf = action_backup_restore( $full->{name} );
is( $rf->{ok}, 0, 'in-app restore refuses a full-system backup' );
like( $rf->{error}, qr/install\.pl --restore/, 'restore error points to the CLI path' );

done_testing();

sub _put { my ( $p, $c ) = @_; open my $fh, '>', $p or die $!; print {$fh} $c; close $fh }
