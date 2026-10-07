#!/usr/bin/perl
# SM961: a submission that arrives while the store is being rewritten is kept.
#
# Delete, confirm and approve rewrite a submissions store whole: read it, write a
# copy, rename the copy over it. The file handler appends. With no shared lock,
# a row appended between the read and the rename went into the file the rename
# threw away - a visitor told "thank you" whose message no longer existed.
# The lock is a sidecar (`.contact.jsonl.lock`) that both sides take, because the
# rename swaps the store file itself.
#
# Both directions, each forced by HOLDING the lock in this process: a real form
# POST in a child must wait for it; a real delete in a child must not read until
# it is released. Each without its half of the fix loses the row.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root site_tempdir);
use Lazysite::Util             ();
use Lazysite::Manager::Plugins ();
use Lazysite::Handlers         ();

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
alarm 60;    # a lock that is never released must fail this file, not hang the suite
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $SECRET = 'test-secret-961';
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms/submissions", "$d/lazysite/logs" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://example.com\n" );
    spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
    spit( "$d/lazysite/forms/handlers.conf", "handlers:\n  - id: jsonl\n    type: file\n" );
    spit( "$d/lazysite/forms/contact.conf", "rate_limit: 0\ntargets:\n  - handler: jsonl\n" );
    return $d;
}

sub post_in_child {
    my ( $d, $message ) = @_;
    my $ts = time() - 10;
    my $body = join '&', "_form=contact", "_ts=$ts", '_tk=' . hmac_sha256_hex( int $ts, $SECRET ),
        '_hp=', 'name=Late', "message=$message";
    # the token is over the integer timestamp the form renders
    $body =~ s/_ts=[\d.]+/_ts=@{[ int $ts ]}/;
    spit( "$d/post.txt", $body );
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        $ENV{REQUEST_METHOD} = 'POST';
        $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
        $ENV{CONTENT_LENGTH} = length $body;
        $ENV{DOCUMENT_ROOT}  = $d;
        $ENV{REMOTE_ADDR}    = '203.0.113.9';
        $ENV{HTTP_HOST}      = 'example.com';
        $ENV{HTTP_ACCEPT}    = 'application/json';
        open STDIN,  '<', "$d/post.txt" or die $!;
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec $^X, $PLUGIN;
        exit 127;
    }
    return $pid;
}

subtest 'a submission arriving during a rewrite waits for it, and is kept' => sub {
    my $d     = site();
    my $store = "$d/lazysite/forms/submissions/contact.jsonl";
    spit( $store, qq({"name":"A","message":"one"}\n{"name":"B","message":"two"}\n) );

    my $lk   = Lazysite::Util::store_lock($store) or die "lock: $!";
    my @rows = grep { /\S/ } split /\n/, slurp($store);    # the rewriter's read
    my $pid  = post_in_child( $d, 'arrived-mid-rewrite' );
    sleep 1.5;    # the child has had time to append, if it could
    spit( "$store.tmp", join( '', map { "$_\n" } grep { !/"A"/ } @rows ) );
    rename "$store.tmp", $store or die $!;    # the rewrite, as _rewrite_store does it
    undef $lk;                                # release
    waitpid $pid, 0;

    my $now = slurp($store);
    like( $now, qr/arrived-mid-rewrite/, 'the late submission is in the store' )
        or diag("store now:\n$now");
    unlike( $now, qr/"A"/, 'and the rewrite still did what it was for' );
};

subtest 'a delete waits for an append in progress, and keeps the new row' => sub {
    my $d     = site();
    my $store = "$d/lazysite/forms/submissions/contact.jsonl";
    my $a     = qq({"name":"A","message":"one"});
    spit( $store, "$a\n" );
    my $id = Lazysite::Handlers::submission_row_id($a);

    my $lk  = Lazysite::Util::store_lock($store) or die "lock: $!";
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        # The child inherits this lock's open handle; while it stays open here
        # the lock can never be released, and the child would wait on itself.
        undef $lk;
        $Lazysite::Manager::Plugins::DOCROOT = $d;
        $Lazysite::Handlers::DOCROOT         = $d;
        my $r = Lazysite::Manager::Plugins::action_form_submission_delete(
            'lazysite/forms/submissions/contact.jsonl', $id );
        exit( $r && $r->{ok} ? 0 : 1 );
    }
    sleep 1.5;    # the delete has had time to read and rewrite, if it could
        # THE PROPERTY, observed directly: while the lock is held the delete has not
        # run. Timing alone cannot force the lost-row interleaving (an unlocked delete
        # usually finishes before the append), but a delete that does not wait is
        # one that can read before an append and rename after it.
    like( slurp($store), qr/"A"/, 'the delete waits while the store is locked' );
    open my $ap, '>>', $store or die $!;
    print {$ap} qq({"name":"C","message":"appended-while-locked"}\n);
    close $ap;
    undef $lk;
    waitpid $pid, 0;
    is( $? >> 8, 0, 'the delete succeeded' );

    my $now = slurp($store);
    like( $now, qr/appended-while-locked/, 'the row appended before the delete read is kept' )
        or diag("store now:\n$now");
    unlike( $now, qr/"A"/, 'and the deleted row is gone' );
};

done_testing();
