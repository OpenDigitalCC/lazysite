#!/usr/bin/perl
# SM1405 (ruling 157): EVERY NOTICE MAIL THROUGH THE ONE SEND TAKES THE SAME SHAPE.
# Lazysite::Notify's send handed the rendered notice to the Form SMTP extension
# AS A FORM SUBMISSION - the subject as `subject_prefix`, the notice as a
# `message` field - so the mail arrived with the subject "[SITE] ... - " (nothing
# after the dash) and a body laid out as a submission: a "Form submission"
# heading, the notice under a `message:` label, then Submitted and IP lines. Now
# it is sent as a composed message (the extension's send_message): its own
# subject, the rendered notice as the body, no handler layout, no IP line - still
# SM485's send, the Form SMTP extension as the only transport, the same hourly
# bound.
#
# The owner-contact mail this was first written against is retired (SM1412,
# ruling 159), so the test is aimed at the sends that remain: SM485's account
# notice (an opted-in account named by a notice) and an import's claim link
# (send_mail as Manager::AccountImport calls it). The real extension script runs
# behind a mock sendmail.
#
# Reverted, the first subtest fails: the subject ends " - " and the body has the
# handler's layout.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Notify ();

plan skip_all => 'no extensions/form-smtp.pl' unless -f repo_root() . '/extensions/form-smtp.pl';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/auth" );
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
spit( "$d/lazysite/auth/users", "ada:x\n" );
spit( "$d/lazysite/auth/user-settings.json",
    JSON::PP->new->canonical->encode( { ada => { email => 'ada@example.org', notify_email => JSON::PP::true() } } ) );
spit( "$d/lazysite/notify.conf", "route.submission: bell,email\n" );

sub mail_to {
    my ($to) = @_;
    my @m = grep { /^To:\s*\Q$to\E\s*$/m } grep { length } split /--MESSAGE--\n/, slurp($out);
    return $m[-1] // '';
}

sub shaped_ok {
    my ( $m, $subject, $carries ) = @_;
    like( $m, qr/^Subject: \Q$subject\E\s*$/m, "the subject is the notice's own: $subject" );
    unlike( $m, qr/^Subject: .* - \s*$/m, '  with no trailing " - "' );
    like( $m, $carries, '  the body carries the notice' );
    unlike( $m, qr/^Form submission/m, '  under no "Form submission" heading' );
    unlike( $m, qr/^message:\s/m,      '  and not as a message: field' );
    unlike( $m, qr/^IP:/m,             '  with no IP line' );
    unlike( $m, qr/^Submitted:/m,      '  and no Submitted line' );
    return;
}

subtest 'SM485\'s account notice: its own subject, the rendered notice as the body' => sub {
    local $ENV{REMOTE_ADDR} = '10.0.63.7';
    ok( Lazysite::Notify::notify( $d, { type => 'submission', message => 'NOTICE-TEXT for ada', to => 'ada' } ),
        'the notice is made' );
    my $m = mail_to('ada@example.org');
    ok( length $m, 'ada, who opted in, was mailed' ) or return diag slurp("$d/lazysite/logs/lazysite.log");
    shaped_ok( $m, '[Bakery] A form was submitted', qr/NOTICE-TEXT for ada/ );
    unlike( $m, qr/10\.0\.63\.7/, '  and the request address is nowhere in it' );
};

subtest 'an import\'s claim link: the same shape' => sub {
    my $why = Lazysite::Notify::send_mail( $d, to => 'ada@example.org', subject => 'Set your password',
        what => 'claim link', text => "An account 'ada' has been made for you.\n\nCLAIM-LINK\n" );
    is( $why, '', 'sent' ) or return;
    shaped_ok( mail_to('ada@example.org'), 'Set your password', qr/CLAIM-LINK/ );
};

done_testing;
