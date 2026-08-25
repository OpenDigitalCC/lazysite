#!/usr/bin/perl
# SM540: plugin diagnostics reach syslog when forward_diagnostics is on. The
# four plugin copies of log_event (form-handler, form-smtp, audit,
# payment-demo) predated Lazysite::Util's forward_line, so an ERROR from a
# submission stayed on STDERR while the docs promised syslog.
#
# Each plugin runs as a real subprocess with the LAZYSITE_SYSLOG_DUMP seam
# (test-only: "<priority> <line>" appended to a file instead of syslog), the
# model being t/unit/lib/17-log-forwarding.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root = repo_root();
my $work = tempdir( CLEANUP => 1 );

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

sub rig {
    my ($name) = @_;
    my $d = "$work/$name";
    make_path("$d/lazysite/forms");
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nforward_diagnostics: true\n";
    close $cf;
    return ( $d, "$work/$name.dump" );
}

# --- form-handler: a POST to a form that does not exist is an ERROR --------
{
    my ( $d, $dump ) = rig('fh');
    my $body = 'form=no-such-form&name=x';
    my $bf   = "$d/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT        => $d,
        REQUEST_METHOD       => 'POST',
        CONTENT_TYPE         => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH       => length $body,
        REMOTE_ADDR          => '203.0.113.5',
        LAZYSITE_SYSLOG_DUMP => $dump,
    );
    my $err = "$d/stderr";
    qx($^X \Q$root/plugins/form-handler.pl\E < \Q$bf\E 2> \Q$err\E);
    like( slurp($err), qr/\[ERROR\] \[form-handler\] .*processing failed/,
        'form-handler: the error is on STDERR (unchanged)' );
    like( slurp($dump), qr/^err .*\[form-handler\] .*processing failed/m,
        'form-handler: and the same line was forwarded at err priority' );
}

# --- form-smtp: --pipe with no input is an ERROR ----------------------------
{
    my ( $d, $dump ) = rig('fs');
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT        => $d,
        LAZYSITE_SYSLOG_DUMP => $dump,
    );
    qx($^X \Q$root/plugins/form-smtp.pl\E --pipe < /dev/null 2>/dev/null);
    like( slurp($dump), qr/^err .*\[form-smtp\] .*smtp failed/m,
        'form-smtp: the pipe failure was forwarded at err priority' );
}

# --- audit: --scan under --docroot logs INFO; the conf is found there -------
{
    my ( $d, $dump ) = rig('audit');
    open my $md, '>', "$d/index.md" or die $!;
    print {$md} "# Home\n";
    close $md;
    local %ENV = ( env_passthrough(), LAZYSITE_SYSLOG_DUMP => $dump );
    delete $ENV{DOCUMENT_ROOT};
    qx($^X \Q$root/plugins/audit.pl\E --scan --docroot \Q$d\E 2>/dev/null >/dev/null);
    like( slurp($dump), qr/^info .*\[audit\] .*audit started/m,
        'audit: the scan start was forwarded at info priority' );
}

# --- forwarding OFF: nothing lands, and the submission is unaffected --------
{
    my ( $d, $dump ) = rig('off');
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    my $body = 'form=no-such-form&name=x';
    my $bf   = "$d/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT        => $d,
        REQUEST_METHOD       => 'POST',
        CONTENT_TYPE         => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH       => length $body,
        REMOTE_ADDR          => '203.0.113.5',
        LAZYSITE_SYSLOG_DUMP => $dump,
    );
    my $out = qx($^X \Q$root/plugins/form-handler.pl\E < \Q$bf\E 2>/dev/null);
    like( $out, qr/"ok":0/, 'the refusal is still answered' );
    ok( !-s $dump, 'and with forwarding off nothing is forwarded' );
}

# --- payment-demo: its copy hands the line on too (pinned at source) --------
{
    my $src = slurp("$root/plugins/payment-demo.pl");
    like( $src, qr/^sub _forward_diag \{/m, 'payment-demo carries the forwarder' );
    my ($le) = $src =~ /(^sub log_event \{.*?^\}$)/ms;
    is( scalar( () = ( $le // '' ) =~ /_forward_diag\(/g ), 2,
        'and its log_event forwards from both the json and the text branch' );
}

done_testing();
