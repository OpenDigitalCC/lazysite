use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# A form submission must only report success when a target actually accepted it.
# If every target is disabled / unknown / failed (e.g. the delivery plugin is
# turned off) the submission is NOT saved, so the handler must ERROR rather than
# show a false "thank you".
my $PLUGIN = 'plugins/form-handler.pl';
ok( -f $PLUGIN, 'form handler present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/forms");
my $SECRET = 'delivery-secret-0987654321';
open my $sf, '>', "$d/lazysite/forms/.secret" or die $!; print $sf "$SECRET\n"; close $sf;
open my $fc, '>', "$d/lazysite/forms/contact.conf" or die $!;
print $fc "targets:\n  - handler: jsonl\n"; close $fc;

# handlers.conf with the file handler in a given enabled state.
sub write_handlers {
    my ($enabled) = @_;
    open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
    print $hc "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
            . "    enabled: $enabled\n    path: $d/subs\n";
    close $hc;
}

my $IP = 0;
sub post {
    my $ts = time() - 10;
    my $tk = hmac_sha256_hex( $ts, $SECRET );
    my $body = "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Ada&message=Hi";
    my $bf = "$d/.body";
    open my $w, '>:raw', $bf or die $!; print {$w} $body; close $w;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{REMOTE_ADDR}    = '10.0.0.' . ( ++$IP );
    my $out = qx($^X \Q$PLUGIN\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;     # strip CGI headers
    return decode_json($out);
}

sub record_count {
    my $f = "$d/subs/contact.jsonl";
    return 0 unless -f $f;
    open my $fh, '<', $f or return 0;
    my $n = 0; $n++ while <$fh>;
    close $fh;
    return $n;
}

# 1) Handler enabled: submission accepted and saved.
write_handlers('true');
my $ok = post();
ok( $ok->{ok}, 'enabled handler: submission reported success' ) or diag explain $ok;
is( record_count(), 1, 'enabled handler: the submission is saved' );

# 2) Handler disabled: submission must ERROR and save nothing.
write_handlers('false');
my $before = record_count();
my $off = post();
ok( !$off->{ok}, 'disabled handler: submission reported FAILURE (no false success)' );
like( $off->{error}, qr/not accepting|delivery target|contact the site owner/i,
    'disabled handler: a clear error is returned' );
is( record_count(), $before, 'disabled handler: nothing is saved' );

done_testing;
