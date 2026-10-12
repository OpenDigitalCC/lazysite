#!/usr/bin/perl
# SM1017 (SM1010 F1): A QUARANTINED SUBMISSION IS NOT ACKNOWLEDGED, through the
# real delivery path.
#
# SM877 sends a second message to the address a form field holds, and SM913
# ruled that a quarantined submission gets none: answering a suspect submission
# writes to an address somebody else chose. The check asked the FIELDS for
# `_quarantined` - and the form handler strips every `_` key before delivery
# and carries the flag as context instead. The only test of it called the sub
# directly with the key in the fields, which is the one arrangement the real
# path never produces. So this file posts through plugins/form-handler.pl, the
# CGI a visitor reaches, and counts what the mock sendmail was handed.
#
# F2 is here too, on the same path: a submitter address naming two recipients
# (a comma, a semicolon, an angle-bracketed display form or a line break) is
# refused, and nothing is sent to it.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $SECRET   = 'test-secret-1017-abcdefghij';
my $BOUNDARY = 'Sbnd1017';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

# A mock sendmail that appends every message it is piped.
sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
    spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    my $out  = "$d/mail.out";
    my $mock = "$d/sendmail";
    spit( $mock,
        "#!$^X\n"
            . 'open my $w, ">>:raw", "' . $out . '" or exit 1;' . "\n"
            . 'local $/; print {$w} "--MESSAGE--\n", <STDIN>; close $w;' . "\n" );
    chmod 0755, $mock;
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n"
            . "  - id: contact\n"
            . "    type: smtp\n"
            . "    name: Contact\n"
            . "    from: web\@example.org\n"
            . "    to: office\@example.org\n"
            . "    method: sendmail\n"
            . "    sendmail_path: $mock\n"
            . "    mail_the_submitter_field: email\n" );
    spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: contact\n" );
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
    local $ENV{REMOTE_ADDR}    = "10.0.17.$ip";
    return scalar qx($^X \Q$PLUGIN\E < \Q$in\E 2>/dev/null);
}

sub recipients {
    my ($out) = @_;
    return sort { $a cmp $b }
        map { /^To:\s*(.*?)\s*$/m ? $1 : '?' }
        grep { length } split /--MESSAGE--\n/, slurp($out);
}

subtest 'a clean submission is acknowledged - the control case' => sub {
    my ( $d, $out ) = site();
    post( $d, name => 'Ada', email => 'ada@example.net', message => 'Hello there.' );
    is_deeply( [ recipients($out) ], [ 'ada@example.net', 'office@example.org' ],
        'the operator and the submitter each got one message' )
        or diag('Without this the quarantine case below passes vacuously.');
};

subtest 'a quarantined submission is stored for the operator and NOT acknowledged' => sub {
    my ( $d, $out ) = site();
    post( $d, name => 'Spam', email => 'victim@example.net',
        message => 'Buy now at https://a.example.biz and https://b.example.info '
            . 'and https://c.example.top' );
    is_deeply( [ recipients($out) ], ['office@example.org'],
        'only the operator was written to - not the address the suspect submission chose' )
        or diag( 'SM1010 F1: the acknowledgement asked the fields for _quarantined, '
            . 'which the form handler strips before delivery.' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/quarantine/,
        'and the delivery record says why nobody else was written to' );
};

subtest 'F2: a submitter address that names more than one recipient is refused' => sub {
    # The first two carry ONE @, which is what the old shape test counted: `root,`
    # names a local mailbox to `sendmail -t` and the rest a second recipient.
    for my $bad ( 'root,b@example.org', 'root;b@example.org',
        'a@example.net,b@example.org', 'x<b@example.org>',
        "a\@example.net\r\nBcc: b\@example.org" )
    {
        my ( $d, $out ) = site();
        post( $d, name => 'Ada', email => $bad, message => 'Hello there.' );
        ( my $label = $bad ) =~ s/\r\n/\\r\\n/g;
        is_deeply( [ recipients($out) ], ['office@example.org'],
            "'$label': only the operator was written to" );
        like( slurp("$d/lazysite/logs/audit.log"), qr/refused as the submitter's address/,
            "'$label': and the record says the address was refused" );
    }
};

done_testing();
