#!/usr/bin/perl
# SM215: lazysite-fix-perms re-asserts modes (and ownership, root-only) across a
# site's lazysite/ tree, and secure_write_perms keeps a just-written file safe.
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

# --- secure_write_perms: mode is applied; no die; group best-effort -----------
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

# --- fix-perms: dry-run reports drift, --apply repairs modes, idempotent -------
my $d    = tempdir( CLEANUP => 1 );
my $root = "$d/lazysite";
make_path( "$root/auth", "$root/forms", "$root/logs", "$root/cache", "$root/stats" );
open my $u, '>', "$root/auth/users" or die $!;
print {$u} "op:hash\n";
close $u;
open my $s, '>', "$root/forms/smtp.conf" or die $!;
print {$s} "host: mail\n";
close $s;
chmod 0755, "$root/forms";           # drifted: not group-writable
chmod 0644, "$root/forms/smtp.conf"; # drifted: world-readable
chmod 0664, "$root/auth/users";      # drifted: should be 0660

sub run { my $out = qx($^X \Q$TOOL\E --docroot \Q$d\E @_ 2>&1); return ( $out, $? >> 8 ) }

my ( $dry, $rc ) = run();
is( $rc, 0, 'dry-run exits 0' );
like( $dry, qr/DRY-RUN/, 'dry-run announces itself' );
like( $dry, qr{forms/smtp\.conf.*0644 -> 0640}, 'dry-run flags the world-readable conf' );
like( $dry, qr{/forms .*0755 -> 2775},          'dry-run flags the non-group-writable forms dir' );
is( ( ( stat "$root/forms/smtp.conf" )[2] & 07777 ), 0644, 'dry-run changed nothing on disk' );

my ( $app, $rc2 ) = run('--apply');
is( $rc2, 0, 'apply exits 0' );
is( ( ( stat "$root/forms/smtp.conf" )[2] & 07777 ), 0640, 'apply fixed the secret conf mode' );
is( ( ( stat "$root/forms" )[2] & 07777 ),           02775, 'apply set the forms dir setgid + group-write' );
is( ( ( stat "$root/auth" )[2] & 07777 ),            02770, 'apply set the auth dir 2770' );
is( ( ( stat "$root/auth/users" )[2] & 07777 ),      0660,  'apply set auth/users 0660' );

my ( $again, $rc3 ) = run('--apply');
like( $again, qr/all paths already correct|repaired/, 'second apply is idempotent' );
is( ( ( stat "$root/auth/users" )[2] & 07777 ), 0660, 'still 0660 after a second run' );

done_testing;
