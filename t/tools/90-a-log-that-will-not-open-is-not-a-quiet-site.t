#!/usr/bin/perl
# SM907's tail: AT4, AT5 and AT6, which close the filing.
#
# AT6 is the one with teeth. lazysite/logs became a store when the audit trail
# moved into it, and the VISITOR log in the same directory had exactly the
# property the trail had: its readers answered empty or skipped silently, so an
# unreadable visitor log reported a site nobody had visited - and "0 human
# visits" is a sentence a sysop acts on.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Stores qw(stores);

my $root = repo_root();
plan skip_all => 'running as root - file modes do not bind' if $> == 0;

subtest 'AT6: the visitor log is in the store that holds the audit trail' => sub {
    my ($logs) = grep { $_->{dir} eq 'logs' } stores();
    ok( $logs, 'the catalogue knows the directory' ) or return;
    ok( $logs->{store}, 'and classifies it as a store' );
    my %mods = map { $_ => 1 } @{ $logs->{modules} || [] };
    ok( $mods{'plugins/stats.pl'},
        'the visitor-log reader is one of its modules' )
        or diag( 'Listed, or lint 121 never looks at the six readers that '
            . 'answered empty.' );
};

subtest 'AT6: the MAIN access log already refused correctly - protect that' => sub {
    # Measured while building this, and it narrowed the filing: the headline read
    # was never the lie. An unreadable access log does not report a quiet site; it
    # refuses and says which fault it is. This subtest exists so that stays true.
    my $stats = "$root/plugins/stats.pl";
    plan skip_all => "no $stats" unless -f $stats;

    my $d   = site_tempdir();
    my $log = "$d/access.log";
    open my $fh, '>', $log or die $!;
    print {$fh} qq{127.0.0.1 - - [27/Sep/2026:10:00:00 +0000] "GET / HTTP/1.1" 200 512 "-" "Mozilla/5.0"\n};
    close $fh;
    chmod 0000, $log or plan skip_all => 'cannot chmod';

    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx{$^X \Q$stats\E --export --docroot \Q$d\E 2>/dev/null};
    chmod 0644, $log;

    unlike( $out, qr/"ok"\s*:\s*(?:1|true)/,
        'it does not answer ok with nothing in it' );
    like( $out, qr/not readable by the web server user/,
        'it names the fault instead of reporting no visitors' );
};

subtest 'AT6: the secondary log readers no longer skip in silence' => sub {
    # A log tail, the rotated visitor logs and the form-event files each answered
    # empty or skipped on a failed open. Those do not change the headline count,
    # they shorten it - which is worse in one way, because nothing looks wrong.
    my $src = do {
        open my $fh, '<', "$root/plugins/stats.pl" or die $!;
        local $/;
        <$fh>;
    };
    for my $what ( 'a log tail', 'the visitor log', 'a visitor log', 'a form-event log' ) {
        like( $src, qr/_cannot_read\( '\Q$what\E'/,
            "$what reports before answering empty" );
    }
    like( $src, qr/return if \$!\{ENOENT\}/,
        'and absence stays silent, because a site with no visitors has no log' );
    like( $src, qr/logs_unreadable => \[ _unique/,
        'the export names which logs would not open' )
        or diag( 'Without this a caller cannot tell a short count from a '
            . 'complete one.' );
};

subtest 'AT4: the check names what an unwritable file actually costs' => sub {
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-check.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/every surface appends here/,
        'the audit log says events are lost, not that a manager cannot save' )
        or diag( 'No manager saves the audit trail; every surface appends to it, '
            . 'and what an operator loses is the record.' );
    like( $src, qr/no account can be created/, 'the user store says what it costs' );
    like( $src, qr/the navigation cannot be saved/, 'and the navigation says its own' );
};

subtest 'AT5: a credential template starts where the save would leave it' => sub {
    my $src = do {
        open my $fh, '<', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/return 0640 if \$path =~ m\{\/lazysite\/forms\/\.\*\\\.example\$\}/,
        'the installer gives a forms example 0640' )
        or diag( 'It shipped 0644, so `cp smtp.conf.example smtp.conf` produced a '
            . 'world-readable file for an SMTP password. The manager save chmods '
            . '0660; the template it was copied from did not start there.' );
};

done_testing();
