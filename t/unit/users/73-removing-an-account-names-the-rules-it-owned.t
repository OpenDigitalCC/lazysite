#!/usr/bin/perl
# SM1401 (triage T-91): REMOVING AN ACCOUNT NAMES THE RULES IT OWNED. An access
# rule keeps its owner's login after the account goes and nothing said so: the
# rule stays in force as written, only the operator can change it, and the
# remove answered "User removed" alone. Now the command line and the API's
# remove (the manager's account delete) say which rules the account owned and
# where, with the remedy; the rules themselves are not changed.
#
# Reverted, the first subtest fails: the output names no rule.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_cmd run_child site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }

sub a_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    run_cmd( $^X, $script, '--docroot', $d, 'add', $_, 'pw-long-enough-123' ) for qw(alice bob);
    spit( "$d/lazysite/auth/acls.json", encode_json( {
        'content/alice-area'  => { owner => 'alice', read  => ['@team'] },
        'content/alice-page.md' => { owner => 'alice' },
        'content/bob-area'    => { owner => 'bob',   write => ['bob'] },
    } ) );
    return $d;
}

subtest 'the command line names the rules, their paths and the remedy, and changes none' => sub {
    my $d      = a_site();
    my $before = slurp("$d/lazysite/auth/acls.json");
    my $out    = run_cmd( $^X, $script, '--docroot', $d, 'remove', 'alice' );
    like( $out, qr/User 'alice' removed/, 'removed' ) or diag $out;
    like( $out, qr/owned 2 access rules in lazysite\/auth\/acls\.json, whose owner is now no account/,
        'the count and the store' );
    like( $out, qr{/content/alice-area, /content/alice-page\.md}, 'the paths, sorted' );
    unlike( $out, qr{bob-area}, 'and not another account\'s' );
    like( $out, qr/remove it from the manager's Permissions/,              'the remedy' );
    like( $out, qr/lazysite acl set 'PATH' --owner ACCOUNT --actor local/, 'or re-owning it' );
    like( $out, qr/A token cannot/,                                        'and that a token cannot' );
    is( slurp("$d/lazysite/auth/acls.json"), $before, 'the rules are not changed' );
    unlike( run_cmd( $^X, $script, '--docroot', $d, 'list' ), qr/^alice\b/m, 'the account is gone' );
};

subtest 'an account that owned no rule is removed with the sentence it always had' => sub {
    my $d = a_site();
    run_cmd( $^X, $script, '--docroot', $d, 'add', 'carol', 'pw-long-enough-123' );
    my $out = run_cmd( $^X, $script, '--docroot', $d, 'remove', 'carol' );
    like( $out, qr/User 'carol' removed\.\n\z/, 'removed, and nothing about rules' ) or diag $out;
};

subtest 'the API (the manager\'s account delete) answers the rules too' => sub {
    my $d = a_site();
    my $r = decode_json( run_child( [ $^X, $script, '--api', '--docroot', $d ],
            stdin => encode_json( { action => 'remove', username => 'bob' } ), stderr => 'discard' )->{out} );
    ok( $r->{ok}, 'removed' ) or diag explain $r;
    is_deeply( $r->{orphaned_rules}, ['/content/bob-area'], 'orphaned_rules names them' );
    like( $r->{message}, qr/User removed\. The account owned 1 access rule in lazysite\/auth\/acls\.json/, 'and so does the message' );
    like( $r->{message}, qr{/content/bob-area}, '  with the path' );
    like( $r->{message}, qr/manager's Permissions/, '  and the remedy' );
    my $none = decode_json( run_child( [ $^X, $script, '--api', '--docroot', $d ],
            stdin => encode_json( { action => 'remove', username => 'alice' } ), stderr => 'discard' )->{out} );
    is_deeply( $none->{orphaned_rules}, ['/content/alice-area', '/content/alice-page.md'], 'alice\'s two' );
    open my $fh, '<', "$root/starter/manager/users.md" or die $!;
    my $page = do { local $/; <$fh> };
    close $fh;
    like( $page, qr/d\.orphaned_rules && d\.orphaned_rules\.length/, 'the Users page shows the message when there are any' );
};

done_testing;
