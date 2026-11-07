#!/usr/bin/perl
# SM1362 (ruling 123): A FORM CAN ANSWER THE SUBMITTER IN ITS OWN WORDS - through
# the real form handler CGI, on the shipped local-storage handler (a form that
# saves and nothing else), with a mock sendmail behind the Form SMTP extension
# counting what was handed over. (SM1362's owner-contact mail is retired, SM1412,
# ruling 159; t/unit/forms/78 holds that the key mails nobody now.)
#
#   * a form's conf opting in with acknowledge_field / acknowledge_message
#     answers the address in that field with the form's own wording - never the
#     submission's text - under SM877's caps (per recipient, per site), shared
#     with the smtp handler's acknowledgements; never for a quarantined
#     submission; a form that does not opt in sends none.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $EXTENSION = repo_root() . '/extensions/form-handler.pl';
plan skip_all => "no $EXTENSION" unless -f $EXTENSION;

my $SECRET   = 'test-secret-1362-abcdefghij';
my $BOUNDARY = 'Sbnd1362';
my $WORDING  = 'Thank you for writing to the Example Bakery.\nWe reply within two days.';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
    spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
    spit( "$d/lazysite/lazysite.conf",
        "site_name: Bakery\nsite_url: https://bakery.example.org\n"
            . ( $o{smtp_off} ? '' : "extensions:\n  - extensions/form-smtp.pl\n" ) );
    my $out  = "$d/mail.out";
    my $mock = "$d/sendmail";
    spit( $mock,
        "#!$^X\n"
            . 'open my $w, ">>:raw", "' . $out . '" or exit 1;' . "\n"
            . 'local $/; print {$w} "--MESSAGE--\n", <STDIN>; close $w;' . "\n" );
    chmod 0755, $mock;
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $mock\nfrom: web\@example.org\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: local-storage\n    type: file\n    name: Saved\n"
            . "    path: lazysite/forms/submissions\n" );
    spit( "$d/lazysite/forms/contact.conf",
        "targets:\n  - handler: local-storage\n" . ( $o{form} // '' ) );
    spit( "$d/lazysite/notify.conf", $o{notify} // '' );
    return ( $d, $out );
}

my $ip = 0;

sub post {
    my ( $d, %fields ) = @_;
    $ip++;
    my $ts   = time() - 10;
    my $body = '';
    for my $pair ( [ '_form', 'contact' ], [ '_ts', $ts ],
        [ '_tk', hmac_sha256_hex( $ts, $SECRET ) ], [ '_hp', '' ],
        map { [ $_, $fields{$_} ] } sort keys %fields )
    {
        $body .= "--$BOUNDARY\r\nContent-Disposition: form-data; name=\"$pair->[0]\"\r\n\r\n$pair->[1]\r\n";
    }
    $body .= "--$BOUNDARY--\r\n";
    my $in = "$d/post.bin";
    spit( $in, $body );
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = "multipart/form-data; boundary=$BOUNDARY";
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = "10.0.62.$ip";
    return scalar qx($^X \Q$EXTENSION\E < \Q$in\E 2>>\Q$d/stderr.log\E);
}

sub messages {
    my ($out) = @_;
    return [ map { { to => ( /^To:\s*(.*?)\s*$/m ? $1 : '?' ), text => $_ } }
            grep { length } split /--MESSAGE--\n/, slurp($out) ];
}
sub to_list { my ($out) = @_; return [ sort map { $_->{to} } @{ messages($out) } ] }
sub to_one { my ( $out, $to ) = @_; return ( grep { $_->{to} eq $to } @{ messages($out) } )[0] }
sub log_of { my ($d) = @_; return slurp("$d/stderr.log") . slurp("$d/lazysite/logs/audit.log") }

my $ACK = "acknowledge_field: email\nacknowledge_subject: We have your message\n"
    . "acknowledge_message: $WORDING\n";
my %GOOD = ( name => 'Ada', email => 'ada@example.net', message => 'SUBMITTED-TEXT please call me' );

subtest 'the submitter is answered in the form\'s words' => sub {
    my ( $d, $out ) = site( form => $ACK );
    post( $d, %GOOD );
    ok( -s "$d/lazysite/forms/submissions/contact.jsonl", 'the submission is saved (local-storage)' );
    is_deeply( to_list($out), ['ada@example.net'], 'one message: the submitter' )
        or diag explain messages($out);

    my $ack = to_one( $out, 'ada@example.net' ) // {};
    like( $ack->{text}, qr/^Subject: We have your message/m, 'the acknowledgement has the form\'s subject' );
    like( $ack->{text}, qr/Thank you for writing to the Example Bakery\.\nWe reply within two days\./,
        '  and the form\'s own wording, \n as a line break' );
    unlike( $ack->{text}, qr/SUBMITTED-TEXT|Ada/, '  and nothing the visitor typed' );
};

subtest 'opt-in' => sub {
    my ( $d, $out ) = site();
    post( $d, %GOOD );
    is_deeply( to_list($out), [], 'no acknowledge_field: nothing is mailed' );
    ok( -s "$d/lazysite/forms/submissions/contact.jsonl", '  and the form still saves' );

    ( $d, $out ) = site( form => "acknowledge_field: email\n" );
    post( $d, %GOOD );
    is_deeply( to_list($out), [], 'a field with no wording sends no acknowledgement' );
    like( log_of($d), qr/no acknowledge_message/, '  and the log says why' );
};

subtest 'a quarantined submission tells nobody' => sub {
    my ( $d, $out ) = site( form => $ACK );
    post( $d, name => 'Spam', email => 'victim@example.net',
        message => 'Buy now at https://a.example.biz and https://b.example.info and https://c.example.top' );
    is_deeply( to_list($out), [], 'not the address the suspect submission chose' );
};

subtest 'the caps: SM877\'s for the submitter' => sub {
    my ( $d, $out ) = site( form => $ACK );
    post( $d, %GOOD ) for 1 .. 4;
    my @to = @{ to_list($out) };
    is( scalar( grep { $_ eq 'ada@example.net' } @to ), 3, 'one address: three acknowledgements an hour' );
    like( log_of($d), qr/the submitter was not acknowledged/, '  and the fourth is logged as not sent' );

    ( $d, $out ) = site( form => $ACK . "submitter_per_site_hour: 2\n", notify => '' );
    post( $d, %GOOD, email => "p$_\@example.net" ) for 1 .. 3;
    is( scalar @{ to_list($out) }, 2, 'the site: the form\'s own submitter_per_site_hour holds' );

    # the bucket is the smtp handler's too: an acknowledgement it sent counts here
    ( $d, $out ) = site( form => $ACK, notify => '' );
    require Lazysite::Handlers;
    {
        no warnings 'once';
        local $Lazysite::Handlers::DOCROOT = $d;
        my $f   = Lazysite::Handlers::submitter_mail_file();
        my $key = substr Digest::SHA::sha256_hex('ada@example.net'), 0, 24;
        make_path( $f =~ s{/[^/]+\z}{}r );
        spit( $f, join '', map { qq({"t":) . time() . qq(,"d":"$key"}\n) } 1 .. 3 );
    }
    post( $d, %GOOD );
    is_deeply( to_list($out), [], 'three smtp-handler acknowledgements to the address this hour: the form sends none' );
};

done_testing();
