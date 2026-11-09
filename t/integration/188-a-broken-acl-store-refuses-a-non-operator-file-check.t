#!/usr/bin/perl
# SM1024 follow-up (ruled 2026-10-12, "Close all three"), and ruling 206
# (2026-11-09, item 2 of the 0.16.9 fault survey): in the manager, an acls.json
# that cannot be read or decoded refuses EVERY per-file check - the operator's
# included - and every table-row check, as cannot-tell (503) naming the store.
#
# Auth::Acl::load_acls answered {} for a broken store, and {} is "no rules", so
# every per-file check passed: a partner refused a file by a rule read and wrote
# it as soon as the store broke, while the render path (SM268 H12) refused every
# protected page. SM1024 made the per-file check answer cannot-tell, but kept the
# operator outside it (file_rule_bypass came first), so the operator read and
# wrote every file past rules the engine could not read. Ruling 206 withdrew
# that exception: the fault is asked before the bypass, the repair is made from
# the command line, and `lazysite check --docroot` names the file.
#
# The file keeps its number and name (other files cite it).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use ManagerSession;

my $root = repo_root();
my $data = eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ? 1 : 0;
my $ms   = ManagerSession::new_site( root => $root,
    conf => "extensions:\n  - extensions/data.pl\n" );
my $d    = $ms->docroot;
my $ACLS = "$d/lazysite/auth/acls.json";

$ms->users( 'setup-sysop', '--user',  'ada' );
$ms->users( 'add',         'bob',     'pw123456789-long-enough' );
$ms->users( 'group-add',   'bob',     'editors' );
$ms->users( 'group-set',   'editors', $_, 'on' ) for qw(ui manage_content);

sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$d/secret.md", "---\ntitle: S\n---\nSECRET-BODY\n" );
put( "$d/open.md",   "---\ntitle: O\n---\nOPEN-BODY\n" );
if ($data) {
    require Lazysite::Data::Tables;
    make_path("$d/lazysite/db/tables");
    put( "$d/lazysite/db/tables/notes.yaml",
        "title: Notes\nkey: slug\nfields:\n  slug:\n    type: text\n  msg:\n    type: text\n" );
    Lazysite::Data::Tables::apply_schema( $d, 'notes' );
    Lazysite::Data::Tables::insert_row( $d, 'notes', { slug => 'n1', msg => 'NOTE-BODY' } );
}

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
  SKIP: {
        skip 'DBI/DBD::SQLite/YAML::PP not available', 1 unless $data;
        $r = $ms->call( 'ada', 'data-rows', query => 'action=data-rows&table=notes' );
        is( $ms->last_status, 200, 'and the rows of a table' ) or diag explain $r;
    }
};

for my $case ( [ 'truncated', '{"secret.md":{"read":["ada"]}' ], [ 'an array', '["secret.md"]' ] ) {
    my ( $what, $bytes ) = @$case;
    subtest "BROKEN acls.json ($what): everyone is refused, the operator included" => sub {
        put( $ACLS, $bytes );
        my ( $s, $r ) = read_as( 'bob', '/secret.md' );
        is( $s, 503, 'bob is refused the protected file (503)' ) or diag explain $r;
        is( $r->{kind},  'cannot-tell',             'as cannot-tell' );
        is( $r->{store}, 'lazysite/auth/acls.json', 'naming the store' );
        unlike( $r->{content} // '', qr/SECRET-BODY/, 'and gets no content' );
        ( $s, $r ) = read_as( 'bob', '/open.md' );
        is( $s, 503, 'every per-file check is refused, a rule cannot be told from none' );
        ( $s, $r ) = read_as( 'ada', '/secret.md' );
        is( $s, 503, 'the operator is refused too' ) or diag explain $r;
        is( $r->{kind}, 'cannot-tell', 'as cannot-tell' );
        unlike( $r->{content} // '', qr/SECRET-BODY/, 'with no content' );
        like( $r->{error} // '', qr/repaired from the command line.*lazysite check --docroot/s,
            'told the repair is made from the command line' );
        my $w = $ms->call( 'ada', 'save', body => { content => "---\ntitle: S\n---\nOVERWRITTEN\n" },
            query => 'action=save&path=secret.md' );
        is( $ms->last_status, 503, 'the operator\'s write is refused' ) or diag explain $w;
      SKIP: {
            skip 'DBI/DBD::SQLite/YAML::PP not available', 2 unless $data;
            $r = $ms->call( 'ada', 'data-rows', query => 'action=data-rows&table=notes' );
            is( $ms->last_status, 503, 'and so is the operator\'s read of a table\'s rows' )
                or diag explain $r;
            unlike( $r->{_raw} // join( ',', %$r ), qr/NOTE-BODY/, 'with no row in the answer' );
        }
        my $check = TestHelper::run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
        like( $check, qr/acls\.json does not decode as a JSON object/, 'lazysite check names the file' );
    };
}

subtest 'ABSENT acls.json: no rules, nothing refused' => sub {
    unlink $ACLS;
    my ( $s, $r ) = read_as( 'bob', '/secret.md' );
    is( $s, 200, 'bob reads it' ) or diag explain $r;
    ( $s, $r ) = read_as( 'ada', '/secret.md' );
    is( $s, 200, 'and so does the operator' ) or diag explain $r;
  SKIP: {
        skip 'DBI/DBD::SQLite/YAML::PP not available', 1 unless $data;
        $r = $ms->call( 'ada', 'data-rows', query => 'action=data-rows&table=notes' );
        is( $ms->last_status, 200, 'and the rows of a table' ) or diag explain $r;
    }
};

done_testing();
