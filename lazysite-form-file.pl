#!/usr/bin/perl
# lazysite-form-file.pl - file-based form submission handler
# Appends submissions as JSON lines to a log file per form.
# Default handler - works without any external config.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Basename qw(dirname);

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'form-file',
        name        => 'Form File Storage',
        description => 'Save form submissions to structured JSON log files',
        version     => '1.0',
        config_file => 'lazysite/forms/file-storage.conf',
        config_schema => [
            { key => 'submissions_dir', label => 'Storage directory', type => 'text',
              default => 'lazysite/forms/submissions',
              help => 'Relative to docroot. Each form saves to FORMNAME.jsonl in this directory.' },
        ],
        actions     => [],
    });
    exit 0;
}

my $DOCROOT      = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";

# Read config
my $SUBMISSIONS_DIR = "$LAZYSITE_DIR/forms/submissions";
my $conf_path = "$LAZYSITE_DIR/forms/file-storage.conf";
if ( -f $conf_path ) {
    open my $fh, '<:utf8', $conf_path;
    while (<$fh>) {
        if ( /^submissions_dir\s*:\s*(.+)/ ) {
            my $dir = $1;
            $dir =~ s/^\s+|\s+$//g;
            $SUBMISSIONS_DIR = "$DOCROOT/$dir" if length $dir;
            last;
        }
    }
    close $fh;
}

# --- Main ---

eval {
    my $json = do { local $/; <STDIN> };
    die "No input\n" unless defined $json && length $json;

    my $form = decode_json($json);

    # Form name from _form field (set by handler) or default
    my $form_name = $form->{_form} // 'unknown';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    $form_name = 'unknown' unless length $form_name;

    # Build submission record
    my %record;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;  # skip internal fields
        $record{$k} = $form->{$k};
    }
    $record{_submitted} = strftime('%Y-%m-%dT%H:%M:%S', localtime);
    $record{_ip}        = $ENV{REMOTE_ADDR} // 'unknown';
    $record{_form}      = $form_name;

    # Write to JSONL file (one JSON object per line)
    make_path($SUBMISSIONS_DIR) unless -d $SUBMISSIONS_DIR;
    my $log_path = "$SUBMISSIONS_DIR/$form_name.jsonl";

    open( my $fh, '>>:utf8', $log_path )
        or die "Cannot write to $log_path: $!\n";
    flock( $fh, LOCK_EX );
    print $fh encode_json(\%record) . "\n";
    flock( $fh, LOCK_UN );
    close $fh;

    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json({ ok => 1 });
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    _log_central( 'ERROR', "form-file: $err" );
    warn "lazysite-form-file: $err\n";
    binmode( STDOUT, ':utf8' );
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json({ ok => 0, error => $err });
}

sub _log_central {
    my ( $level, $msg ) = @_;
    eval {
        my $log_dir  = "$LAZYSITE_DIR/logs";
        my $log_path = "$log_dir/lazysite.log";
        make_path($log_dir) unless -d $log_dir;
        open( my $fh, '>>:utf8', $log_path ) or return;
        flock( $fh, 2 );
        my $ts = strftime( '%Y-%m-%dT%H:%M:%S', localtime );
        my $ip = $ENV{REMOTE_ADDR} // '';
        print $fh "[$ts] $level ip=$ip $msg\n";
        flock( $fh, 8 );
        close $fh;
    };
}
