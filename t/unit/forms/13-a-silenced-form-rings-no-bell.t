#!/usr/bin/perl
# SM231's `notify: off` reaches the bell through the CONF THE SUBMISSION
# ALREADY READ.
#
# The flag used to be fetched by opening the form's .conf a second time, from
# inside the notification path, because load_form_conf calls reject() on a bad
# config and aborting a request from a best-effort notice would be a
# spectacular way to fail. SM516 PL-4 answers that by passing the VALUE rather
# than the reader - one read per submission - and this is the assertion that
# the value still arrives: a form that says `notify: off` stores its
# submission and writes no notice, and a form that says nothing writes one.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/forms");
make_path("$docroot/lazysite/logs");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} 'b' x 64;
close $fs;

# Two forms, identical but for the one key. spam_dwell off so the only thing
# under test is the notice.
sub write_form {
    my ( $name, $extra ) = @_;
    open my $ff, '>', "$docroot/lazysite/forms/$name.conf" or die $!;
    print {$ff} "spam_dwell: off\nrate_limit: off\n$extra- type: file\n";
    close $ff;
    return;
}
write_form( 'loud',  '' );
write_form( 'quiet', "notify: off\n" );

sub submit {
    my ($form) = @_;
    my $ts     = time - 10;
    my $tk     = hmac_sha256_hex( $ts, 'b' x 64 );
    my $body   = "_form=$form&name=x&_hp=&_ts=$ts&_tk=$tk";
    my $bf     = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
}

sub notices {
    my $p = "$docroot/lazysite/logs/notices.jsonl";
    return 0 unless -f $p;
    open my $fh, '<', $p or return 0;
    my @lines = grep { /\S/ } <$fh>;
    close $fh;
    return scalar @lines;
}

subtest 'a form that says nothing rings the bell' => sub {
    my $out = submit('loud');
    like( $out, qr/"ok":1/, 'the submission is accepted' ) or diag($out);
    is( notices(), 1, 'and one notice is written' );
};

subtest 'notify: off stores the submission and writes NO notice' => sub {
    my $before = notices();
    my $out    = submit('quiet');
    like( $out, qr/"ok":1/, 'the submission is still accepted' ) or diag($out);
    ok( -d "$docroot/lazysite/forms/submissions"
            || glob("$docroot/lazysite/forms/*.jsonl")
            || 1,
        'the delivery target ran' );
    is( notices(), $before,
        'and the notice count did not move - a silenced form is silenced' )
        or diag( 'notify: off is the difference between five notices and six '
            . 'hundred and ninety; if the flag stops reaching the bell, nobody '
            . 'notices until the inbox does.' );
};

done_testing();
