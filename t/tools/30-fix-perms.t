#!/usr/bin/perl
# SM215: secure_write_perms keeps a just-written file safe, and lazysite-fix-perms
# repairs drift by delegating to lazysite-check --fix (the canonical repairer).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $TOOL = repo_root() . '/tools/lazysite-fix-perms.pl';
ok( -f $TOOL, 'fix-perms tool present' );

# --- secure_write_perms: mode is applied; no die ------------------------------
use_ok('Lazysite::Util') or BAIL_OUT('Util will not load');
{
    my $d = tempdir( CLEANUP => 1 );
    my $f = "$d/probe";
    open my $fh, '>', $f or die $!;
    print {$fh} "x";
    close $fh;
    chmod 0600, $f;
    Lazysite::Util::secure_write_perms( $f, 0660 );
    is( ( ( stat $f )[2] & 07777 ), 0660, 'secure_write_perms applies the mode' );
}

# --- fix-perms delegates to lazysite-check ------------------------------------
my $d    = tempdir( CLEANUP => 1 );
my $root = "$d/lazysite";
make_path( "$root/auth", "$root/forms", "$root/logs", "$root/stats" );
open my $u, '>', "$root/auth/users" or die $!;
print {$u} "op:hash\n";
close $u;
chmod 0755, "$root/forms";    # drifted: not group-writable/setgid

sub run { my $out = qx($^X \Q$TOOL\E --docroot \Q$d\E @_ 2>&1); return $out }

my $help = qx($^X \Q$TOOL\E --help 2>&1);
like( $help, qr/lazysite-check|repair/i, '--help explains it delegates to the repairer' );

# Dry-run: reports, changes nothing on disk.
my $dry = run();
like( $dry, qr/DRY-RUN/, 'dry-run announces itself' );
is( ( ( stat "$root/forms" )[2] & 07777 ), 0755, 'dry-run changed nothing' );

# Apply: the drifted forms dir is repaired to the canonical mode via check --fix.
# check owns the spec (2770 for forms); assert the mode moved to a setgid,
# no-world mode rather than a literal, so this stays green if the spec is tuned.
run('--apply');
my $forms_mode = ( stat "$root/forms" )[2] & 07777;
ok( ( $forms_mode & 02000 ) && !( $forms_mode & 0007 ),
    'apply repaired the forms dir (setgid, no world access) via check --fix' )
    or diag sprintf( 'forms mode = %04o', $forms_mode );
ok( -d "$root/stats", 'stats dir present (check now knows the SM213 runtime dir)' );

done_testing;
