#!/usr/bin/perl
# lazysite-form-handler.pl - form POST receiver, validation, dispatch
use strict;
use warnings;
use POSIX qw(strftime);
use Digest::SHA qw(hmac_sha256_hex);
use Fcntl qw(:flock O_RDWR O_CREAT);
use DB_File;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json decode_json);
use LWP::UserAgent;

my $DOCROOT      = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $FORMS_DIR    = "$LAZYSITE_DIR/forms";

# --- Main ---

eval {
    reject('Method not allowed')
        unless ( $ENV{REQUEST_METHOD} // '' ) eq 'POST';

    my %form    = parse_post();
    my $name    = $form{_form} // '';
    $name =~ s/[^a-zA-Z0-9_-]//g;
    reject('Missing form name') unless $name;

    my $conf = load_form_conf($name);

    check_honeypot( $form{_hp} // '' );
    check_timestamp( $form{_ts} // '', $form{_tk} // '', load_form_secret() );
    check_rate_limit( $ENV{REMOTE_ADDR} // '0.0.0.0' );

    for my $target ( @{ $conf->{targets} } ) {
        dispatch( $target, \%form );
    }

    log_event( 'OK', "form=$name", $ENV{REMOTE_ADDR} // 'unknown' );
    respond_ok('Thank you - your message has been sent.');
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    log_event( 'ERROR', $err, $ENV{REMOTE_ADDR} // 'unknown' );
    respond_error('An error occurred - please try again.');
}

# --- POST parsing ---

sub parse_post {
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    my $type = $ENV{CONTENT_TYPE}   || '';
    my $data = '';

    if ( $len > 0 ) {
        read( STDIN, $data, $len );
    }
    else {
        local $/;
        $data = <STDIN> // '';
    }

    my %form;

    if ( $type =~ m{multipart/form-data.*boundary=(.+)}i ) {
        my $boundary = $1;
        $boundary =~ s/^\s+|\s+$//g;
        for my $part ( split /--\Q$boundary\E/, $data ) {
            next unless $part =~ /name="([^"]+)"/;
            my $name = $1;
            $part =~ s/\A.*?\r?\n\r?\n//s;
            $part =~ s/\r?\n\z//;
            $form{$name} = sanitise_header( $part, 10000 );
        }
    }
    else {
        for my $pair ( split /&/, $data ) {
            my ( $k, $v ) = split /=/, $pair, 2;
            next unless defined $k;
            $k =~ s/\+/ /g;
            $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $v //= '';
            $v =~ s/\+/ /g;
            $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $form{$k} = sanitise_header( $v, 10000 );
        }
    }

    return %form;
}

# --- Security ---

sub check_honeypot {
    my ($hp) = @_;
    reject('Spam detected') if defined $hp && length $hp;
}

sub check_timestamp {
    my ( $ts, $tk, $secret ) = @_;
    reject('Invalid submission') unless $ts && $tk;
    reject('Invalid submission') unless $ts =~ /^\d+$/;

    my $expected = hmac_sha256_hex( $ts, $secret );
    reject('Invalid submission') unless $tk eq $expected;

    my $age = time() - $ts;
    reject('Submission too fast')   if $age < 3;
    reject('Submission expired')    if $age > 7200;
}

sub check_rate_limit {
    my ($ip) = @_;
    return unless $ip;

    _ensure_dir_for("$FORMS_DIR/.rate-limit.db");

    my %db;
    tie( %db, 'DB_File', "$FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0600, $DB_HASH )
        or return;    # fail open if DB unavailable

    my $now  = time();
    my $hour = int( $now / 3600 );
    my $key  = "$ip:$hour";

    my $count = $db{$key} || 0;
    if ( $count >= 5 ) {
        untie %db;
        reject('Rate limit exceeded - please try again later');
    }

    $db{$key} = $count + 1;

    # Clean old entries (older than 2 hours)
    for my $k ( keys %db ) {
        if ( $k =~ /:(\d+)$/ ) {
            delete $db{$k} if $1 < $hour - 1;
        }
    }

    untie %db;
}

sub load_form_secret {
    my $secret_path = "$FORMS_DIR/.secret";
    _ensure_dir_for($secret_path);

    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or die "Cannot read form secret\n";
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }

    die "Form secret not found - render a form page first to generate it\n";
}

# --- Config ---

sub load_form_conf {
    my ($name) = @_;
    my $path = "$FORMS_DIR/$name.conf";
    reject("Form '$name' not configured") unless -f $path;

    open( my $fh, '<:utf8', $path ) or reject("Cannot read form config");
    local $/;
    my $text = <$fh>;
    close($fh);

    my @targets;
    while ( $text =~ /^\s*-\s+type:\s*(\w+)\s*$(.*?)(?=^\s*-\s+type:|\z)/gms ) {
        my ( $type, $block ) = ( $1, $2 );
        my %t = ( type => $type );
        $t{url}    = $1 if $block =~ /^\s*url:\s*(.+)$/m;
        $t{format} = $1 if $block =~ /^\s*format:\s*(.+)$/m;
        $t{$_} =~ s/^\s+|\s+$//g for grep { defined $t{$_} } keys %t;
        push @targets, \%t;
    }

    reject("No targets configured for form '$name'") unless @targets;
    return { targets => \@targets };
}

# --- Dispatch ---

sub dispatch {
    my ( $target, $form ) = @_;
    my $type = $target->{type} || '';

    if ( $type eq 'smtp' ) {
        dispatch_smtp( $target, $form );
    }
    elsif ( $type eq 'api' ) {
        dispatch_api( $target, $form );
    }
    else {
        log_event( 'WARN', "Unknown target type: $type",
            $ENV{REMOTE_ADDR} // '' );
    }
}

sub dispatch_smtp {
    my ( $target, $form ) = @_;
    my $url = $target->{url} or return;

    # Collect non-internal fields
    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my $ua = LWP::UserAgent->new( timeout => 15 );
    my $resp = $ua->post(
        $url,
        Content_Type => 'application/json',
        Content      => encode_json( \%fields ),
    );

    unless ( $resp->is_success ) {
        log_event( 'ERROR', "SMTP dispatch failed: " . $resp->status_line,
            $ENV{REMOTE_ADDR} // '' );
    }
}

sub dispatch_api {
    my ( $target, $form ) = @_;
    my $url    = $target->{url}    or return;
    my $format = $target->{format} || 'json';

    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my $ua = LWP::UserAgent->new( timeout => 15 );
    my $payload;

    if ( $format eq 'slack' ) {
        my $text = join "\n", map { "$_: $fields{$_}" } sort keys %fields;
        $payload = encode_json( { text => $text } );
    }
    else {
        $payload = encode_json( \%fields );
    }

    my $resp = $ua->post(
        $url,
        Content_Type => 'application/json',
        Content      => $payload,
    );

    unless ( $resp->is_success ) {
        log_event( 'WARN', "API dispatch to $url: " . $resp->status_line,
            $ENV{REMOTE_ADDR} // '' );
    }
}

# --- Response ---

sub respond_ok {
    my ($msg) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1, message => $msg } );
}

sub respond_error {
    my ($msg) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $msg } );
}

sub reject {
    my ($msg) = @_;
    die "$msg\n";
}

# --- Utilities ---

sub sanitise_header {
    my ( $val, $max ) = @_;
    $max //= 1000;
    $val =~ s/[\r\n]/ /g;
    $val = substr( $val, 0, $max ) if length($val) > $max;
    return $val;
}

sub sanitise_email {
    my ($val) = @_;
    $val =~ s/[\r\n<>]//g;
    return $val;
}

sub _ensure_dir_for {
    my ($path) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
}

sub log_event {
    my ( $level, $msg, $ip ) = @_;
    $ip //= '';
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );

    my $log_path = "$FORMS_DIR/handler.log";
    if ( open( my $fh, '>>', $log_path ) ) {
        flock( $fh, LOCK_EX );
        print $fh "[$ts] $level ip=$ip $msg\n";
        flock( $fh, LOCK_UN );
        close($fh);
    }
    else {
        warn "lazysite-form-handler: [$ts] $level ip=$ip $msg\n";
    }
}
