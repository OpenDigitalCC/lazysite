#!/usr/bin/perl
# lazysite-form-smtp.pl - SMTP email helper for lazysite forms
# Accepts JSON POST, sends email via configured method
use strict;
use warnings;
use POSIX qw(strftime);
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(dirname);

my $LOG_COMPONENT = 'form-smtp';

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'form-smtp',
        name        => 'Form SMTP',
        description => 'SMTP connection settings for form email delivery',
        version     => '1.1',
        # SM072: capabilities this plugin provides when enabled, so other
        # code can detect (e.g.) that the site can send email.
        provides    => ['email-send'],
        config_file => 'lazysite/forms/smtp.conf',
        config_schema => [
            { key => 'method', label => 'Send method', type => 'select',
              options => ['sendmail','smtp'], default => 'sendmail', required => JSON::PP::true() },
            { key => 'sendmail_path', label => 'Sendmail path', type => 'text',
              default => '/usr/sbin/sendmail', show_when => { key => 'method', value => ['sendmail'] } },
            { key => 'host', label => 'SMTP host', type => 'text', default => 'localhost',
              show_when => { key => 'method', value => ['smtp'] } },
            { key => 'port', label => 'SMTP port', type => 'number', default => '587',
              show_when => { key => 'method', value => ['smtp'] } },
            { key => 'tls', label => 'TLS', type => 'select',
              options => ['false','starttls','true'], default => 'false',
              show_when => { key => 'method', value => ['smtp'] } },
            { key => 'auth', label => 'SMTP authentication', type => 'boolean', default => 'false',
              show_when => { key => 'method', value => ['smtp'] } },
            { key => 'username', label => 'SMTP username', type => 'text',
              show_when => { key => 'auth', value => ['true','1'] } },
                { key => 'password', label => 'SMTP password', type => 'password',
                    note => 'Stored in the operator-only smtp.conf; never shown again. Leave blank to keep the current one.',
                    show_when => { key => 'auth', value => [ 'true', '1' ] } },
                { key => 'password_file', label => 'Password file (alternative to the password field)', type => 'path',
              show_when => { key => 'auth', value => ['true','1'] } },
        ],
            actions => [ { id => 'validate', label => 'Validate SMTP connection' } ],
    });
    exit 0;
}

# --- Validate mode (the "Validate SMTP connection" button): staged connection
# check against the SAVED smtp.conf, reporting WHICH stage fails - host (DNS),
# port (TCP), TLS, or authentication - so a misconfiguration names itself.
# Invoked by the manager's plugin-action as `--scan --docroot DIR`.

if ( grep { $_ eq '--scan' } @ARGV ) {
    my $docroot = '';
    for my $i ( 0 .. $#ARGV ) {
        $docroot = $ARGV[ $i + 1 ] // '' if $ARGV[$i] eq '--docroot';
    }
    $docroot ||= $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '.';
    print encode_json( validate_smtp($docroot) );
    exit 0;
}

# --- Pipe mode: called by form-handler via IPC ---

if ( grep { $_ eq '--pipe' } @ARGV ) {
    eval {
        my $json = do { local $/; <STDIN> };
        die "No input\n" unless defined $json && length $json;

        my $data = decode_json($json);
        my $config = $data->{config} or die "Missing config\n";
        my $form   = $data->{form}   or die "Missing form\n";

        # Merge SMTP connection settings from smtp.conf if available
        my $docroot = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
        if ($docroot) {
            my $smtp_conf = load_smtp_conf_from("$docroot/lazysite/forms/smtp.conf");
            # smtp.conf provides connection settings; handler config provides from/to/subject
            for my $k (qw(method sendmail_path host port tls auth username password password_file)) {
                $config->{$k} //= $smtp_conf->{$k} if defined $smtp_conf->{$k};
            }
        }

        # Apply defaults
        $config->{method}         //= 'sendmail';
        $config->{sendmail_path}  //= '/usr/sbin/sendmail';
        $config->{from}           //= 'webforms@localhost';
        $config->{to}             //= 'root@localhost';
        $config->{subject_prefix} //= '[Contact] ';

        # Uploaded files (base64) arrive only when the handler has attach_files on.
        my $files;
        if ( ref $data->{files} eq 'ARRAY' && @{ $data->{files} } ) {
            require MIME::Base64;
            $files = [ map {
                {   filename => $_->{filename},
                    type     => $_->{type},
                    size     => $_->{size},
                    data     => MIME::Base64::decode_base64( $_->{data} // '' ),
                }
            } @{ $data->{files} } ];
        }

        send_email( $config, $form, $files );
        log_event('INFO', $config->{to} // '-', 'email sent', method => $config->{method} // 'sendmail', from => $config->{from} // '-');
        print encode_json( { ok => 1 } );
    };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        log_event('ERROR', '-', 'smtp failed', error => $err);
        print encode_json( { ok => 0, error => $err } );
    }
    exit 0;
}

# --- CGI mode (legacy) ---

my $DOCROOT      = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $FORMS_DIR    = "$LAZYSITE_DIR/forms";

eval {
    my $json = do { local $/; <STDIN> };
    die "No input\n" unless defined $json && length $json;

    my $form = decode_json($json);
    my $conf = load_smtp_conf();
    send_email( $conf, $form );
    log_event('INFO', $conf->{to} // '-', 'email sent', method => $conf->{method} // 'sendmail', from => $conf->{from} // '-');

    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1 } );
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    log_event('ERROR', '-', 'smtp failed', error => $err);
    warn "lazysite-form-smtp: $err\n";
    binmode( STDOUT, ':utf8' );
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $err } );
}

# --- Config ---

sub load_smtp_conf_from {
    my ($path) = @_;
    return {} unless -f $path;

    open( my $fh, '<:utf8', $path ) or return {};
    local $/;
    my $text = <$fh>;
    close($fh);

    my %conf;
    while ( $text =~ /^([a-z_]+)\s*:\s*(.+)$/mg ) {
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/^\s+|\s+$//g;
        next if $v =~ /^#/;
        $conf{$k} = $v;
    }
    return \%conf;
}

sub load_smtp_conf {
    my $path = "$FORMS_DIR/smtp.conf";
    die "SMTP config not found at $path\n" unless -f $path;

    open( my $fh, '<:utf8', $path ) or die "Cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close($fh);

    my %conf;
    while ( $text =~ /^([a-z_]+)\s*:\s*(.+)$/mg ) {
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/^\s+|\s+$//g;
        next if $v =~ /^#/;
        $conf{$k} = $v;
    }

    $conf{method}        //= 'sendmail';
    $conf{sendmail_path} //= '/usr/sbin/sendmail';
    $conf{from}          //= 'webforms@localhost';
    $conf{to}            //= 'root@localhost';
    $conf{subject_prefix} //= '[Form] ';

    return \%conf;
}

# --- Email ---

sub _truthy { my $v = shift; defined $v && lc("$v") =~ /^(?:1|true|yes|on|enabled)$/ }

# SM524: the SM519 discipline for the two flags smtp.conf carries. `auth: 1`
# used to skip authentication (the read was /^true$/i) and `tls: false` was a
# truthy STRING that got listed as checked. A spelling the reader does not know
# is REFUSED - it must never degrade to "no auth" or "no TLS".
sub _falsy { my $v = shift; !defined $v || lc("$v") =~ /^(?:|0|false|no|off|disabled)$/ }

sub _smtp_auth_flag {
    my ($conf) = @_;
    my $v = $conf->{auth};
    return 1 if _truthy($v);
    return 0 if _falsy($v);
    die "smtp.conf: auth must be true or false (got '$v')\n";
}

sub _smtp_tls_mode {
    my ($conf) = @_;
    my $v = $conf->{tls};
    return ''         if _falsy($v);
    return 'starttls' if lc("$v") eq 'starttls';
    return 'true'     if _truthy($v);
    die "smtp.conf: tls must be false, starttls or true (got '$v')\n";
}

sub _human_size {
    my $n = shift // 0;
    return "$n B"                              if $n < 1024;
    return sprintf( '%.1f KB', $n / 1024 )     if $n < 1024 * 1024;
    return sprintf( '%.1f MB', $n / 1048576 );
}

# Wrap the text body + uploaded files into a multipart/mixed message. Returns
# ($mime_body, $content_type).
sub _wrap_multipart {
    my ( $text_body, $files ) = @_;
    require MIME::Base64;
    my $boundary = 'lzs_' . time() . '_' . int( rand 1_000_000 );
    my $m = "--$boundary\r\n"
          . "Content-Type: text/plain; charset=utf-8\r\n\r\n"
          . $text_body . "\r\n";
    for my $f (@$files) {
        ( my $fn = $f->{filename} // 'file' ) =~ s/["\r\n]//g;
        ( my $ct = $f->{type} // 'application/octet-stream' ) =~ s/[;"\r\n].*//s;
        $m .= "--$boundary\r\n"
            . "Content-Type: $ct; name=\"$fn\"\r\n"
            . "Content-Transfer-Encoding: base64\r\n"
            . "Content-Disposition: attachment; filename=\"$fn\"\r\n\r\n"
            . MIME::Base64::encode_base64( $f->{data} // '' )
            . "\r\n";
    }
    $m .= "--$boundary--\r\n";
    return ( $m, qq(multipart/mixed; boundary="$boundary") );
}

sub send_email {
    my ( $conf, $form, $files ) = @_;

    my $attach = _truthy( $conf->{attach_files} ) && $files && @$files;

    # Build body from non-internal fields
    my @lines = ("Form submission");
    push @lines, "-" x 40;
    push @lines, "";
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        my $v = $form->{$k} // '';
        $v =~ s/[\r\n]+/\n             /g;
        push @lines, sprintf( "%-12s %s", "$k:", $v );
    }

    # List the uploaded files (name + size) below the message when attaching.
    if ($attach) {
        push @lines, "";
        push @lines, "Files uploaded:";
        for my $f (@$files) {
            push @lines, sprintf( '  %-32s %s',
                ( $f->{filename} // 'file' ),
                _human_size( $f->{size} // length( $f->{data} // '' ) ) );
        }
    }

    push @lines, "";
    push @lines, "-" x 40;
    push @lines, "Submitted: " . strftime( '%A, %d %B %Y at %H:%M:%S %Z', localtime );
    push @lines, "IP:        " . ( $ENV{REMOTE_ADDR} // 'unknown' );

    my $body = join( "\n", @lines ) . "\n";

    # Subject from first short field or form name
    my $subject = $conf->{subject_prefix};
    for my $k (qw(subject name email)) {
        if ( defined $form->{$k} && length $form->{$k} ) {
            $subject .= substr( $form->{$k}, 0, 80 );
            last;
        }
    }
    $subject =~ s/[\r\n]/ /g;

    my $from = sanitise_email( $conf->{from} );
    my $to   = sanitise_email( $conf->{to} );

    my $ctype;
    ( $body, $ctype ) = _wrap_multipart( $body, $files ) if $attach;

    my $method = $conf->{method};

    if ( $method eq 'sendmail' ) {
        send_via_sendmail( $conf->{sendmail_path}, $from, $to, $subject, $body, $ctype );
    }
    elsif ( $method eq 'smtp' ) {
        send_via_smtp( $conf, $from, $to, $subject, $body, $ctype );
    }
    else {
        die "Unknown SMTP method: $method\n";
    }
}

sub send_via_sendmail {
    my ( $sendmail, $from, $to, $subject, $body, $ctype ) = @_;
    $ctype ||= 'text/plain; charset=utf-8';

    die "sendmail not found at $sendmail\n" unless -x $sendmail;

    open( my $fh, '|-', $sendmail, '-t', '-oi', '-f', $from )
        or die "Cannot run sendmail: $!\n";
    print $fh "From: $from\n";
    print $fh "To: $to\n";
    print $fh "Subject: $subject\n";
    print $fh "Content-Type: $ctype\n";
    print $fh "MIME-Version: 1.0\n";
    print $fh "\n";
    print $fh $body;
    close($fh) or die "sendmail failed: exit $?\n";
}

sub send_via_smtp {
    my ( $conf, $from, $to, $subject, $body, $ctype ) = @_;

    require Net::SMTP;

    my $host = $conf->{host} || 'localhost';
    my $port = $conf->{port} || 25;
    my $tls  = _smtp_tls_mode($conf);    # SM524
    my $auth = _smtp_auth_flag($conf);

    my %opts = (
        Host    => $host,
        Port    => $port,
        Timeout => 10,
    );

    if ( $tls eq 'true' ) {
        require IO::Socket::SSL;
        $opts{SSL} = 1;
    }

    my $smtp = Net::SMTP->new(%opts) or die "Cannot connect to $host:$port\n";

    if ( $tls eq 'starttls' ) {
        $smtp->starttls() or die "STARTTLS failed\n";
    }

    if ($auth) {
        my $user = $conf->{username} // '';
        my $pass = resolve_password($conf);
        $smtp->auth( $user, $pass ) or die "SMTP auth failed\n";
    }

    $smtp->mail($from)           or die "MAIL FROM failed\n";
    $smtp->to($to)               or die "RCPT TO failed\n";
    $smtp->data()                or die "DATA failed\n";
    $smtp->datasend("From: $from\n");
    $smtp->datasend("To: $to\n");
    $smtp->datasend("Subject: $subject\n");
    $smtp->datasend( "Content-Type: " . ( $ctype || 'text/plain; charset=utf-8' ) . "\n" );
    $smtp->datasend("MIME-Version: 1.0\n");
    $smtp->datasend("\n");
    $smtp->datasend($body);
    $smtp->dataend()             or die "DATA END failed\n";
    $smtp->quit();
}

sub sanitise_email {
    my ($val) = @_;
    $val =~ s/[\r\n<>]//g;
    return $val;
}

# --- Logging ---

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
        _forward_diag( $level, $json );
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
        _forward_diag( $level, $line );
    }
}

# SM540: a best-effort copy of the line to syslog through Lazysite::Util's
# forward_line, so `forward_diagnostics: true` covers this plugin's
# diagnostics as the docs promise. The module tree is located at runtime (the
# SM473 lesson: `prove -l` puts lib/ on @INC and a real install does not) and
# the require is eval-guarded, the SM425 posture: a missing lib costs the
# operator a syslog copy, never a submission - STDERR has the line either way.
sub _forward_diag {
    my ( $level, $line ) = @_;
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    eval {
        unless ( $INC{'Lazysite/Util.pm'} ) {
            require Cwd;
            require File::Basename;
            my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
            for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
                if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
            }
            require Lazysite::Util;
        }
        Lazysite::Util::forward_line( 'diag', $prio{$level} // 'info', $line );
        1;
    };
    return;
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

# The SMTP password: the `password` key in the operator-only smtp.conf is the
# simple path; `password_file` remains a fallback, used only when no password is
# set. Shared by delivery (send_via_smtp) and the validate action.
sub resolve_password {
    my ($conf) = @_;
    return $conf->{password}
        if defined $conf->{password} && length $conf->{password};
    my $pass = '';
    if ( $conf->{password_file} ) {
        my $docroot = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
        my $pf      = $conf->{password_file};
        $pf = "$docroot/$pf" if $docroot && $pf !~ m{^/};
        if ( -f $pf ) {
            open( my $pfh, '<', $pf ) or die "Cannot read password file: $!\n";
            chomp( $pass = <$pfh> );
            close($pfh);
        }
    }
    return $pass;
}

# Staged validation of the saved smtp.conf: each stage names itself on failure
# (host / port / TLS / auth), so "email doesn't work" becomes actionable. Never
# sends a message - it stops after the last configured stage and QUITs.
sub validate_smtp {
    my ($docroot) = @_;
    local $ENV{DOCUMENT_ROOT} = $docroot;

    my $path = "$docroot/lazysite/forms/smtp.conf";
    return { ok => 0, stage => 'config',
        error => 'No smtp.conf found - save the SMTP settings first.' }
        unless -f $path;
    my $conf = load_smtp_conf_from($path);

    my $method = $conf->{method} || 'sendmail';
    if ( $method eq 'sendmail' ) {
        my $sm = $conf->{sendmail_path} || '/usr/sbin/sendmail';
        return { ok => 0, stage => 'sendmail',
            error => "Sendmail issue: '$sm' not found or not executable. "
                . 'Install a sendmail-compatible MTA or switch to method: smtp.' }
            unless -x $sm;
        return { ok => 1, stage => 'ok', checked => ['sendmail'],
            message => "OK: $sm is present and executable." };
    }

    my $host = $conf->{host} || 'localhost';
    my $port = $conf->{port} || 25;
    # SM524: a spelling the reader refuses is a CONFIG fault, reported before
    # any socket opens.
    my ( $tls, $auth ) = eval { ( _smtp_tls_mode($conf), _smtp_auth_flag($conf) ) };
    if ($@) {
        ( my $err = $@ ) =~ s/\s+$//;
        return { ok => 0, stage => 'config', error => "Config issue: $err" };
    }
    my @checked;

    my $result = eval {
        local $SIG{ALRM} = sub { die "timed out\n" };
        alarm 30;

        # Stage 1 - host: does the name resolve? (IP literals skip DNS.)
        unless ( $host =~ /^[\d.]+$/ || $host =~ /^\[?[0-9a-fA-F:]+\]?$/ ) {
            my @addr = gethostbyname($host);
            return { ok => 0, stage => 'host',
                error => "Host issue: cannot resolve '$host'. Check the SMTP "
                    . 'host name (DNS).' }
                unless @addr;
        }
        push @checked, 'host';

        # Stage 2 - port: plain TCP reach first, so a closed port / firewall is
        # reported as a PORT problem, not mistaken for a TLS one.
        require IO::Socket::INET;
        my $probe = IO::Socket::INET->new(
            PeerAddr => $host, PeerPort => $port, Timeout => 10 );
        return { ok => 0, stage => 'port',
            error => "Port issue: cannot connect to $host:$port. Check the port "
                . '(25/465/587) and any firewall.' }
            unless $probe;
        close $probe;
        push @checked, 'port';

        # Stage 3 - the SMTP session itself (TLS-on-connect when tls: true).
        require Net::SMTP;
        my %opts = ( Host => $host, Port => $port, Timeout => 10 );
        if ( $tls eq 'true' ) {
            require IO::Socket::SSL;
            $opts{SSL} = 1;
        }
        my $smtp = Net::SMTP->new(%opts);
        unless ($smtp) {
            return { ok => 0, stage => 'tls',
                error => "TLS issue: $host:$port accepts connections but the "
                    . 'TLS handshake failed. If the server expects STARTTLS '
                    . '(usual on 587), set tls: starttls; implicit TLS is '
                    . 'usually port 465.' }
                if $tls eq 'true';
            return { ok => 0, stage => 'port',
                error => "Port issue: $host:$port accepted the connection but "
                    . 'did not greet as an SMTP server. Is this the right port?' };
        }
        push @checked, 'connect';

        if ( $tls eq 'starttls' ) {
            unless ( $smtp->starttls() ) {
                my $code = $smtp->code // '';
                $smtp->quit;
                return { ok => 0, stage => 'tls',
                    error => "TLS issue: STARTTLS failed ($code). The server may "
                        . 'not offer STARTTLS on this port - try tls: true on '
                        . '465, or tls: false for a localhost relay.' };
            }
        }
        push @checked, 'tls' if $tls;

        # Stage 4 - authentication.
        if ($auth) {
            my $user = $conf->{username} // '';
            my $pass = resolve_password($conf);
            unless ( length $pass ) {
                $smtp->quit;
                return { ok => 0, stage => 'auth',
                    error => 'Auth issue: no password is set. Enter one in the '
                        . 'Password field (or configure password_file).' };
            }
            unless ( $smtp->auth( $user, $pass ) ) {
                my $code = $smtp->code // '';
                $smtp->quit;
                return { ok => 0, stage => 'auth',
                    error => "Auth issue: the server rejected the credentials "
                        . "($code). Check the username and password; some "
                        . 'servers require TLS before AUTH.' };
            }
            push @checked, 'auth';
        }

        my $banner = $smtp->banner // '';
        $banner =~ s/[\r\n]+/ /g;
        $smtp->quit;
        return { ok => 1, stage => 'ok', checked => \@checked,
            message => 'OK: ' . join( ' + ', @checked )
                . " all succeeded against $host:$port"
                . ( length $banner ? " ($banner)" : '' ) . '.' };
    };
    alarm 0;
    return $result if ref $result eq 'HASH';
    ( my $err = $@ || 'validation failed' ) =~ s/[\r\n]+/ /g;
    my $next  = $checked[-1] // 'host';
    my %after = ( host => 'port', port => 'connect', connect => 'tls', tls => 'auth' );
    return { ok => 0, stage => ( $after{$next} // 'connect' ),
        error => "Validation stopped after '$next': $err" };
}
