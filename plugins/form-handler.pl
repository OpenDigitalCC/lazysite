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
                    { key => 'attach_files',   label => 'Attach uploaded files', type => 'boolean', default => 'false',
                      note => 'When on, files uploaded with the form are attached to the email and listed (name + size) below the message. Off by default. Mind your mail server\'s attachment size limits.' },
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

# Hard ceiling on a POST body, so a hostile upload can't exhaust memory before the
# per-form size limits are even checked. Generous; real limits are per-form.
my $MAX_POST_BYTES = 64 * 1024 * 1024;

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

    # Binary uploads: reject up front (before any handler runs) if the form does
    # not accept files, or a file breaks the form's size / type / count limits.
    if ( my $files = $form{_files} ) {
        reject_user('This form does not accept file uploads.') unless $conf->{upload};
        validate_uploads( $files, $conf->{upload} );
    }

    # Reject a contentless submission - every visible field blank and no file
    # uploaded. HTML5 `required` stops this in a browser, so it is almost always an
    # automated/blank POST; saving a "thank you" + an empty record is worse than an
    # honest error.
    my $has_content = ( $form{_files} && @{ $form{_files} } ) ? 1 : 0;
    unless ($has_content) {
        for my $k ( keys %form ) {
            next if $k =~ /^_/;
            if ( defined $form{$k} && $form{$k} =~ /\S/ ) { $has_content = 1; last }
        }
    }
    reject_user('Please fill in the form before submitting.') unless $has_content;

    my $delivered = 0;
    for my $target ( @{ $conf->{targets} } ) {
        $delivered += ( dispatch( $target, \%form, \%handlers ) ? 1 : 0 );
    }

    # If NOTHING actually accepted the submission - every target disabled, unknown,
    # or failed (e.g. the form handler / its delivery plugin is turned off) - the
    # submission was NOT saved. Fail loudly instead of showing a false "thank you".
    unless ($delivered) {
        log_event( 'ERROR', $name, 'form not delivered - no active target',
            ip => $ENV{REMOTE_ADDR} // 'unknown' );
        reject_user( 'This form is not accepting submissions right now '
            . '(no active delivery target). Please contact the site owner.' );
    }

    log_event( 'INFO', $name, 'form received', ip => $ENV{REMOTE_ADDR} // 'unknown' );
    _audit_submission( $name, $auth_user, $ENV{REMOTE_ADDR} // '' );
    _notify_submission($name);   # SM113: operator notification badge
    respond_ok('Thank you - your message has been sent.');
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    my $fname = '';
    log_event( 'ERROR', $fname, 'processing failed', error => $err, ip => $ENV{REMOTE_ADDR} // 'unknown' );
    # USER: messages (e.g. upload too large / wrong type) are safe to show the
    # submitter; everything else gets a generic message.
    if ( $err =~ /^USER:(.*)/s ) { respond_error($1); }
    else { respond_error('An error occurred - please try again.'); }
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

    # Optional binary-upload constraints. Present any of these keys to enable file
    # uploads on the form; absent = the form accepts no files.
    #   upload_max_kb:    <int>           max size of EACH file, KiB
    #   upload_max_files: <int>           max number of files per submission
    #   upload_accept:    jpg, png, pdf   allowed extensions (also matched loosely
    #                                     against the part's Content-Type)
    my $upload;
    if ( $text =~ /^\s*upload_(?:max_kb|max_files|accept)\s*:/m ) {
        my ($kb)    = $text =~ /^\s*upload_max_kb\s*:\s*(\d+)/m;
        my ($maxn)  = $text =~ /^\s*upload_max_files\s*:\s*(\d+)/m;
        my ($acc)   = $text =~ /^\s*upload_accept\s*:\s*(.+?)\s*$/m;
        my @accept  = grep { length }
                      map { my $x = lc $_; $x =~ s/^\s+|\s+$//g; $x =~ s/^\.//; $x }
                      split /[,\s|]+/, ( $acc // '' );
        $upload = {
            max_kb    => ( $kb   ? $kb   + 0 : 5120 ),     # 5 MiB default
            max_files => ( $maxn ? $maxn + 0 : 5 ),
            accept    => \@accept,                          # empty = any type
        };
    }

    return { targets => \@targets, upload => $upload };
}

# --- Dispatch ---

sub dispatch {
    my ( $target, $form, $handlers_ref ) = @_;

    my %h_config;
    if ( $target->{handler} ) {
        my $id = $target->{handler};
        unless ( $handlers_ref->{$id} ) {
            log_event( 'WARN', $form->{_form} // '-', 'unknown handler', handler => $id );
            return 0;
        }
        %h_config = %{ $handlers_ref->{$id} };

        if ( lc( $h_config{enabled} // 'true' ) eq 'false' ) {
            return 0;          # handler disabled - did NOT deliver
        }
    }
    else {
        %h_config = %$target;
    }

    my $type = $h_config{type} // '';

    if    ( $type eq 'file' )    { return dispatch_file( \%h_config, $form ) }
    elsif ( $type eq 'smtp' )    { return dispatch_smtp( \%h_config, $form ) }
    elsif ( $type eq 'webhook' || $type eq 'api' ) { return dispatch_webhook( \%h_config, $form ) }
    else {
        log_event( 'WARN', $form->{_form} // '-', 'unknown handler type', type => $type );
        return 0;
    }
}

# SM115: record a submission in the audit trail. The submitter is the public, so the
# user is usually blank; written directly in Lazysite::Audit's pipe format (origin
# "form"), since the handler does not load the lib.
sub _audit_submission {
    my ( $form, $user, $ip ) = @_;
    my $logdir = "$DOCROOT/lazysite/logs";
    return unless -d $logdir;
    $_ = defined $_ ? "$_" : '' for ( $form, $user, $ip );
    s/[|\r\n]+/ /g for ( $form, $user, $ip );
    my $ts = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    open my $fh, '>>', "$logdir/audit.log" or return;
    print {$fh} "$ts | $user | submit | $form | $ip | ok | form\n";
    close $fh;
    return;
}

# SM113: raise an operator notification for a new submission. Append-only store
# the manager reads for its unread badge. Best-effort (never blocks delivery).
sub _notify_submission {
    my ($form) = @_;
    my $logdir = "$DOCROOT/lazysite/logs";
    return unless -d $logdir;
    ( my $f = defined $form ? "$form" : '' ) =~ s/[\r\n]+/ /g;
    my $line = encode_json({
        ts      => time(),
        type    => 'submission',
        message => "New form submission: $f",
        target  => $f,
        url     => '/manager/plugins',
    });
    open my $fh, '>>', "$logdir/notices.jsonl" or return;
    print {$fh} "$line\n";
    close $fh;
    return;
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

    # Binary uploads: store the files in a per-submission subdir next to the
    # <form>.jsonl, and record the (sanitised) filenames + their dir in the record.
    if ( $form->{_files} && @{ $form->{_files} } ) {
        my $id = strftime( '%Y%m%dT%H%M%S', localtime )
               . '-' . sprintf( '%04x', int( rand 65536 ) );
        my ( $saved, $rel ) = save_uploads( $form->{_files}, $dir, $form_name, $id );
        if (@$saved) {
            $record{_files}     = $saved;
            $record{_files_dir} = $rel;
        }
    }

    my $log_path = "$dir/$form_name.jsonl";
    open( my $fh, '>>:utf8', $log_path ) or do {
        log_event( 'ERROR', $form->{_form} // '-', 'file write failed', path => $log_path, error => $! );
        return 0;
    };
    flock( $fh, LOCK_EX );
    print $fh encode_json( \%record ) . "\n";
    flock( $fh, LOCK_UN );
    close $fh;
    return 1;
}

# Enforce the form's upload constraints; reject() (die) on the first violation.
sub validate_uploads {
    my ( $files, $cfg ) = @_;
    reject_user("Too many files (max $cfg->{max_files}).")
        if @$files > $cfg->{max_files};
    my %ok = map { $_ => 1 } @{ $cfg->{accept} };
    for my $f (@$files) {
        my $kb = int( ( length( $f->{data} ) + 1023 ) / 1024 );
        reject_user("File '$f->{filename}' is too large (max $cfg->{max_kb} KiB).")
            if $kb > $cfg->{max_kb};
        next unless keys %ok;
        my ($ext) = lc( $f->{filename} ) =~ /\.([a-z0-9]+)$/;
        reject_user( "File type not allowed: $f->{filename} (accepted: "
                . join( ', ', @{ $cfg->{accept} } ) . ').' )
            unless $ext && $ok{$ext};
    }
    return;
}

# Path-safe: strip any directory component (traversal) and keep a conservative
# whitelist of characters. Returns a bare, safe basename.
sub _safe_filename {
    my ($n) = @_;
    $n =~ s{.*[\\/]}{};
    $n =~ s/[^A-Za-z0-9._-]/_/g;
    $n =~ s/^\.+//;
    $n = 'file' unless length $n;
    return substr( $n, 0, 100 );
}

# Write the uploaded files into <dir>/<form>.files/<id>/. Returns (\@saved_names,
# $relative_subdir).
sub save_uploads {
    my ( $files, $dir, $form_name, $id ) = @_;
    my $rel  = "$form_name.files/$id";
    my $fdir = "$dir/$rel";
    make_path($fdir) unless -d $fdir;
    my @saved;
    my $i = 0;
    for my $f (@$files) {
        $i++;
        my $safe = _safe_filename( $f->{filename} );
        $safe = "$i-$safe" if -e "$fdir/$safe";   # keep both if names collide
        open my $w, '>:raw', "$fdir/$safe" or next;
        print {$w} $f->{data};
        close $w;
        push @saved, $safe;
    }
    return ( \@saved, $rel );
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

    # When the SMTP handler is set to attach uploads, hand the files (base64) to
    # form-smtp.pl so it can attach them and list them under the message.
    my $attach = defined $config->{attach_files}
        && lc("$config->{attach_files}") =~ /^(?:1|true|yes|on|enabled)$/;
    if ( $attach && $form->{_files} && @{ $form->{_files} } ) {
        require MIME::Base64;
        $payload{files} = [ map {
            {   filename => $_->{filename},
                type     => $_->{type},
                size     => length( $_->{data} // '' ),
                data     => MIME::Base64::encode_base64( $_->{data} // '' ),
            }
        } @{ $form->{_files} } ];
    }

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
    return $r->{ok} ? 1 : 0;
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
    return $res->is_success ? 1 : 0;
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

    reject('Upload too large') if $len > $MAX_POST_BYTES;

    binmode STDIN;                       # binary-safe: file parts carry raw bytes
    if ( $len > 0 ) { read( STDIN, $data, $len ); }
    else            { local $/; $data = <STDIN> // ''; }

    my %form;
    my @files;
    if ( $type =~ m{multipart/form-data.*boundary=(.+)}i ) {
        my $boundary = $1;
        $boundary =~ s/^\s+//;
        $boundary =~ s/["\s]+$//;
        for my $part ( split /--\Q$boundary\E/, $data ) {
            # part = optional CRLF, headers, blank line, body, trailing CRLF
            next unless $part =~ /\A\r?\n?(.*?)\r?\n\r?\n(.*)\z/s;
            my ( $head, $body ) = ( $1, $2 );
            next unless $head =~ /name="([^"]*)"/i;
            my $name = $1;
            $body =~ s/\r?\n\z//;        # drop the CRLF that precedes the next boundary
            if ( $head =~ /filename="([^"]*)"/i ) {
                my $filename = $1;
                next unless length $filename;    # an empty file input - skip
                my ($ctype) = $head =~ /Content-Type:\s*([^\r\n]+)/i;
                push @files, {
                    field    => $name,
                    filename => $filename,
                    type     => ( $ctype // 'application/octet-stream' ),
                    data     => $body,
                };
            }
            else {
                $form{$name} = sanitise_header( $body, 10000 );
            }
        }
        $form{_files} = \@files if @files;
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

# Like reject(), but the message IS shown to the submitter (upload limits etc.).
sub reject_user { die "USER:$_[0]\n"; }

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
