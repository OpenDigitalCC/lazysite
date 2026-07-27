#!/usr/bin/perl
# lazysite-fix-perms - SM215: re-assert ownership and modes across a site's
# lazysite/ management tree, to repair drift (e.g. a credential reset or install
# run under sudo that left files root-owned, which the www-data CGI cannot access,
# or a directory that lost its group-write bit). Dry-run by default; --apply makes
# the changes. Idempotent. Must run as root to fix ownership (chown is root-only).
#
#   perl tools/lazysite-fix-perms.pl --docroot /srv/site            # report only
#   perl tools/lazysite-fix-perms.pl --docroot /srv/site --apply    # repair
#   ... [--owner NAME|UID] [--group NAME|GID]   # default: the docroot's own owner/group
#
# The target owner/group default to the docroot's own owner:group (provisioning
# sets the docroot to <site-user>:<web-group>), so nothing external is assumed.
# Standalone + module-free (it may run as root during provisioning); no network.
use strict;
use warnings;
use File::Find ();

my %arg = ( apply => 0 );
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--docroot' ) { $arg{docroot} = shift @ARGV }
    elsif ( $a eq '--apply' )   { $arg{apply}   = 1 }
    elsif ( $a eq '--owner' )   { $arg{owner}   = shift @ARGV }
    elsif ( $a eq '--group' )   { $arg{group}   = shift @ARGV }
    elsif ( $a eq '--help' )    { print _usage(); exit 0 }
    else                        { die "Unknown argument '$a'\n" . _usage() }
}
sub _usage { "Usage: lazysite-fix-perms --docroot DIR [--apply] [--owner U] [--group G]\n" }

my $docroot = $arg{docroot} || $ENV{DOCUMENT_ROOT}
    or die "--docroot is required\n" . _usage();
$docroot =~ s{/+$}{};
my $root = "$docroot/lazysite";
die "No lazysite/ tree under '$docroot'\n" unless -d $root;

# Resolve target owner/group: an explicit name/uid, else inherit the docroot's own.
my @dstat = stat $docroot or die "cannot stat $docroot: $!\n";
my $uid   = _resolve_id( $arg{owner}, $dstat[4], \&_uid_of );
my $gid   = _resolve_id( $arg{group}, $dstat[5], \&_gid_of );

sub _resolve_id {
    my ( $want, $default, $lookup ) = @_;
    return $default unless defined $want && length $want;
    return $want if $want =~ /^\d+$/;
    my $id = $lookup->($want);
    die "no such user/group '$want'\n" unless defined $id;
    return $id;
}
sub _uid_of { my $n = shift; my @p = getpwnam($n); return @p ? $p[2] : undef }
sub _gid_of { my $n = shift; my @g = getgrnam($n); return @g ? $g[2] : undef }

if ( $arg{apply} && $> != 0 ) {
    warn "WARNING: not running as root - ownership changes will be attempted but "
        . "will fail for files you do not own.\n";
}

# Directory modes (setgid so NEW files inherit the group). Longest prefix wins.
my @DIR_MODE = (
    [ "$root/auth"  => 02770 ],    # credentials: setgid + group rwx, no world
    [ "$root/forms" => 02775 ],
    [ "$root/cache" => 02775 ],
    [ "$root/logs"  => 02775 ],
    [ "$root/stats" => 02775 ],    # SM213 durable stats store
);

# File-mode rules by path (regex against the path under the docroot). Anything not
# matched keeps its mode; only owner/group are re-asserted for it.
sub _target_file_mode {
    my ($path) = @_;
    return 0660 if $path =~ m{/lazysite/auth/};    # co-managed by CLI + www-data
    return 0640 if $path =~ m{/lazysite/forms/[^/]+\.conf$}; # per-form config (may hold a secret)
    return undef;
}

sub _target_dir_mode {
    my ($path) = @_;
    for my $r (@DIR_MODE) {
        return $r->[1] if $path eq $r->[0] || index( $path, "$r->[0]/" ) == 0;
    }
    return 02775;    # other lazysite/ dirs: setgid + group-write, no world-write
}

my ( @changes, $errors );
File::Find::find(
    { no_chdir => 1,
        wanted => sub {
            my $path = $File::Find::name;
            my @st   = lstat $path or return;
            return if -l _;    # never follow/alter symlinks
            my $is_dir = -d _;
            my ( $cuid, $cgid, $cmode ) = ( $st[4], $st[5], $st[2] & 07777 );

            # owner / group
            if ( $cuid != $uid || $cgid != $gid ) {
                push @changes, [ 'own', $path, "$cuid:$cgid", "$uid:$gid" ];
                if ( $arg{apply} ) { chown( $uid, $gid, $path ) or $errors++ }
            }

            # mode
            my $target = $is_dir ? _target_dir_mode($path) : _target_file_mode($path);
            if ( defined $target && $cmode != $target ) {
                push @changes,
                    [ 'mode', $path, sprintf( '%04o', $cmode ), sprintf( '%04o', $target ) ];
                if ( $arg{apply} ) { chmod( $target, $path ) or $errors++ }
            }
        },
    },
    $root,
);

my $tuser = getpwuid($uid) // $uid;
my $tgrp  = getgrgid($gid) // $gid;
printf "lazysite-fix-perms: %s\n  target owner=%s group=%s  tree=%s\n",
    ( $arg{apply} ? 'APPLIED' : 'DRY-RUN (no changes; pass --apply to repair)' ),
    $tuser, $tgrp, $root;
if (@changes) {
    for my $c (@changes) {
        printf "  [%-4s] %s : %s -> %s\n", @$c;
    }
    printf "  %d path(s) %s.\n", scalar @changes,
        ( $arg{apply} ? 'repaired' : 'would be repaired' );
}
else { print "  all paths already correct.\n" }
if ($errors) {
    warn "  $errors change(s) FAILED (run as root to fix ownership).\n";
    exit 1;
}
exit 0;
