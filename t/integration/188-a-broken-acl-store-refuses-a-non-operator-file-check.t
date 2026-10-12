#!/usr/bin/perl
# SM1024 follow-up (ruled 2026-10-12, "Close all three"): in the manager, an
# acls.json that cannot be read or decoded refuses a NON-OPERATOR's per-file
# check; the operator is unaffected and can repair the rule from the manager.
#
# Auth::Acl::load_acls answered {} for a broken store, and {} is "no rules", so
# every per-file check passed: a partner refused a file by a rule read and wrote
# it as soon as the store broke, while the render path (SM268 H12) refused every
# protected page. Now the per-file check answers cannot-tell (503) naming the
# store, and `lazysite check --docroot` names the file.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use ManagerSession;

my $root = repo_root();
my $ms   = ManagerSession::new_site( root => $root );
my $d    = $ms->docroot;
my $ACLS = "$d/lazysite/auth/acls.json";

$ms->users( 'setup-sysop', '--user',  'ada' );
$ms->users( 'add',         'bob',     'pw123456789' );
$ms->users( 'group-add',   'bob',     'editors' );
$ms->users( 'group-set',   'editors', $_, 'on' ) for qw(ui manage_content);

sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$d/secret.md", "---\ntitle: S\n---\nSECRET-BODY\n" );
put( "$d/open.md",   "---\ntitle: O\n---\nOPEN-BODY\n" );

sub read_as {
    my ( $who, $path ) = @_;
    my $r = $ms->call( $who, 'read', query => "action=read&path=$path" );
    return ( $ms->last_status // 0, $r );
}

my $RULE = '{"secret.md":{"read":["ada"],"write":["ada"]}}';

subtest 'THE CONTROL: a readable store decides' => sub {
    put( $ACLS, $RULE );
    my ( $s, $r ) = read_as( 'bob', '/open.md' );
    is( $s, 200, 'bob reads a file no rule governs' ) or diag explain $r;
    ( $s, $r ) = read_as( 'bob', '/secret.md' );
    isnt( $s, 200, 'and is refused one the rule keeps from him' );
    ( $s, $r ) = read_as( 'ada', '/secret.md' );
    is( $s, 200, 'the operator reads it' );
};

for my $case ( [ 'truncated', '{"secret.md":{"read":["ada"]}' ], [ 'an array', '["secret.md"]' ] ) {
    my ( $what, $bytes ) = @$case;
    subtest "BROKEN acls.json ($what): a non-operator is refused, the operator is not" => sub {
        put( $ACLS, $bytes );
        my ( $s, $r ) = read_as( 'bob', '/secret.md' );
        is( $s, 503, 'bob is refused the protected file (503)' ) or diag explain $r;
        is( $r->{kind},  'cannot-tell',             'as cannot-tell' );
        is( $r->{store}, 'lazysite/auth/acls.json', 'naming the store' );
        unlike( $r->{content} // '', qr/SECRET-BODY/, 'and gets no content' );
        ( $s, $r ) = read_as( 'bob', '/open.md' );
        is( $s, 503, 'every per-file check is refused, a rule cannot be told from none' );
        ( $s, $r ) = read_as( 'ada', '/secret.md' );
        is( $s, 200, 'the operator still reads it' ) or diag explain $r;
        like( $r->{content} // '', qr/SECRET-BODY/, 'and so can reach the repair' );
        my $check = TestHelper::run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
        like( $check, qr/acls\.json does not decode as a JSON object/, 'lazysite check names the file' );
    };
}

subtest 'ABSENT acls.json: no rules, nothing refused' => sub {
    unlink $ACLS;
    my ( $s, $r ) = read_as( 'bob', '/secret.md' );
    is( $s, 200, 'bob reads it' ) or diag explain $r;
};

done_testing();
