#!/usr/bin/perl
# SM1412 (rulings 158, 159): A FORM MAILS NOBODY UNLESS A HANDLER IT NAMES SAYS SO.
#
# Ruling 158: no one is mailed by default - a form's submissions go to file
# storage, because a site cannot be sure it can send mail - and people are mailed
# only through a notify handler the form names. Ruling 159 retires SM1362's
# `owner_contact` (0.16.6), which mailed every form's notice to one address in
# notify.conf: the key is ignored from 0.16.8.
#
# Through the real form handler CGI, on the shipped local-storage handler, with
# everything a mail could need in place - the Form SMTP extension on with its
# settings, a mock sendmail, an operator account with an address that opted in to
# mail notices, the submission route set to email, and owner_contact still set -
# a submission is stored, its notice is in the bell, and nobody is mailed.
#
# Reverted (the owner-contact mail restored), the first subtest fails: the
# address in owner_contact is mailed.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use JSON::PP    ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $EXTENSION = repo_root() . '/extensions/form-handler.pl';
plan skip_all => "no $EXTENSION" unless -f $EXTENSION;

my $SECRET   = 'test-secret-1412-abcdefghij';
my $BOUNDARY = 'Sbnd1412';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/auth" );
    spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
    spit( "$d/lazysite/lazysite.conf",
        "site_name: Bakery\nsite_url: https://bakery.example.org\nextensions:\n  - extensions/form-smtp.pl\n" );
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
    spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: local-storage\n" . ( $o{form} // '' ) );
    spit( "$d/lazysite/auth/users", "opal:x\n" );
    spit( "$d/lazysite/auth/user-settings.json",
        JSON::PP->new->canonical->encode( { opal => { email => 'opal@example.org', notify_email => JSON::PP::true() } } ) );
    spit( "$d/lazysite/notify.conf", "owner_contact: owner\@example.org\nroute.submission: bell,email\n" );
    return ( $d, $out );
}

sub post {
    my ( $d, %fields ) = @_;
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
    local $ENV{REMOTE_ADDR}    = '10.0.64.9';
    return scalar qx($^X \Q$EXTENSION\E < \Q$in\E 2>>\Q$d/stderr.log\E);
}

my %GOOD = ( name => 'Ada', email => 'ada@example.net', message => 'SUBMITTED-TEXT please call me' );

for my $case ( [ 'notify: on (the default)', '' ], [ 'notify: full', "notify: full\n" ] ) {
    my ( $label, $form ) = @$case;
    subtest "a form naming no notify handler mails nobody, and stores its submission - $label" => sub {
        my ( $d, $out ) = site( form => $form );
        post( $d, %GOOD );
        is( slurp($out), '', 'nothing was handed to the mail transport' )
            or diag slurp($out);
        like( slurp("$d/lazysite/forms/submissions/contact.jsonl"), qr/SUBMITTED-TEXT/,
            'the submission is stored under lazysite/forms/submissions' );
        like( slurp("$d/lazysite/logs/notices.jsonl"), qr/"type":"submission"/,
            'and its notice is in the bell' );
        unlike( slurp("$d/stderr.log"), qr/owner contact/, 'no owner-contact mail is attempted' );
    };
}

done_testing;
