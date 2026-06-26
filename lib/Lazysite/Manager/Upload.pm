package Lazysite::Manager::Upload;

# SM079: manager file upload / download / zip-download handlers, the
# content-type + text-extension tables, and the upload rate limiter. Context
# ($DOCROOT, $LAZYSITE_DIR, $auth_user) is set by the dispatcher. DB_File,
# Archive::Zip and File::Temp are required inline (optional deps).

use strict;
use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX qw(strftime);
use File::Basename qw(basename);
use File::Path qw(make_path);
use Cwd qw(realpath);
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common
    qw(validate_path is_blocked_path is_blocked_config respond upload_limits);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_file_upload action_file_download action_file_zip_download
    check_upload_rate parse_multipart_body sanitise_upload_filename
    detect_content_type is_editable_text
);

our $DOCROOT;
our $LAZYSITE_DIR;
our $auth_user = '';

# === moved from lazysite-manager-api.pl (SM079a) ===

our %CONTENT_TYPE_MAP = (
    md    => 'text/plain; charset=utf-8',
    txt   => 'text/plain; charset=utf-8',
    html  => 'text/html; charset=utf-8',
    htm   => 'text/html; charset=utf-8',
    css   => 'text/css; charset=utf-8',
    js    => 'text/javascript; charset=utf-8',
    json  => 'application/json; charset=utf-8',
    jsonl => 'application/jsonl; charset=utf-8',
    xml   => 'application/xml; charset=utf-8',
    yaml  => 'text/yaml; charset=utf-8',
    yml   => 'text/yaml; charset=utf-8',
    csv   => 'text/csv; charset=utf-8',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    svg   => 'image/svg+xml',
    ico   => 'image/vnd.microsoft.icon',
    pdf   => 'application/pdf',
    zip   => 'application/zip',
);

our %TEXT_EXTENSIONS = map { $_ => 1 } qw(
    md url txt html htm css js json jsonl xml
    yaml yml csv tsv conf ini log pl pm
    sh bash env example brief
);

sub check_upload_rate {
    my ( $username, $content_length ) = @_;
    my $limits = upload_limits();

    return { ok => 1 }
        if $limits->{rate_count} == 0
        && $limits->{rate_bytes} == 0;

    my $rate_dir  = "$LAZYSITE_DIR/manager";
    my $rate_path = "$rate_dir/.upload-rate.db";
    make_path($rate_dir) unless -d $rate_dir;

    my %db;
    # Note: no assignment of the tie return value - holding a
    # reference to the tied object would trigger "untie attempted
    # while inner references still exist" on the untie below.
    eval { require DB_File; 1 } or do {
        log_event( 'WARN', 'file-upload', 'rate DB tie failed',
            path => $rate_path, error => "DB_File unavailable: $@" );
        return { ok => 1 };
    };
    eval {
        no warnings 'once';
        tie %db, 'DB_File', $rate_path, O_RDWR | O_CREAT, 0o600,
            $DB_File::DB_HASH;
    };
    unless ( tied %db ) {
        log_event( 'WARN', 'file-upload', 'rate DB tie failed',
            path => $rate_path, error => ( $@ || 'tie returned empty' ) );
        return { ok => 1 };    # fail open
    }

    my $hour       = int( time() / 3600 );
    my $count_key  = "$username:$hour:count";
    my $bytes_key  = "$username:$hour:bytes";

    my $cur_count  = $db{$count_key} || 0;
    my $cur_bytes  = $db{$bytes_key} || 0;

    if ( $limits->{rate_count} > 0
        && $cur_count >= $limits->{rate_count} ) {
        untie %db;
        log_event( 'WARN', 'file-upload',
            'rate limit exceeded (count)',
            user => $username, hour => $hour,
            count => $cur_count, limit => $limits->{rate_count} );
        return { ok => 0,
            error => "Upload rate limit reached "
                   . "($limits->{rate_count} per hour)" };
    }

    if ( $limits->{rate_bytes} > 0
        && $cur_bytes + $content_length > $limits->{rate_bytes} ) {
        untie %db;
        log_event( 'WARN', 'file-upload',
            'rate limit exceeded (bytes)',
            user => $username, hour => $hour,
            bytes => $cur_bytes, limit => $limits->{rate_bytes},
            requested => $content_length );
        return { ok => 0,
            error => "Upload size limit reached for this hour" };
    }

    # Reserve up-front. CONTENT_LENGTH includes multipart overhead so
    # this slightly over-counts, which is the safe direction. Counted
    # per request, not per file: a ten-file upload in one request
    # costs one count slot.
    $db{$count_key} = $cur_count + 1;
    $db{$bytes_key} = $cur_bytes + $content_length;

    for my $k ( keys %db ) {
        if ( $k =~ /:(\d+):/ ) {
            delete $db{$k} if $1 < $hour - 1;
        }
    }

    untie %db;
    return { ok => 1 };
}

sub parse_multipart_body {
    my ( $body, $content_type ) = @_;

    my ($q_boundary, $u_boundary) = $content_type =~
        m{multipart/form-data.*?boundary=(?:"([^"]+)"|([^;\s]+))}i;
    my $boundary = $q_boundary // $u_boundary // '';
    return () unless length $boundary;

    my @parts;
    # Relies on well-formed boundaries - a boundary string appearing
    # inside a payload would corrupt parsing. This is the documented
    # multipart assumption; browsers pick random-looking boundaries
    # that make collision vanishingly unlikely.
    for my $chunk ( split /--\Q$boundary\E(?:--)?\r?\n?/, $body ) {
        next unless length $chunk;
        next unless $chunk =~ /\r?\n\r?\n/;

        my ( $headers, $content ) = split /\r?\n\r?\n/, $chunk, 2;
        next unless defined $content;

        $content =~ s/\r?\n\z//;

        my %part;
        if ( $headers =~ /Content-Disposition:\s*[^;]+;(.+)/i ) {
            my $disp = $1;
            ( $part{name} )     = $disp =~ /\bname="([^"]*)"/;
            ( $part{filename} ) = $disp =~ /\bfilename="([^"]*)"/;
        }
        if ( $headers =~ /Content-Type:\s*(\S+)/i ) {
            $part{type} = $1;
        }
        $part{data} = $content;
        push @parts, \%part if defined $part{name};
    }
    return @parts;
}

sub sanitise_upload_filename {
    my ($name) = @_;
    return '' unless defined $name;
    $name =~ s{.*[/\\]}{};             # basename only
    return '' if $name =~ /\0/;        # null bytes
    return '' if $name eq '' || $name eq '.' || $name eq '..';
    $name =~ s/[\x00-\x1f]//g;         # strip control chars
    return $name;
}

sub action_file_upload {
    my ( $rel_dir, $body ) = @_;

    my $ctype = $ENV{CONTENT_TYPE} // '';
    unless ( $ctype =~ m{^multipart/form-data}i ) {
        return { ok => 0, error => "Expected multipart body" };
    }

    $rel_dir //= '/';
    $rel_dir =~ s{^/+}{};
    $rel_dir =~ s{/+$}{};
    my $full_dir = length $rel_dir ? "$DOCROOT/$rel_dir" : $DOCROOT;

    unless ( -d $full_dir ) {
        return { ok => 0, error => "Target is not a directory" };
    }
    my $real = realpath($full_dir);
    unless ( $real && index( $real, $DOCROOT ) == 0 ) {
        return { ok => 0, error => "Invalid target directory" };
    }

    my @parts = parse_multipart_body( $body, $ctype );
    my @files = grep { defined $_->{filename}
                        && length $_->{filename} } @parts;

    unless (@files) {
        return { ok => 0, error => "No files in upload" };
    }

    my $overwrite = 0;
    for my $p (@parts) {
        if ( ( $p->{name} // '' ) eq 'overwrite'
            && ( $p->{data} // '' ) eq '1' ) {
            $overwrite = 1;
        }
    }

    my @saved;
    my @skipped;
    my @errors;

    for my $file (@files) {
        my $fname = sanitise_upload_filename( $file->{filename} );
        unless ( length $fname ) {
            push @errors, { name => $file->{filename},
                            error => 'Invalid filename' };
            next;
        }

        my $rel_target = length $rel_dir
            ? "$rel_dir/$fname"
            : $fname;

        if ( is_blocked_path($rel_target)
            || is_blocked_config( $rel_target, 1 ) ) {
            push @errors, { name => $fname,
                            error => 'Blocked target' };
            next;
        }

        my $full_target = "$DOCROOT/$rel_target";

        if ( -e $full_target && !$overwrite ) {
            push @skipped, $fname;
            next;
        }

        my $tmp = "$full_target.tmp.$$";
        unless ( open my $fh, '>', $tmp ) {
            push @errors, { name => $fname,
                            error => "Cannot write: $!" };
            next;
        }
        else {
            binmode $fh;
            unless ( print {$fh} $file->{data} ) {
                my $err = "$!";
                close $fh;
                unlink $tmp;
                push @errors, { name => $fname,
                                error => "Write failed: $err" };
                next;
            }
            unless ( close $fh ) {
                my $err = "$!";
                unlink $tmp;
                push @errors, { name => $fname,
                                error => "Close failed: $err" };
                next;
            }
        }

        unless ( rename $tmp, $full_target ) {
            my $err = "$!";
            unlink $tmp;
            push @errors, { name => $fname,
                            error => "Cannot rename: $err" };
            next;
        }

        my @st = stat $full_target;
        push @saved, {
            name  => $fname,
            path  => $rel_target,
            size  => $st[7] // 0,
            mtime => $st[9] // 0,
        };

        log_event( 'INFO', 'file-upload', 'file uploaded',
            path => $rel_target, size => $st[7] // 0,
            user => $auth_user );

        if ( $full_target =~ /\.md$/ ) {
            ( my $cache = $full_target ) =~ s/\.md$/.html/;
            unlink $cache if -f $cache;
        }
    }

    # ok=1 means the request was processed. The client inspects
    # saved/skipped/errors to decide what to show. Returning ok=0
    # when all files were skipped-no-overwrite would make the
    # client show "Upload failed" instead of the overwrite prompt.
    return {
        ok      => 1,
        saved   => \@saved,
        skipped => \@skipped,
        errors  => \@errors,
    };
}

sub detect_content_type {
    my ($path) = @_;
    my ($ext) = $path =~ /\.([^.\/]+)$/;
    return 'application/octet-stream' unless defined $ext;
    return $CONTENT_TYPE_MAP{ lc $ext }
        // 'application/octet-stream';
}

sub is_editable_text {
    my ($path) = @_;
    my ($ext) = $path =~ /\.([^.\/]+)$/;
    return 1 unless defined $ext;   # no extension: assume text
    return $TEXT_EXTENSIONS{ lc $ext } ? 1 : 0;
}

sub action_file_download {
    my ($rel_path) = @_;

    my $result = validate_path($rel_path);
    unless ( $result->{ok} ) {
        respond({ ok => 0, error => $result->{error} });
        return;
    }

    # SM019 decision point: consult is_blocked_path on download so a
    # manager cannot grab lazysite/auth/.secret (or any .pl) through
    # this action just because action_read blocks them. The briefing
    # did not specify this; added for parity with read/save/delete.
    if ( is_blocked_path( $result->{rel} ) ) {
        respond({ ok => 0, error => "Path is blocked" });
        return;
    }
    # SM019c: config block list applies to downloads too, so a
    # caller cannot siphon the manager UI or any other configured
    # sensitive directory via this surface.
    if ( is_blocked_config( $result->{rel} ) ) {
        respond({ ok => 0, error => "Path is blocked by config" });
        return;
    }

    my $full = $result->{full};

    unless ( -f $full ) {
        respond({ ok => 0, error => "File not found" });
        return;
    }
    if ( -d $full ) {
        respond({ ok => 0, error => "Not a file" });
        return;
    }

    my $basename = basename($full);
    my $ctype    = detect_content_type($full);
    my $size     = ( stat $full )[7] // 0;

    ( my $safe_name = $basename ) =~ s/[\r\n"\\]//g;

    log_event( 'DEBUG', 'file-download', 'file downloaded',
        path => $result->{rel}, size => $size,
        user => $auth_user );

    # syswrite below bypasses Perl's stdio buffer; without autoflush
    # the print-ed headers land in stdout AFTER the body bytes.
    binmode STDOUT;
    local $| = 1;
    print "Status: 200 OK\r\n";
    print "Content-Type: $ctype\r\n";
    print "Content-Length: $size\r\n";
    print "Content-Disposition: attachment; filename=\"$safe_name\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";

    open my $fh, '<', $full or return;
    binmode $fh;
    my $buf;
    while ( my $n = sysread( $fh, $buf, 65536 ) ) {
        syswrite STDOUT, $buf, $n;
    }
    close $fh;
}

sub collect_zip_paths {
    my @paths;
    for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && defined $v;
        next unless $k eq 'paths' || $k eq 'paths[]';
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $v =~ s/\+/ /g;
        push @paths, $v if length $v;
    }
    return @paths;
}

sub action_file_zip_download {
    my @requested = collect_zip_paths();
    unless (@requested) {
        respond({ ok => 0, error => "No files selected" });
        return;
    }

    my $max_total = upload_limits()->{max_bytes} * 10;

    require Archive::Zip;
    Archive::Zip->import(qw(:ERROR_CODES));

    my $zip   = Archive::Zip->new();
    my $total = 0;
    my $added = 0;

    for my $rel (@requested) {
        my $vr = validate_path($rel);
        unless ( $vr->{ok} ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (invalid path)',
                path => $rel, user => $auth_user );
            next;
        }
        if ( is_blocked_path( $vr->{rel} ) ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (blocked path)',
                path => $rel, user => $auth_user );
            next;
        }
        # SM019c: config block list applies to zip-download too,
        # mirroring single-file download.
        if ( is_blocked_config( $vr->{rel} ) ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (blocked by config)',
                path => $rel, user => $auth_user );
            next;
        }

        my $full = $vr->{full};
        unless ( -f $full ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (not a file)',
                path => $rel, user => $auth_user );
            next;
        }

        my $size = ( stat $full )[7] // 0;
        $total += $size;
        if ( $total > $max_total ) {
            respond({ ok => 0, error => "Total size exceeds limit" });
            return;
        }

        $zip->addFile( $full, $vr->{rel} );
        $added++;
    }

    unless ($added) {
        respond({ ok => 0, error => "No valid files" });
        return;
    }

    require File::Temp;
    my $tmp = File::Temp->new(
        TEMPLATE => 'lazysite-zip-XXXXXX',
        SUFFIX   => '.zip',
        TMPDIR   => 1,
    );
    my $tmp_path = $tmp->filename;

    unless ( $zip->writeToFileNamed($tmp_path) == 0 ) {    # AZ_OK
        respond({ ok => 0, error => "Zip write failed" });
        return;
    }

    my $zip_size = ( stat $tmp_path )[7] // 0;
    my $ts       = strftime( '%Y%m%d-%H%M%S', localtime );
    my $fname    = "lazysite-files-$ts.zip";

    log_event( 'INFO', 'file-zip-download', 'zip downloaded',
        count => $added, size => $zip_size,
        user => $auth_user );

    binmode STDOUT;
    local $| = 1;    # flush headers before the syswrite loop
    print "Status: 200 OK\r\n";
    print "Content-Type: application/zip\r\n";
    print "Content-Length: $zip_size\r\n";
    print "Content-Disposition: attachment; filename=\"$fname\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";

    open my $fh, '<', $tmp_path or return;
    binmode $fh;
    my $buf;
    while ( my $n = sysread( $fh, $buf, 65536 ) ) {
        syswrite STDOUT, $buf, $n;
    }
    close $fh;
}

1;
