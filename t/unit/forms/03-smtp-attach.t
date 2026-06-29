use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempdir);

# SMTP form transport: when the handler's attach_files is on, uploaded files are
# attached to the email and listed (name + size) below the message. Off (default)
# = a plain-text email, no attachments.
my $SMTP = 'plugins/form-smtp.pl';
ok( -f $SMTP, 'form-smtp present' );

my $d = tempdir( CLEANUP => 1 );
my $OUT = "$d/mail.out";

# Mock sendmail: capture the piped message to a file.
my $mock = "$d/sendmail";
open my $mf, '>', $mock or die $!;
print $mf "#!$^X\n", 'open my $w, ">:raw", $ENV{MOCK_MAIL_OUT} or exit 1;', "\n",
          'local $/; print {$w} <STDIN>; close $w;', "\n";
close $mf;
chmod 0755, $mock;

my $png = "\x89PNG\r\n" . ( 'z' x 300 );    # 306 bytes

sub run_pipe {
    my ($attach) = @_;
    unlink $OUT;
    my %config = (
        method        => 'sendmail',
        sendmail_path => $mock,
        from          => 'web@example.com',
        to            => 'admin@example.com',
        subject_prefix => '[C] ',
        attach_files  => ( $attach ? 'true' : 'false' ),
    );
    my %payload = (
        config => \%config,
        form   => { name => 'Ada', message => 'Hi' },
        files  => [ { filename => 'pic.png', type => 'image/png',
                      size => length($png), data => encode_base64($png) } ],
    );
    my $json = encode_json( \%payload );
    my $bf = "$d/payload.json";
    open my $w, '>', $bf or die $!; print {$w} $json; close $w;
    local $ENV{MOCK_MAIL_OUT}  = $OUT;
    local $ENV{DOCUMENT_ROOT}  = $d;     # no smtp.conf here -> use config's settings
    my $res = qx($^X \Q$SMTP\E --pipe < \Q$bf\E 2>/dev/null);
    my $mail = '';
    if ( open my $r, '<:raw', $OUT ) { local $/; $mail = <$r>; close $r; }
    return ( $res, $mail );
}

# --- attach ON: multipart, file listed, attachment present ---
{
    my ( $res, $mail ) = run_pipe(1);
    like( $res, qr/"ok"\s*:\s*1/, 'send reported ok' );
    like( $mail, qr{Content-Type:\s*multipart/mixed}i, 'multipart email when attaching' );
    like( $mail, qr/Files uploaded:/, 'file list header present' );
    like( $mail, qr/pic\.png\s+306 B/, 'file name + size listed below the message' );
    like( $mail, qr/Content-Disposition:\s*attachment; filename="pic\.png"/i, 'attachment part present' );
    my ($b64_first) = encode_base64($png) =~ /^(\S+)/;
    like( $mail, qr/\Q$b64_first\E/, 'attachment carries the base64 file data' );
}

# --- attach OFF (default): plain text, no attachment ---
{
    my ( $res, $mail ) = run_pipe(0);
    like( $res, qr/"ok"\s*:\s*1/, 'send ok (no attach)' );
    like( $mail, qr{Content-Type:\s*text/plain}i, 'plain-text email when not attaching' );
    unlike( $mail, qr/multipart/i, 'no multipart' );
    unlike( $mail, qr/Files uploaded:/, 'no file list when attach is off' );
}

done_testing;
