#!/usr/bin/perl
# Eight-dimension review D5: disk-full / write-failure injection. The write
# paths must FAIL CLOSED - no torn file renamed into place, no false success -
# and concurrent writers must never produce an interleaved file.
#
# Injection technique (no root needed): run the CGI child under
# `ulimit -f 4` (a few KB file-size cap) with SIGXFSZ ignored (IgnoreXFSZ via
# PERL5OPT), so a write past the cap fails with EFBIG - the same graceful
# failure path as ENOSPC. Pipes (the CGI response) are unaffected by the cap.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_dav_site);

my $root = repo_root();
my $BIG  = ( "lazysite failure-mode filler line\n" x 2048 );    # ~68 KB

# Run @cmd under the file-size cap with SIGXFSZ ignored, feeding $body on
# stdin; returns stdout. %ENV must already be localised by the caller.
sub run_limited {
    my ( $script, $body ) = @_;
    local $ENV{PERL5OPT} = "-I$root/t/lib -MIgnoreXFSZ";
    my $bf = tempdir( CLEANUP => 1 ) . '/body';
    open my $w, '>:raw', $bf or die $!;
    print {$w} ( defined $body ? $body : '' );
    close $w;
    my $cmd = "ulimit -f 4; exec \Q$^X\E \Q$script\E < \Q$bf\E 2>/dev/null";
    return scalar qx(sh -c \Q$cmd\E);
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# --- A. Processor cache write fails closed: old cache survives intact -------
subtest 'processor: failed cache rewrite never installs a torn file' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: WF\n";
    close $cf;
    open my $ix, '>', "$d/index.md" or die $!;
    print $ix "---\ntitle: Big\n---\n\n$BIG";
    close $ix;

    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $d;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{REDIRECT_URL}   = '/index';
    $ENV{QUERY_STRING}   = '';

    # Pre-warm WITHOUT the cap: a good cache lands.
    qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
    my $good = slurp("$d/index.html");
    ok( defined $good && length($good) > 8192, 'pre-warmed cache is complete' );

    # Stale the cache, then render under the cap: the rewrite must fail.
    sleep 1;
    utime undef, undef, "$d/index.md";
    my $out = run_limited( "$root/lazysite-processor.pl" );
    like( $out, qr/filler line/, 'page still rendered and served in full' );

    is( slurp("$d/index.html"), $good,
        'cache on disk is the OLD complete file - the torn rewrite was dropped' );
    my @tmp = glob("$d/index.html.tmp.*");
    ok( !@tmp, 'no tempfile debris left behind' ) or diag "@tmp";
};

# --- B. DAV PUT fails closed: 500, original intact, no tempfile -------------
subtest 'dav: failed PUT reports 500 and leaves the original untouched' => sub {
    my $site = setup_dav_site();
    my $d    = $site->{docroot};
    open my $of, '>', "$d/content/target.md" or die $!;
    print $of "ORIGINAL\n";
    close $of;

    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{REQUEST_METHOD}          = 'PUT';
    $ENV{PATH_INFO}               = '/content/target.md';
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{HTTP_AUTHORIZATION}      = $site->{auth};
    $ENV{CONTENT_LENGTH}          = length $BIG;

    my $out = run_limited( "$root/lazysite-dav.pl", $BIG );
    like( $out, qr/Status:\s*500/, 'PUT under write failure returns 500' );
    like( $out, qr/Write failed/,  'with the write-failure body' );
    is( slurp("$d/content/target.md"), "ORIGINAL\n",
        'destination file is untouched' );
    my @tmp = glob("$d/content/target.md.tmp.*");
    ok( !@tmp, 'no tempfile debris left behind' ) or diag "@tmp";
};

# --- C. Form submission fails closed: error response, no false thank-you ----
subtest 'forms: failed submission write reports failure, not success' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/forms", "$d/subs" );
    my $SECRET = 'wf-secret-1234567890';
    open my $sf, '>', "$d/lazysite/forms/.secret" or die $!;
    print $sf "$SECRET\n";
    close $sf;
    open my $fc, '>', "$d/lazysite/forms/contact.conf" or die $!;
    print $fc "targets:\n  - handler: jsonl\n";
    close $fc;
    open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
    print $hc "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
            . "    enabled: true\n    path: $d/subs\n";
    close $hc;

    # Pre-fill the submissions file BEYOND the cap (written unlimited), so the
    # child's append fails outright - EFBIG before any byte lands.
    open my $pf, '>', "$d/subs/contact.jsonl" or die $!;
    print $pf qq({"prefill":"x"}\n) x 2048;    # ~35 KB, over the 4-block cap
    close $pf;
    my $before = -s "$d/subs/contact.jsonl";

    my $ts = time() - 10;
    my $tk = hmac_sha256_hex( $ts, $SECRET );
    my $body = "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Ada&message=Hello";

    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'POST';
    $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    $ENV{CONTENT_LENGTH} = length $body;
    $ENV{REMOTE_ADDR}    = '10.7.7.7';

    my $out = run_limited( "$root/plugins/form-handler.pl", $body );
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $resp = eval { decode_json($out) } || {};
    ok( !$resp->{ok}, 'submission reports FAILURE when the record cannot be written' )
        or diag $out;
    is( -s "$d/subs/contact.jsonl", $before, 'submissions file unchanged (no partial record)' );
};

# --- D. Concurrent DAV writers: one wins whole, never an interleaved file ---
subtest 'dav: racing PUTs never produce a torn or interleaved file' => sub {
    my $site = setup_dav_site();
    my $d    = $site->{docroot};
    my $lenA = 32768;
    my $bodyA = 'A' x $lenA;
    my $bodyB = 'B' x $lenA;

    for my $iter ( 1 .. 4 ) {
        my @pids;
        for my $body ( $bodyA, $bodyB ) {
            my $bf = "$d/.race-body-" . ( substr $body, 0, 1 );
            open my $w, '>:raw', $bf or die $!;
            print {$w} $body;
            close $w;
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ( !$pid ) {
                %ENV = (
                    %ENV,
                    DOCUMENT_ROOT           => $d,
                    REQUEST_METHOD          => 'PUT',
                    PATH_INFO               => '/content/race.md',
                    SCRIPT_NAME             => '/dav',
                    HTTPS                   => 'on',    # non-localhost DAV refuses plaintext
                    REMOTE_ADDR             => "10.9.$iter." . ( substr( $body, 0, 1 ) eq 'A' ? 1 : 2 ),
                    LAZYSITE_DAV_FAIL_DELAY => 0,
                    HTTP_AUTHORIZATION      => $site->{auth},
                    CONTENT_LENGTH          => length $body,
                );
                exec 'sh', '-c', "exec \Q$^X\E \Q$root/lazysite-dav.pl\E < \Q$bf\E > /dev/null 2>&1";
                die "exec: $!";
            }
            push @pids, $pid;
        }
        waitpid $_, 0 for @pids;

        my $got = slurp("$d/content/race.md");
        is( length($got // ''), $lenA, "iter $iter: file is exactly one full body" );
        my $first = substr( $got // '', 0, 1 );
        ok( $got eq ( $first x $lenA ), "iter $iter: content is uniform (all-$first, no interleave)" );
    }
    my @tmp = glob("$d/content/race.md.tmp.*");
    ok( !@tmp, 'no tempfile debris after the races' ) or diag "@tmp";
};

done_testing();
