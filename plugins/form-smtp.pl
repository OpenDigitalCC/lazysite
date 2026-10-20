#!/usr/bin/perl
# lazysite-form-smtp.pl - SMTP email helper for lazysite forms
# Accepts JSON POST, sends email via configured method
use strict;
use warnings;
use POSIX          qw(strftime);
use JSON::PP       qw(encode_json decode_json);
use File::Basename qw(dirname);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). Nothing is loaded here: the loads are lazy, so --describe
    # answers even where the tree is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

my $LOG_COMPONENT = 'form-smtp';

if ( grep { $_ eq '--describe' } @ARGV ) {
    print JSON::PP::encode_json( {
            id          => 'form-smtp',
            name        => 'Form SMTP',
            description => 'SMTP connection settings for form email delivery',
            version     => '1.1',
            # SM072: capabilities this plugin provides when enabled, so other
            # code can detect (e.g.) that the site can send email.
            provides      => ['email-send'],
            config_file   => 'lazysite/forms/smtp.conf',
            config_schema => [
                { key => 'method', label => 'Send method', type => 'select',
                    options => [ 'sendmail', 'smtp' ], default => 'sendmail', required => JSON::PP::true() },
                # SM1109 (0.15.7 test plan U6): the sender is a setting. It was
                # webforms@localhost with no way to change it, which a real mail
                # server refuses at RCPT.
                { key => 'from', label => 'From address', type => 'email',
                    note => 'The sender of every mail this site sends. Leave empty to use '
                        . 'no-reply@ followed by the host of the Site URL.' },
                { key => 'sendmail_path', label => 'Sendmail path', type => 'text',
                    default => '/usr/sbin/sendmail', show_when => { key => 'method', value => ['sendmail'] } },
                { key => 'host', label => 'SMTP host', type => 'text', default => 'localhost',
                    show_when => { key => 'method', value => ['smtp'] } },
                { key => 'port', label => 'SMTP port', type => 'number', default => '587',
                    show_when => { key => 'method', value => ['smtp'] } },
                { key => 'tls', label => 'TLS', type => 'select',
                    options   => [ 'false', 'starttls', 'true' ], default => 'false',
                    show_when => { key => 'method', value => ['smtp'] } },
                { key => 'auth', label => 'SMTP authentication', type => 'boolean', default => 'false',
                    show_when => { key => 'method', value => ['smtp'] } },
                { key => 'username', label => 'SMTP username', type => 'text',
                    show_when => { key => 'auth', value => [ 'true', '1' ] } },
                { key => 'password', label => 'SMTP password', type => 'password',
                    note => 'Stored in the sysop-only smtp.conf; never shown again. Leave blank to keep the current one.',
                    show_when => { key => 'auth', value => [ 'true', '1' ] } },
                { key => 'password_file', label => 'Password file (alternative to the password field)', type => 'path',
                    show_when => { key => 'auth', value => [ 'true', '1' ] } },
            ],
            actions => [ { id => 'validate', label => 'Validate SMTP connection' } ],
    } );
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
    $docroot ||= _docroot() || '.';
    print encode_json( validate_smtp($docroot) );
    exit 0;
}

# --- Pipe mode: called by form-handler via IPC ---

if ( grep { $_ eq '--pipe' } @ARGV ) {
    eval {
        my $json = do { local $/; <STDIN> };
        die "No input\n" unless defined $json && length $json;

        my $data   = decode_json($json);
        my $config = $data->{config} or die "Missing config\n";
        my $form   = $data->{form}   or die "Missing form\n";

        # Merge SMTP connection settings from smtp.conf if available
        my $docroot = _docroot();
        if ($docroot) {
            my $smtp_conf = load_smtp_conf_from( _lz($docroot) . "/forms/smtp.conf" );
         # smtp.conf provides connection settings; handler config provides from/to/subject
            for my $k (qw(method sendmail_path host port tls auth username password password_file)) {
                $config->{$k} //= $smtp_conf->{$k} if defined $smtp_conf->{$k};
            }
        }

        # SM1109: the sender - the handler's own, else the extension's From
        # setting, else the default derived from the site's address.
        my $conf_from = $docroot ? load_smtp_conf_from( _lz($docroot) . "/forms/smtp.conf" )->{from} : undef;
        $config->{from} = resolve_from( $config->{from}, $conf_from, $docroot );

        # Apply defaults
        $config->{method}         //= 'sendmail';
        $config->{sendmail_path}  //= '/usr/sbin/sendmail';
        $config->{to}             //= 'root@localhost';
        $config->{subject_prefix} //= '[Contact] ';

        # Uploaded files (base64) arrive only when the handler has attach_files on.
        my $files;
        if ( ref $data->{files} eq 'ARRAY' && @{ $data->{files} } ) {
            require MIME::Base64;
            $files = [ map {
                    { filename => $_->{filename},
                        type => $_->{type},
                        size => $_->{size},
                        data => MIME::Base64::decode_base64( $_->{data} // '' ),
                    }
            } @{ $data->{files} } ];
        }

        # SM1020: a notification rule's message arrives composed (Lazysite::Outbox).
        if ( ref $data->{message} eq 'HASH' ) { send_message( $config, $data->{message} ) }
        else                                  { send_email( $config, $form, $files ) }
        log_event( 'INFO', $config->{to} // '-', 'email sent', method => $config->{method} // 'sendmail', from => $config->{from} // '-' );
        print encode_json( { ok => 1 } );
    };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        log_event( 'ERROR', '-', 'smtp failed', error => $err );
        print encode_json( { ok => 0, error => $err } );
    }
    exit 0;
}

# --- CGI mode (legacy) ---

my $DOCROOT      = _docroot() or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = _lz($DOCROOT);
# SM929: THE request address for this request - the visitor, not the front proxy.
# One reader, cached, because everything below asks the same question about one
# request. Behind a front proxy REMOTE_ADDR is a single constant for every visitor
# a site will ever have, so an address column held the infrastructure's identity
# and anything keyed on it shared one bucket with the world.
{
    my $request_ip;

    sub _request_ip {
        return $request_ip if defined $request_ip;
        require Lazysite::Util;
        $request_ip = Lazysite::Util::request_address(
            Lazysite::Util::trusted_proxy_spec($LAZYSITE_DIR) );
        return $request_ip;
    }
}

my $FORMS_DIR = "$LAZYSITE_DIR/forms";

eval {
    my $json = do { local $/; <STDIN> };
    die "No input\n" unless defined $json && length $json;

    my $form = decode_json($json);
    my $conf = load_smtp_conf();
    send_email( $conf, $form );
    log_event( 'INFO', $conf->{to} // '-', 'email sent', method => $conf->{method} // 'sendmail', from => $conf->{from} // '-' );

    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1 } );
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    log_event( 'ERROR', '-', 'smtp failed', error => $err );
    warn "lazysite-form-smtp: $err\n";
    binmode( STDOUT, ':utf8' );
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $err } );
}

# --- Config ---

# The docroot this request is about, as the web server spells it. The empty
# string when neither variable is set - what each caller does about that
# differs (a scan falls back to '.', the CGI path refuses) and stays with the
# caller.
sub _docroot {
    return $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
}

sub load_smtp_conf_from {
    my ( $path, $strict ) = @_;
    unless ( -f $path ) {
        die "SMTP config not found at $path\n" if $strict;
        return {};
    }

    open( my $fh, '<:utf8', $path ) or do {
        die "Cannot read $path: $!\n" if $strict;
        return {};
    };
    local $/;
    my $text = <$fh>;
    close($fh);

    my %conf;
    while ( $text =~ /^([a-z_]+)\h*:\h*(.+)$/mg ) {
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/^\s+|\s+$//g;
        next if $v =~ /^#/;
        $conf{$k} = $v;
    }
    return \%conf;
}

# The CGI path's reader: the same parse, but it REFUSES a missing or
# unreadable file rather than falling back to defaults, and it fills the
# defaults in afterwards.
sub load_smtp_conf {
    my $conf = load_smtp_conf_from( "$FORMS_DIR/smtp.conf", 1 );
    $conf->{method}        //= 'sendmail';
    $conf->{sendmail_path} //= '/usr/sbin/sendmail';
    $conf->{from} = resolve_from( undef, $conf->{from}, _docroot() );
    $conf->{to}             //= 'root@localhost';
    $conf->{subject_prefix} //= '[Form] ';
    return $conf;
}

# --- The sender ---

# SM1109 (0.15.7 test plan U6): "The default sender webforms@localhost is refused
# by a real mail server ... the Form SMTP settings cannot change (the extension
# has no From field)". RULED 2026-10-16 ("from default ok"): the chain is
#
#   1. the handler's own `from`,
#   2. the Form SMTP extension's From setting (smtp.conf `from`),
#   3. no-reply@<host of the site's site_url>, site_url expanded,
#   4. webforms@localhost - only when site_url does not resolve to an absolute
#      address (a daemon has no request to borrow a host from), and the log says so.
#
# One resolver for every message: a form's copy, a notification, an account
# claim link all pass through this script.
sub resolve_from {
    my ( $handler_from, $conf_from, $docroot ) = @_;
    for my $v ( $handler_from, $conf_from ) {
        next unless defined $v && !ref $v;
        ( my $s = $v ) =~ s/^\s+|\s+$//g;
        return $s if length $s;
    }
    my $base = '';
    if ($docroot) {
        $base = eval { require Lazysite::Notify; Lazysite::Notify::site_base($docroot) } // '';
    }
    if ( $base =~ m{\A\w+://(?:[^/@\s]*@)?([^/\s:]+)} ) {
        return "no-reply\@$1";
    }
    log_event( 'WARN', '-', 'no sender configured and site_url does not resolve to an address; '
            . 'sending as webforms@localhost, which a real mail server refuses - set the From '
            . 'address on the Form SMTP extension or pin Site URL' );
    return 'webforms@localhost';
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
    return "$n B" if $n < 1024;
    return sprintf( '%.1f KB', $n / 1024 ) if $n < 1024 * 1024;
    return sprintf( '%.1f MB', $n / 1048576 );
}

# Wrap the text body + uploaded files into a multipart/mixed message. Returns
# ($mime_body, $content_type).
sub _wrap_multipart {
    my ( $text_body, $files ) = @_;
    require MIME::Base64;
    my $boundary = 'lzs_' . time() . '_' . int( rand 1_000_000 );
    my $m        = "--$boundary\r\n"
        . "Content-Type: text/plain; charset=utf-8\r\n\r\n"
        . $text_body . "\r\n";
    for my $f (@$files) {
        ( my $fn = $f->{filename} // 'file' )                     =~ s/["\r\n]//g;
        ( my $ct = $f->{type}     // 'application/octet-stream' ) =~ s/[;"\r\n].*//s;
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
    push @lines, "IP:        " . ( _request_ip() || 'unknown' );

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

    my $from = sanitise_email( $conf->{from}, 'From address' );
    my $to   = sanitise_email( $conf->{to},   'To address' );

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

# SM1020: A COMPOSED MESSAGE - the notify rules' mail (Lazysite::Outbox).
#
# send_email above builds a FORM's message: "Form submission", one line per
# field, the submitter's address. A notification is composed by its rule's
# template instead, so it arrives here whole - subject, plain-text body, and
# the headers a rule may add - and this only puts it on the wire:
#
#   * To and From are exactly one address, refused otherwise (SM1017);
#   * the Subject is folded of CR/LF and RFC 2047-encoded when not ASCII;
#   * a header is accepted only from a closed list, and its value only in the
#     shape that header takes - List-Unsubscribe is one <http(s)://...> URL,
#     and List-Unsubscribe-Post (RFC 8058, SM1073) its one fixed value.
#     Nothing a template writes can add a header.
# A sub, not a file-scope hash: the --pipe block above runs before a `my` here
# would be assigned.
sub _message_header_shape {
    my ($name) = @_;
    my %shape = (
        q{List-Unsubscribe}      => qr{\A<https?://[^\s<>"]+>\z},
        q{List-Unsubscribe-Post} => qr{\AList-Unsubscribe=One-Click\z},
    );
    return $shape{$name};
}

sub send_message {
    my ( $conf, $msg ) = @_;
    my $from = sanitise_email( $conf->{from}, 'From address' );
    my $to   = sanitise_email( $conf->{to},   'To address' );
    require Lazysite::Mail;
    my $subject = Lazysite::Mail::encode_header( $msg->{subject} // '' );
    my @extra;
    my $h = ref $msg->{headers} eq 'HASH' ? $msg->{headers} : {};
    for my $name ( sort keys %$h ) {
        my $re = _message_header_shape($name) or die "the header $name is not one a message may carry\n";
        my $v = $h->{$name} // '';
        die "the $name header is refused: it is not in the shape that header takes\n"
            unless !ref $v && $v =~ $re;
        push @extra, "$name: $v";
    }
    my $body = $msg->{text} // '';
    $body =~ s/\r\n?/\n/g;
    utf8::encode($body) if utf8::is_utf8($body);
    my $ctype = 'text/plain; charset=utf-8';
    if ( $conf->{method} eq 'sendmail' ) {
        send_via_sendmail( $conf->{sendmail_path}, $from, $to, $subject, $body, $ctype, \@extra );
    }
    elsif ( $conf->{method} eq 'smtp' ) {
        send_via_smtp( $conf, $from, $to, $subject, $body, $ctype, \@extra );
    }
    else {
        die "Unknown SMTP method: $conf->{method}\n";
    }
    return;
}

sub send_via_sendmail {
    my ( $sendmail, $from, $to, $subject, $body, $ctype, $extra ) = @_;
    $ctype ||= 'text/plain; charset=utf-8';

    die "sendmail not found at $sendmail\n" unless -x $sendmail;

    # SM1111: sendmail's stderr goes to a file for the length of the run, so a
    # failure can quote it; the parent's own stderr is put back before anything
    # else happens.
    require File::Temp;
    my ( $errfh, $errfile ) = File::Temp::tempfile( UNLINK => 1 );
    open( my $olderr, '>&', \*STDERR ) or die "Cannot save stderr: $!\n";
    open( STDERR,     '>&', $errfh )   or die "Cannot redirect stderr: $!\n";
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $opened   = open( my $fh, '|-', $sendmail, '-t', '-oi', '-f', $from );
    my $open_err = "$!";
    open( STDERR, '>&', $olderr ) or die "Cannot restore stderr: $!\n";
    close $olderr;
    $opened or die "Cannot run sendmail: $open_err\n";
    print $fh "From: $from\n";
    print $fh "To: $to\n";
    print $fh "Subject: $subject\n";
    print $fh "$_\n" for @{ $extra || [] };    # SM1020: from a closed list (send_message)
    print $fh "Content-Type: $ctype\n";
    print $fh "MIME-Version: 1.0\n";
    print $fh "\n";
    print $fh $body;
    unless ( close($fh) ) {
        my $why  = describe_wait_status( $?, $! );
        my $said = _first_lines($errfile);
        die "sendmail failed: $why" . ( length $said ? ": $said" : '' ) . "\n";
    }
}

# SM1111 (0.15.7 test plan U9): "'sendmail failed: exit 256' is the raw wait
# status (exit code 1)". The status of a child is an exit code in the high byte
# and a signal in the low seven bits; it is said as what it is.
sub describe_wait_status {
    my ( $status, $errno ) = @_;
    return "killed by signal " . ( $status & 127 ) . _signame( $status & 127 ) if $status & 127;
    return 'exit code ' .        ( $status >> 8 ) if $status >> 8;
    # A close that failed with a clean status is a write that did not complete.
    return 'could not be written to' . ( $errno ? ": $errno" : '' );
}

sub _signame {
    my ($n) = @_;
    my %name = ( 1 => 'HUP', 2 => 'INT', 3 => 'QUIT', 6 => 'ABRT', 9 => 'KILL', 11 => 'SEGV', 13 => 'PIPE', 14 => 'ALRM', 15 => 'TERM' );
    return $name{$n} ? " ($name{$n})" : '';
}

# The first few lines of a file as one line, bounded: sendmail's own words, for
# the reason a send failed. Empty when there are none.
sub _first_lines {
    my ($path) = @_;
    open( my $fh, '<', $path ) or return '';
    my @l;
    while ( my $l = <$fh> ) {
        $l =~ s/\s+$//;
        next unless length $l;
        push @l, $l;
        last if @l >= 3;
    }
    close $fh;
    my $s = join ' / ', @l;
    $s = substr( $s, 0, 300 ) . '...' if length $s > 300;
    return $s;
}

# SM1110 (0.15.7 test plan U7): "STARTTLS fails on a hostname mismatch with only
# 'STARTTLS failed'... the message should say 'certificate is for
# isp.cloudient.net, not mail.explore.lazysite.io'."
#
# Upgrades the connection and, when that fails, says WHY. The verify callback
# only watches: it records the names the server's certificate was issued for
# (its subject alternative names, else its common name) and returns the verdict
# unchanged, so it can never make a certificate acceptable. Returns (1) on
# success, else (0, $message, $cert_seen) - $cert_seen is true when a
# certificate was presented, which is how a caller tells a refused certificate
# from a server that does not offer STARTTLS at all.
sub _starttls {
    my ($smtp) = @_;
    my @names;
    my $watch = sub {
        my ( $ok, $store, $certname, $err, $cert ) = @_;
        eval {
            if ( $cert && Net::SSLeay::X509_STORE_CTX_get_error_depth($store) == 0 ) {
                my @san = Net::SSLeay::X509_get_subjectAltNames($cert);
                while ( my ( $type, $val ) = splice @san, 0, 2 ) { push @names, $val if $type == 2 }
                unless (@names) {
                    my $cn = Net::SSLeay::X509_NAME_get_text_by_NID(
                        Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay::NID_commonName() );
                    push @names, $cn if defined $cn && length $cn;
                }
            }
            1;
        };
        return $ok;
    };
    return (1) if $smtp->starttls( SSL_verify_callback => $watch );
    return ( 0, starttls_failure( $smtp->host, \@names, $@, $smtp->code, scalar $smtp->message ), scalar @names );
}

# The sentence for a STARTTLS that failed. Pure, so it is tested without a
# socket: $host is what was connected to, $names the certificate's names (may
# be empty), $err the TLS library's error, $code/$reply the server's last reply.
sub starttls_failure {
    my ( $host, $names, $err, $code, $reply ) = @_;
    $host //= '';
    $err  //= '';
    $err =~ s/\s+$//;
    if ( defined $code && $code =~ /\A[45]/ ) {
        ( my $r = $reply // '' ) =~ s/[\r\n]+/ /g;
        $r =~ s/\s+$//;
        return "STARTTLS failed: the server replied $code" . ( length $r ? " $r" : '' );
    }
    if ( $names && @$names && $err =~ /hostname verification failed/i ) {
        return 'STARTTLS failed: certificate is for ' . join( ', ', @$names ) . ", not $host ($err)";
    }
    return "STARTTLS failed: $err" if length $err;
    return 'STARTTLS failed';
}

# The server's last reply as one line ("550 5.7.1 ..."), or a plain word when it
# gave none.
sub _smtp_reply {
    my ($smtp) = @_;
    my $m = scalar( $smtp->message ) // '';
    $m =~ s/[\r\n]+/ /g;
    $m =~ s/\s+$//;
    my $c = $smtp->code // '';
    my $r = join ' ', grep { length } $c, $m;
    return length $r ? $r : 'no reply from the server';
}

sub send_via_smtp {
    my ( $conf, $from, $to, $subject, $body, $ctype, $extra ) = @_;

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
        my ( $tls_ok, $tls_why ) = _starttls($smtp);
        die "$tls_why\n" unless $tls_ok;
    }

    if ($auth) {
        my $user = $conf->{username} // '';
        my $pass = resolve_password($conf);
        $smtp->auth( $user, $pass ) or die "SMTP auth failed\n";
    }

    $smtp->mail($from) or die "MAIL FROM failed\n";
    # SM1109: the refusal names the sender used - the usual cause is a server
    # that will not relay for the sender's domain, and the reply alone does not
    # say which sender it was shown.
    unless ( $smtp->to($to) ) {
        my $reply = _smtp_reply($smtp);
        die "RCPT TO refused for $to sending as $from: $reply\n";
    }
    $smtp->data() or die "DATA failed\n";
    $smtp->datasend("From: $from\n");
    $smtp->datasend("To: $to\n");
    $smtp->datasend("Subject: $subject\n");
    $smtp->datasend("$_\n") for @{ $extra || [] };    # SM1020
    $smtp->datasend( "Content-Type: " . ( $ctype || 'text/plain; charset=utf-8' ) . "\n" );
    $smtp->datasend("MIME-Version: 1.0\n");
    $smtp->datasend("\n");
    $smtp->datasend($body);
    $smtp->dataend() or die "DATA END failed\n";
    $smtp->quit();
}

# SM1017 (SM1010 F2): THE HEADER GETS EXACTLY ONE ADDRESS, OR NOTHING IS SENT.
#
# This used to STRIP CR, LF, < and > and send whatever was left, which repaired
# `x<b@example.org>` into a different address and let `root,b@example.org`
# through whole - two recipients to `sendmail -t`. Every message this script
# sends passes here (a form's copy, the submitter's acknowledgement, a setup
# link, a notice), so the one writer of the header is the one place the rule
# is certain to hold. Refused, never repaired: the die is the pipe's error.
sub sanitise_email {
    my ( $val, $which ) = @_;
    $which //= 'address';
    require Lazysite::Mail;
    my ( $one, $why ) = Lazysite::Mail::one_address($val);
    die "the $which is refused: $why\n" unless defined $one;
    return $one;
}

# --- Logging ---

sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts     = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
        _forward_diag( $level, $json );
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
        _forward_diag( $level, $line );
    }
}

# SM850: the engine's tree - inside the docroot, or beside it on a site that
# moved it out (SM293). Asked of the resolver, never built by hand: a path built
# here kept working until the day a site migrated, then read and wrote a
# directory that was no longer there.
sub _lz {
    my ($docroot) = @_;
    require Lazysite::Paths;
    return Lazysite::Paths::lazysite_dir($docroot);
}

# SM540: a best-effort copy of the line to syslog through Lazysite::Util's
# forward_line, so this plugin's diagnostics are covered by the
# forward_diagnostics DEFAULT of WARN and above (SM932) as well as by an
# explicit setting - it needed `forward_diagnostics: true` before that, and
# the docs promised syslog either way. The rest of this plugin's
# diagnostics as the docs promise. The module tree is found by the bootstrap at
# the top (the SM473 lesson: `prove -l` puts lib/ on @INC and a real install does not) and
# the require is eval-guarded, the SM425 posture: a missing lib costs the
# operator a syslog copy, never a submission - STDERR has the line either way.
sub _forward_diag {
    my ( $level, $line ) = @_;
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    eval {
        require Lazysite::Util;
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
        my $docroot = _docroot();
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

    my $path = _lz($docroot) . "/forms/smtp.conf";
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
        alarm 30;    # network-bound: DNS and the SMTP peer (t/lint/120)

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
            my ( $tls_ok, $tls_why, $tls_cert ) = _starttls($smtp);
            unless ($tls_ok) {
                my $code = $smtp->code // '';
                $smtp->quit;
                # SM1110: a certificate that was refused says why; "may not offer
                # STARTTLS" is the advice only when the server never got that far.
                return { ok => 0, stage => 'tls', error => "TLS issue: $tls_why" } if $tls_cert;
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
