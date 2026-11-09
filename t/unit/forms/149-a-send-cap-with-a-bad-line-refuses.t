#!/usr/bin/perl
# Ruling 206 (item 12 of the 0.16.9 fault survey): A SEND CAP WHOSE RECORD HOLDS
# A LINE THAT IS NOT A RECORD REFUSES, rather than counting past it.
#
# Three caps counted their hour by reading a JSON-lines record and skipping any
# line that would not decode - so a torn record undercounted, and the cap let
# through what it should have held:
#
#   lazysite/forms/submitter-mail.jsonl  - a form's acknowledgement to the submitter
#   lazysite/logs/notice-mail.jsonl      - the site's own notice mail
#   lazysite/connectors/calls.jsonl      - a connector's rate_per_hour
#
# Each counter now answers undef ("cannot tell") on such a line, which the cap
# policy (Egress::within_caps) refuses, with a WARN naming the store and the
# line. The record is left as found. An absent record is a genuine zero.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Handlers           ();
use Lazysite::Notify             ();
use Lazysite::Manager::Connectors ();

sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub quietly {
    my ($code) = @_;
    my $err = '';
    my @r;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        @r = $code->();
        close STDERR;
    }
    return ( $err, @r );
}

my $OUT;

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/connectors" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    $OUT = "$d/mail.out";
    spit( "$d/sendmail", "#!$^X\nopen my \$w, '>>:raw', '$OUT' or exit 1;\n"
            . "local \$/; print {\$w} \"--MESSAGE--\\n\", <STDIN>; close \$w;\n" );
    chmod 0755, "$d/sendmail";
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: contact\n    type: smtp\n    from: web\@example.org\n"
            . "    to: office\@example.org\n    method: sendmail\n    sendmail_path: $d/sendmail\n"
            . "    mail_the_submitter_field: email\n" );
    $Lazysite::Handlers::DOCROOT = $d;
    return $d;
}

sub deliver {
    return Lazysite::Handlers::deliver( 'contact', { email => 'ada@example.net' },
        source => 'form:contact', actor => '', ip => '10.0.0.1', origin => 'form' );
}

sub recipients {
    my $t = slurp($OUT) // '';
    return sort { $a cmp $b } map { /^To:\s*(\S+)/m ? $1 : '?' } grep { length } split /--MESSAGE--\n/, $t;
}

my $good = '{"d":"0123456789abcdef01234567","t":' . time . "}\n";

subtest 'submitter-mail: absent counts zero, and the acknowledgement goes' => sub {
    site();
    my ( undef, $r ) = quietly( \&deliver );
    ok( $r->{ok}, 'delivered' ) or diag explain $r;
    is_deeply( [ recipients() ], [ 'ada@example.net', 'office@example.org' ], 'both messages went' );
};

subtest 'submitter-mail: a line that is not a record refuses the acknowledgement' => sub {
    my $d   = site();
    my $rec = "$d/lazysite/forms/submitter-mail.jsonl";
    my $bad = $good . "not json\n" . $good;
    spit( $rec, $bad );
    my ( $err, $r ) = quietly( \&deliver );
    ok( $r->{ok}, 'the submission still succeeds (the operator was told)' );
    like( $r->{note}, qr/cannot tell how much of its per-recipient cap/, 'the acknowledgement is refused' );
    like( $r->{note}, qr/`lazysite check --docroot <docroot>` names the fault/, 'naming the check' );
    is_deeply( [ recipients() ], ['office@example.org'], 'the submitter was not written to' );
    like( $err, qr/cannot tell - lazysite\/forms\/submitter-mail\.jsonl holds a line that is not a send record \(line 2\)/,
        'the log names the store and the line' );
    is( slurp($rec), $bad, 'the record is left as found' );
};

subtest 'notice-mail: absent is zero; a bad line cannot be counted' => sub {
    my $d = site();
    is( Lazysite::Notify::_mail_sent_last_hour($d), 0, 'absent: nothing sent yet' );
    my $rec = "$d/lazysite/logs/notice-mail.jsonl";
    spit( $rec, '{"t":' . time . "}\n" );
    is( Lazysite::Notify::_mail_sent_last_hour($d), 1, 'one good line counts one' );
    spit( $rec, '{"t":' . time . "}\n{\"t\":\n" );
    my ( $err, $n ) = quietly( sub { Lazysite::Notify::_mail_sent_last_hour($d) } );
    is( $n, undef, 'a torn line: cannot tell, never 1' );
    like( $err, qr/cannot tell - lazysite\/logs\/notice-mail\.jsonl holds a line that is not a send record \(line 2\)/,
        'and the log names it' );
};

subtest 'connector calls: absent is zero; a bad line cannot be counted' => sub {
    my $d = site();
    local $Lazysite::Manager::Connectors::DOCROOT = $d;
    is( Lazysite::Manager::Connectors::_calls_in_last_hour('crm'), 0, 'absent: no calls yet' );
    my $rec = "$d/lazysite/connectors/calls.jsonl";
    my $call = '{"at":' . time . ',"connector":"crm","state":"ok"}' . "\n";
    spit( $rec, $call . $call );
    is( Lazysite::Manager::Connectors::_calls_in_last_hour('crm'), 2, 'two good lines count two' );
    spit( $rec, $call . "garbage\n" . $call );
    my ( $err, $n ) = quietly( sub { Lazysite::Manager::Connectors::_calls_in_last_hour('crm') } );
    is( $n, undef, 'a bad line: cannot tell, never 2' );
    like( $err, qr/cannot tell - lazysite\/connectors\/calls\.jsonl holds a line that is not a call record \(line 2\)/,
        'and the log names it' );
};

done_testing();
