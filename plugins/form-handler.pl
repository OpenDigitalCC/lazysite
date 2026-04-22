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

my $LOG_COMPONENT = 'form-handler';

if ( grep { $_ eq '--describe' } @ARGV ) {
    print encode_json({
        id          => 'form-handler',
        name        => 'Form Handler',
        description => 'Receives and dispatches contact form submissions',
        version     => '1.1',
        config_file => '',
        config_schema => [],
        handler_types => [
            {
                type   => 'smtp',
                label  => 'Send email (SMTP)',
                schema => [
                    { key => 'name',           label => 'Name',           type => 'text',    required => JSON::PP::true, default => 'Email delivery' },
                    { key => 'enabled',        label => 'Enabled',        type => 'boolean', default => 'true' },
                    { key => 'from',           label => 'From address',   type => 'email',   required => JSON::PP::true, default => 'webforms@example.com' },
                    { key => 'to',             label => 'To address',     type => 'email',   required => JSON::PP::true, default => 'admin@example.com' },
                    { key => 'subject_prefix', label => 'Subject prefix', type => 'text',    default => '[Contact] ' },
                ],
                note => 'SMTP connection settings (host, port, TLS) are configured under the Email (SMTP) group header.',
            },
            {
                type   => 'file',
                label  => 'Save to file',
                schema => [
                    { key => 'name',    label => 'Name',              type => 'text',    required => JSON::PP::true },
                    { key => 'enabled', label => 'Enabled',           type => 'boolean', default => 'true' },
                    { key => 'path',    label => 'Storage directory',  type => 'text',    default => 'lazysite/forms/submissions' },
                ],
            },
            {
                type   => 'webhook',
                label  => 'Webhook',
                schema => [
                    { key => 'name',    label => 'Name',        type => 'text',   required => JSON::PP::true },
                    { key => 'enabled', label => 'Enabled',     type => 'boolean', default => 'true' },
                    { key => 'url',     label => 'Webhook URL',  type => 'text',   required => JSON::PP::true },
                    { key => 'format',  label => 'Format',       type => 'select', options => ['json', 'slack'], default => 'json' },
                ],
            },
        ],
        child_configs => {
            pattern    => 'lazysite/forms/*.conf',
            exclude    => ['smtp.conf', 'handlers.conf'],
            label_from => 'filename',
        },
        actions => [],
    });
    exit 0;
}

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

    # Tag submission with the authenticated user if present
    my $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
    $form{_auth_user} = $auth_user if length $auth_user;

    my $conf = load_form_conf($name);
    my %handlers = load_handlers();

    check_honeypot( $form{_hp} // '' );
    check_timestamp( $form{_ts} // '', $form{_tk} // '', load_form_secret() );
    check_rate_limit( $ENV{REMOTE_ADDR} // '0.0.0.0' );

    for my $target ( @{ $conf->{targets} } ) {
        dispatch( $target, \%form, \%handlers );
    }

    log_event( 'INFO', $name, 'form received', ip => $ENV{REMOTE_ADDR} // 'unknown' );
    respond_ok('Thank you - your message has been sent.');
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    my $fname = '';
    log_event( 'ERROR', $fname, 'processing failed', error => $err, ip => $ENV{REMOTE_ADDR} // 'unknown' );
    respond_error('An error occurred - please try again.');
}

# --- Config ---

sub load_handlers {
    my $path = "$FORMS_DIR/handlers.conf";
    return () unless -f $path;

    open my $fh, '<:utf8', $path or return ();
    my $text = do { local $/; <$fh> };
    close $fh;

    my %handlers;
    while ( $text =~ /^\s{2}-\s+id:\s*(\S+)(.*?)(?=^\s{2}-\s+id:|\z)/gmsx ) {
        my ( $id, $block ) = ( $1, $2 );
        my %h = ( id => $id );
        while ( $block =~ /^\s{4}(\w+)\s*:\s*(.+)$/mg ) {
            $h{$1} = $2;
            $h{$1} =~ s/\s+$//;
        }
        $handlers{$id} = \%h;
    }

    return %handlers;
}

sub load_form_conf {
    my ($name) = @_;
    my $path = "$FORMS_DIR/$name.conf";
    reject("Form '$name' not configured") unless -f $path;

    open( my $fh, '<:utf8', $path ) or reject("Cannot read form config");
    my $text = do { local $/; <$fh> };
    close $fh;

    my @targets;

    # New format: handler references
    while ( $text =~ /^\s*-\s+handler:\s*(\S+)/mg ) {
        push @targets, { handler => $1 };
    }

    # Legacy format: inline type config
    if ( !@targets ) {
        while ( $text =~ /^\s*-\s+type:\s*(\w+)\s*$(.*?)(?=^\s*-\s+type:|\z)/gms ) {
            my ( $type, $block ) = ( $1, $2 );
            my %t = ( type => $type );
            $t{url}    = $1 if $block =~ /^\s*url:\s*(.+)$/m;
            $t{format} = $1 if $block =~ /^\s*format:\s*(.+)$/m;
            $t{path}   = $1 if $block =~ /^\s*path:\s*(.+)$/m;
            $t{$_} =~ s/^\s+|\s+$//g for grep { defined $t{$_} } keys %t;
            push @targets, \%t;
        }
    }

    reject("No targets configured for form '$name'") unless @targets;
    return { targets => \@targets };
}

# --- Dispatch ---

sub dispatch {
    my ( $target, $form, $handlers_ref ) = @_;

    my %h_config;
    if ( $target->{handler} ) {
        my $id = $target->{handler};
        unless ( $handlers_ref->{$id} ) {
            log_event( 'WARN', $form->{_form} // '-', 'unknown handler', handler => $id );
            return;
        }
        %h_config = %{ $handlers_ref->{$id} };

        if ( lc( $h_config{enabled} // 'true' ) eq 'false' ) {
            return;
        }
    }
    else {
        %h_config = %$target;
    }

    my $type = $h_config{type} // '';

    if    ( $type eq 'file' )    { dispatch_file( \%h_config, $form ) }
    elsif ( $type eq 'smtp' )    { dispatch_smtp( \%h_config, $form ) }
    elsif ( $type eq 'webhook' || $type eq 'api' ) { dispatch_webhook( \%h_config, $form ) }
    else {
        log_event( 'WARN', $form->{_form} // '-', 'unknown handler type', type => $type );
    }
}

sub dispatch_file {
    my ( $config, $form ) = @_;

    my $dir = $config->{path} || 'lazysite/forms/submissions';
    $dir = "$DOCROOT/$dir" unless $dir =~ m{^/};
    make_path($dir) unless -d $dir;

    my $form_name = $form->{_form} // 'unknown';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;

    my %record;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $record{$k} = $form->{$k};
    }
    $record{_submitted} = strftime( '%Y-%m-%dT%H:%M:%S', localtime );
    $record{_ip}        = $ENV{REMOTE_ADDR} // 'unknown';
    $record{_form}      = $form_name;

    my $log_path = "$dir/$form_name.jsonl";
    open( my $fh, '>>:utf8', $log_path ) or do {
        log_event( 'ERROR', $form->{_form} // '-', 'file write failed', path => $log_path, error => $! );
        return;
    };
    flock( $fh, LOCK_EX );
    print $fh encode_json( \%record ) . "\n";
    flock( $fh, LOCK_UN );
    close $fh;
}

sub dispatch_smtp {
    my ( $config, $form ) = @_;

    my $script = find_script('form-smtp.pl');
    unless ($script) {
        log_event( 'WARN', $form->{_form} // '-', 'smtp script not found' );
        return;
    }

    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my %payload = ( config => $config, form => \%fields );
    my $json = encode_json( \%payload );

    require IPC::Open2;
    my ( $child_out, $child_in );
    my $pid = IPC::Open2::open2( $child_out, $child_in, $^X, $script, '--pipe' );
    print $child_in $json;
    close $child_in;
    my $result = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;

    my $r = eval { decode_json( $result // '' ) } // {};
    unless ( $r->{ok} ) {
        log_event( 'WARN', $form->{_form} // '-', 'smtp dispatch failed',
            error => ( $r->{error} // 'no output' ) );
    }
}

sub dispatch_webhook {
    my ( $config, $form ) = @_;
    my $url = $config->{url} or return;

    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my $body;
    if ( ( $config->{format} // 'json' ) eq 'slack' ) {
        my $text = join "\n", map { "*$_*: $fields{$_}" } sort keys %fields;
        $body = encode_json( { text => $text } );
    }
    else {
        $body = encode_json( \%fields );
    }

    require LWP::UserAgent;
    my $ua  = LWP::UserAgent->new( timeout => 10 );
    my $res = $ua->post( $url,
        'Content-Type' => 'application/json',
        Content        => $body );

    unless ( $res->is_success ) {
        log_event( 'WARN', $form->{_form} // '-', 'webhook failed',
            url => $url, status => $res->status_line );
    }
}

sub find_script {
    my ($name) = @_;
    # D022: $DOCROOT/../plugins/ is now the canonical home.
    # The other paths stay as fallbacks so 0.1.0 installs
    # still work during the upgrade transition, and operators
    # who choose a system-wide install layout keep working.
    for my $path (
        "$DOCROOT/../plugins/$name",
        "$DOCROOT/../cgi-bin/$name",
        "$DOCROOT/../$name",
        "/usr/local/lib/lazysite/$name",
    ) {
        return $path if -f $path;
    }
    return;
}

# --- POST parsing ---

sub parse_post {
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    my $type = $ENV{CONTENT_TYPE}   || '';
    my $data = '';

    if ( $len > 0 ) { read( STDIN, $data, $len ); }
    else            { local $/; $data = <STDIN> // ''; }

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
    reject('Submission too fast')  if $age < 3;
    reject('Submission expired')   if $age > 7200;
}

sub check_rate_limit {
    my ($ip) = @_;
    return unless $ip;
    _ensure_dir_for("$FORMS_DIR/.rate-limit.db");
    my %db;
    tie( %db, 'DB_File', "$FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_HASH ) or return;
    my $hour = int( time() / 3600 );
    my $key  = "$ip:$hour";
    my $count = $db{$key} || 0;
    if ( $count >= 5 ) { untie %db; reject('Rate limit exceeded'); }
    $db{$key} = $count + 1;
    for my $k ( keys %db ) {
        delete $db{$k} if $k =~ /:(\d+)$/ && $1 < $hour - 1;
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

sub reject { die "$_[0]\n"; }

# --- Utilities ---

sub sanitise_header {
    my ( $val, $max ) = @_;
    $max //= 1000;
    $val =~ s/[\r\n]/ /g;
    $val = substr( $val, 0, $max ) if length($val) > $max;
    return $val;
}

sub _ensure_dir_for {
    my ($path) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
}

sub log_event {
    my ($level, $context, $message, %extra) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map  { '"' . _json_str($_) . '":"' . _json_str($extra{$_}) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"'     . _json_str($level)          . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT)  . '"'
            . ',"context":"'   . _json_str($context)        . '"'
            . ',"message":"'   . _json_str($message)        . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
