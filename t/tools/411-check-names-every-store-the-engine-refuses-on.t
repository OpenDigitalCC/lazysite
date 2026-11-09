#!/usr/bin/perl
# Ruling 206 (SM1417; items 9-21 of the 0.16.9 fault survey): LAZYSITE CHECK
# NAMES EVERY STORE THE ENGINE NOW REFUSES ON, WITH ITS REPAIR.
#
# The engine refuses when a send record, a counter, a run record or a state file
# exists and cannot be told; the sysadmin repairs it from the command line, and
# this is where they learn which file and how. Each store is damaged in turn on
# a fresh site: the check FAILs naming the file, what the engine does about it,
# and the repair; it changes nothing. A fresh site with none of them says OK.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $check = repo_root() . '/tools/lazysite-check.pl';

sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<:raw', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub site {
    my $d = site_tempdir();
    make_path( map { "$d/lazysite/$_" } qw(auth manager notify forms logs connectors daemon notify-templates db) );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    return $d;
}

sub check {
    my ($d) = @_;
    return run_child( [ $^X, $check, '--docroot', $d ], stderr => 'merge' )->{out} // '';
}

subtest 'a fresh site: nothing to name' => sub {
    my $out = check( site() );
    like( $out, qr/the send records, counters and run records this site has can all be read/, 'OK' );
};

my @cases = (
    [ 'db/data.sqlite', "not a database\n" x 64, qr/does not pass SQLite's quick_check, so a data migration/, qr/restore '.*data\.sqlite' from a backup/ ],
    [ 'manager/.upload-rate.db', "not a database\n" x 64, qr/does not open as a DB_File database, so every upload is refused/,
        qr/remove '.*\.upload-rate\.db'/ ],
    [ 'notify/suppressed.jsonl', qq({"r":"x","p":"y"}\n{torn\n), qr/holds a line that is not a record \(line 2\), so no notification is sent/,
        qr/it records who unsubscribed, so do not remove the file/ ],
    [ 'notify/ledger.jsonl', "nope\n", qr/notify\/ledger\.jsonl holds a line that is not a record \(line 1\)/,
        qr/repair or remove the named line/ ],
    [ 'notify/status.json', '{"a":', qr/notify\/status\.json does not decode as a JSON object/, qr/next run writes again/ ],
    [ 'forms/submitter-mail.jsonl', "x\n", qr/acknowledgement to the submitter is refused by its cap/, qr/named line/ ],
    [ 'logs/notice-mail.jsonl', "x\n", qr/every notice mail is refused by its cap/, qr/named line/ ],
    [ 'connectors/calls.jsonl', "x\n", qr/every capped connector call is refused/, qr/named line/ ],
    [ 'daemon/scheduler-runs.json', '{"stats-rollup":"boom"}', qr/has entries that are not job records \(stats-rollup\), so no scheduled job runs/,
        qr/every job then runs once/ ],
    [ 'daemon/scheduler.state.json', '{', qr/scheduler\.state\.json does not decode as a JSON object, so the daemon supervisor starts no service/,
        qr/make sure no copy of the service runs/ ],
    [ '.install-state.json', '[]', qr/\.install-state\.json does not decode as a JSON object/, qr/run the upgrade again/ ],
);

for my $c (@cases) {
    my ( $rel, $content, $says, $repair ) = @$c;
    subtest "a damaged lazysite/$rel is a FAIL with its repair" => sub {
        my $d = site();
        spit( "$d/lazysite/$rel", $content );
        my $out = check($d);
        like( $out, qr/lazysite\/\Q$rel\E/, 'the check names the file' );
        like( $out, $says,   'and what the engine does about it' );
        like( $out, $repair, 'and the repair' );
        unlike( $out, qr/counters and run records this site has can all be read/, 'not OK' );
        is( slurp("$d/lazysite/$rel"), $content, 'and changes nothing' );
    };
}

subtest 'an unreadable notice template is named' => sub {
    plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;
    my $d = site();
    my $t = "$d/lazysite/notify-templates/default.xmpp.tt";
    spit( $t, "[% message %]\n" );
    chmod 0000, $t;
    my $out = check($d);
    chmod 0644, $t;
    like( $out, qr/notify-templates\/default\.xmpp\.tt cannot be read/, 'named' );
    like( $out, qr/built-in notice wording is used/, 'with what that means' );
};

done_testing();
