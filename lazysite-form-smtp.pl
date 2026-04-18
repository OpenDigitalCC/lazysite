#!/usr/bin/perl
# lazysite-form-smtp.pl - SMTP email helper for lazysite forms
# Accepts JSON POST, sends email via configured method
use strict;
use warnings;
use POSIX qw(strftime);
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(dirname);

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'form-smtp',
        name        => 'Form SMTP',
        description => 'Email delivery for contact form submissions',
        version     => '1.0',
        config_file => 'lazysite/forms/smtp.conf',
        config_schema => [
            { key => 'method', label => 'Send method', type => 'select',
              options => ['sendmail','localhost','remote'], default => 'sendmail', required => JSON::PP::true() },
            { key => 'sendmail_path', label => 'Sendmail path', type => 'text',
              default => '/usr/sbin/sendmail', show_when => { key => 'method', value => ['sendmail'] } },
            { key => 'host', label => 'SMTP host', type => 'text',
              show_when => { key => 'method', value => ['localhost','remote'] } },
            { key => 'port', label => 'SMTP port', type => 'number', default => '587',
              show_when => { key => 'method', value => ['localhost','remote'] } },
            { key => 'tls', label => 'TLS', type => 'select',
              options => ['false','starttls','true'], default => 'starttls',
              show_when => { key => 'method', value => ['remote'] } },
            { key => 'auth', label => 'SMTP authentication', type => 'boolean', default => 'false',
              show_when => { key => 'method', value => ['remote'] } },
            { key => 'username', label => 'SMTP username', type => 'text',
              show_when => { key => 'auth', value => ['true','1'] } },
            { key => 'password_file', label => 'Password file path', type => 'path',
              show_when => { key => 'auth', value => ['true','1'] } },
            { key => 'from', label => 'From address', type => 'email', required => JSON::PP::true() },
            { key => 'to', label => 'Recipient address', type => 'email', required => JSON::PP::true() },
            { key => 'subject_prefix', label => 'Subject prefix', type => 'text', default => '[Contact] ' },
        ],
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
    my $json = do { local $/; <STDIN> };
    die "No input\n" unless defined $json && length $json;

    my $form = decode_json($json);
    my $conf = load_smtp_conf();
    send_email( $conf, $form );

    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1 } );
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    warn "lazysite-form-smtp: $err\n";
    binmode( STDOUT, ':utf8' );
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $err } );
}

# --- Config ---

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

sub send_email {
    my ( $conf, $form ) = @_;

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

    my $method = $conf->{method};

    if ( $method eq 'sendmail' ) {
        send_via_sendmail( $conf->{sendmail_path}, $from, $to, $subject, $body );
    }
    elsif ( $method eq 'localhost' ) {
        send_via_smtp( $conf, $from, $to, $subject, $body );
    }
    elsif ( $method eq 'remote' ) {
        send_via_smtp( $conf, $from, $to, $subject, $body );
    }
    else {
        die "Unknown SMTP method: $method\n";
    }
}

sub send_via_sendmail {
    my ( $sendmail, $from, $to, $subject, $body ) = @_;

    die "sendmail not found at $sendmail\n" unless -x $sendmail;

    open( my $fh, '|-', $sendmail, '-t', '-oi', '-f', $from )
        or die "Cannot run sendmail: $!\n";
    print $fh "From: $from\n";
    print $fh "To: $to\n";
    print $fh "Subject: $subject\n";
    print $fh "Content-Type: text/plain; charset=utf-8\n";
    print $fh "MIME-Version: 1.0\n";
    print $fh "\n";
    print $fh $body;
    close($fh) or die "sendmail failed: exit $?\n";
}

sub send_via_smtp {
    my ( $conf, $from, $to, $subject, $body ) = @_;

    require Net::SMTP;

    my $host = $conf->{host} || 'localhost';
    my $port = $conf->{port} || 25;
    my $tls  = $conf->{tls}  || '';
    my $auth = $conf->{auth} && $conf->{auth} =~ /^true$/i;

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
        my $pass = '';
        if ( $conf->{password_file} ) {
            my $pf = "$DOCROOT/" . $conf->{password_file};
            if ( -f $pf ) {
                open( my $pfh, '<', $pf ) or die "Cannot read password file: $!\n";
                chomp( $pass = <$pfh> );
                close($pfh);
            }
        }
        $smtp->auth( $user, $pass ) or die "SMTP auth failed\n";
    }

    $smtp->mail($from)           or die "MAIL FROM failed\n";
    $smtp->to($to)               or die "RCPT TO failed\n";
    $smtp->data()                or die "DATA failed\n";
    $smtp->datasend("From: $from\n");
    $smtp->datasend("To: $to\n");
    $smtp->datasend("Subject: $subject\n");
    $smtp->datasend("Content-Type: text/plain; charset=utf-8\n");
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
