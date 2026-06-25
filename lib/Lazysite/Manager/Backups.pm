package Lazysite::Manager::Backups;

# SM084: docroot content backups - tarball snapshots stored under
# lazysite/backups/ (infrastructure, never served), surfaced in the manager so an
# operator can snapshot before a risky change and download/restore the original.
# A pre-install snapshot is taken by the Hestia hook; manual ones come from here.

use strict;
use warnings;
use POSIX qw(strftime);
use File::Path qw(make_path);
use Lazysite::Util qw(log_event);
use Exporter qw(import);
our @EXPORT_OK = qw(action_backup_list action_backup_create action_backup_download);

our $DOCROOT      = '';
our $LAZYSITE_DIR = '';
our $auth_user    = '';

sub _dir { return "$LAZYSITE_DIR/backups" }

# A backup name is a single tarball basename - strict, no path traversal.
sub _valid_name { return $_[0] =~ /\A[A-Za-z0-9._-]+\.tar\.gz\z/ && $_[0] !~ /[.][.]/ }

sub action_backup_list {
    my $dir = _dir();
    my @out;
    if ( opendir my $dh, $dir ) {
        for my $f ( readdir $dh ) {
            next unless $f =~ /\.tar\.gz\z/ && -f "$dir/$f";
            my @st = stat "$dir/$f";
            push @out, { name => $f, size => $st[7] // 0, mtime => $st[9] // 0,
                kind => ( $f =~ /^preinstall-/ ? 'preinstall' : 'manual' ) };
        }
        closedir $dh;
    }
    @out = sort { $b->{mtime} <=> $a->{mtime} } @out;
    return { ok => 1, backups => \@out };
}

sub action_backup_create {
    my $dir = _dir();
    make_path($dir) unless -d $dir;
    my $name = 'manual-' . strftime( '%Y%m%dT%H%M%SZ', gmtime ) . '.tar.gz';
    my $out  = "$dir/$name";
    # Snapshot the served content; exclude the lazysite/ infra (which holds the
    # backups themselves + auth secrets) and the generated assets dir.
    my $rc = system( 'tar', 'czf', $out, '-C', $DOCROOT,
        '--exclude=./lazysite', '--exclude=./lazysite-assets', '.' );
    return { ok => 0, error => 'Backup failed' } if $rc != 0 || !-f $out;
    log_event( 'INFO', 'backup-create', 'docroot snapshot', file => $name, user => $auth_user );
    my @st = stat $out;
    return { ok => 1, name => $name, size => $st[7] // 0, mtime => $st[9] // 0 };
}

# Streams the tarball (Content-Disposition attachment). Returns an error hash
# only on a pre-stream failure; on success it has already written the response.
sub action_backup_download {
    my ($name) = @_;
    $name = '' unless defined $name;
    return { ok => 0, error => 'Invalid backup name' } unless _valid_name($name);
    my $full = _dir() . "/$name";
    return { ok => 0, error => 'Backup not found' } unless -f $full;

    my $size = ( stat $full )[7] // 0;
    ( my $safe = $name ) =~ s/[\r\n"\\]//g;
    log_event( 'INFO', 'backup-download', 'backup downloaded', file => $name, user => $auth_user );

    binmode STDOUT;
    local $| = 1;
    print "Status: 200 OK\r\n";
    print "Content-Type: application/gzip\r\n";
    print "Content-Length: $size\r\n";
    print "Content-Disposition: attachment; filename=\"$safe\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";
    open my $fh, '<', $full or return { ok => 0, error => 'Cannot read backup' };
    binmode $fh;
    my $buf;
    while ( my $n = sysread $fh, $buf, 65536 ) { syswrite STDOUT, $buf, $n }
    close $fh;
    return { ok => 1, streamed => 1 };
}

1;
