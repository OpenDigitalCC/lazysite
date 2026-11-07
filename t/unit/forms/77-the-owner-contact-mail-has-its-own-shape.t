#!/usr/bin/perl
# SM1405: THE OWNER-CONTACT NOTICE MAIL HAS ITS OWN SHAPE. Lazysite::Notify's
# send handed the rendered notice to the Form SMTP extension AS A FORM
# SUBMISSION - the subject as `subject_prefix`, the notice as a `message` field -
# so the mail arrived with the subject "[SITE] A form was submitted - " (nothing
# after the dash) and a body laid out as a submission: a "Form submission"
# heading, the notice under a `message:` label, then Submitted and IP lines. Now
# it is sent as a composed message (the extension's send_message): its own
# subject, the rendered notice as the body, no handler layout, no IP line - still
# through SM485's send, the Form SMTP extension as the only transport, the same
# hourly bound. Through the real form handler CGI with a mock sendmail, as
# t/unit/forms/68 drives it.
#
# Reverted, the first subtest fails: the subject ends " - " and the body has the
# handler's layout.
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

my $SECRET   = 'test-secret-1405-abcdefghij';
my $BOUNDARY = 'Sbnd1405';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
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
    spit( "$d/lazysite/notify.conf",        "owner_contact: owner\@example.org\n" );
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
    local $ENV{REMOTE_ADDR}    = '10.0.63.7';
    return scalar qx($^X \Q$EXTENSION\E < \Q$in\E 2>>\Q$d/stderr.log\E);
}

sub owner_mail {
    my ($out) = @_;
    my ($m) = grep { /^To:\s*owner\@example\.org\s*$/m } grep { length } split /--MESSAGE--\n/, slurp($out);
    return $m // '';
}

subtest 'the subject is the notice\'s own, and the body is the rendered notice' => sub {
    my ( $d, $out ) = site();
    post( $d, name => 'Ada', message => 'SUBMITTED-TEXT' );
    my $m = owner_mail($out);
    ok( length $m, 'the owner was mailed' ) or diag slurp("$d/stderr.log");
    like( $m, qr/^Subject: \[Bakery\] A form was submitted\s*$/m, 'the subject, with nothing dangling after it' );
    unlike( $m, qr/^Subject: .* - \s*$/m, '  no trailing " - "' );
    like( $m, qr/New form submission: contact/, 'the body carries the notice' );
    unlike( $m, qr/^Form submission/m, '  under no "Form submission" heading' );
    unlike( $m, qr/^message:\s/m,      '  and not as a message: field' );
    unlike( $m, qr/^IP:/m,             '  with no IP line' );
    unlike( $m, qr/^Submitted:/m,      '  and no Submitted line' );
    unlike( $m, qr/10\.0\.63\.7/,      '  the address is nowhere in it' );
    unlike( $m, qr/SUBMITTED-TEXT/,    '  and on notify: on the fields are not in it' );
};

subtest 'notify: full still carries the fields, in the notice\'s own layout' => sub {
    my ( $d, $out ) = site( form => "notify: full\n" );
    post( $d, name => 'Ada', message => 'SUBMITTED-TEXT' );
    my $m = owner_mail($out);
    like( $m, qr/SUBMITTED-TEXT/, 'the fields are in the mail' );
    unlike( $m, qr/^Form submission/m, 'and still no handler heading' );
    unlike( $m, qr/^IP:/m,             'and no IP line' );
};

done_testing;
