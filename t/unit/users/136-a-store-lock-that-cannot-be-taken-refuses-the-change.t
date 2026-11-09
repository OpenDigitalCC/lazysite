#!/usr/bin/perl
# Ruling 206 (item 3 of the 0.16.9 fault survey): THE AUTH STORE LOCK FAILS
# CLOSED.
#
# Every mutating verb of the users tool - an account change, a single-use
# secret's redemption - runs under lazysite/auth/.consume.lock. _consume_lock
# returned undef when the lock could not be opened or taken, and both doors
# (the --api door the manager and the auth wrapper drive, and the CLI) carried
# on unlocked: a reset link could be redeemed twice and two writers could lose
# each other's update. Now both refuse - the API as cannot-tell naming the lock,
# the CLI by dying with the same sentence - nothing is written, and `lazysite
# check` names the lock. An absent lock file is no fault: it is made on first use.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

plan skip_all => 'root opens a 0400 file for writing; run as the site user' if $> == 0;

my $root   = "$FindBin::Bin/../../..";
my $script = "$root/tools/lazysite-users.pl";

sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, @args;
    my $out = `$cmd 2>&1` // '';
    return ( $out, $? >> 8 );
}

sub api {
    my ( $d, $req ) = @_;
    my $in = File::Temp->new;
    print {$in} encode_json($req);
    close $in;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, '--api';
    my $out = `$cmd < \Q$in\E 2>/dev/null`;
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
my $LOCK  = "$d/lazysite/auth/.consume.lock";
my $USERS = "$d/lazysite/auth/users";

subtest 'ABSENT lock file: no fault, the first change makes it' => sub {
    ok( !-e $LOCK, 'no lock file yet' );
    my ( $out, $rc ) = cli( $d, 'add', 'ann', 'pw12345678-long-enough' );
    is( $rc, 0, 'the CLI adds an account' ) or diag $out;
    my $r = api( $d, { action => 'add', username => 'ben', password => 'pw12345678-long-enough' } );
    ok( $r->{ok}, 'and so does the API door' ) or diag explain $r;
    ok( -e $LOCK, 'and the lock file now exists' );
    like( slurp($USERS), qr/^ben:/m, 'both accounts are stored' );
};

subtest 'a lock that cannot be opened refuses every change' => sub {
    chmod 0400, $LOCK or die "chmod: $!";
    my $before = slurp($USERS);
    my $r = api( $d, { action => 'add', username => 'cat', password => 'pw12345678-long-enough' } );
    ok( !$r->{ok}, 'the API door refuses the change' ) or diag explain $r;
    is( $r->{kind},  'cannot-tell',                 'as cannot-tell' );
    is( $r->{store}, 'lazysite/auth/.consume.lock', 'naming the lock' );
    like( $r->{error} // '', qr/lazysite check --docroot/, 'and the check that names it' );
    my ( $out, $rc ) = cli( $d, 'add', 'dan', 'pw12345678-long-enough' );
    isnt( $rc, 0, 'the CLI refuses it too' );
    like( $out, qr/lazysite\/auth\/\.consume\.lock cannot be opened or locked/, 'saying why' );
    is( slurp($USERS), $before, 'and nothing was written' );
    ( $out, $rc ) = cli( $d, 'list' );
    is( $rc, 0, 'a read needs no lock and still answers' );
    like( $out, qr/ann/, 'with the accounts' );
    my $check = `\Q$^X\E \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1`;
    like( $check, qr/lazysite\/auth\/\.consume\.lock .*not writable by the CGI.*single-use link/,
        'lazysite check names the lock and what it stops' );
    chmod 0660, $LOCK;
};

done_testing();
