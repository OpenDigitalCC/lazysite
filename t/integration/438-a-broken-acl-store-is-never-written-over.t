#!/usr/bin/perl
# Ruling 206 (item 1 of the 0.16.9 fault survey): A RULE IS NEVER WRITTEN OVER A
# BROKEN acls.json.
#
# load_acls answers {} for a store that exists and will not read or decode
# (SM1024), and every writer loaded, changed one key and saved. So the
# operator's rule set, rule removal or file copy, or a manage_data holder's
# table rule, REPLACED the damaged store with that one rule: every other rule
# on the site was lost. Now each refuses as cannot-tell before it changes
# anything, save_acls refuses as the last line, the damaged file is left byte
# for byte as it was, and `lazysite check` says rule changes are refused. An
# ABSENT store is no fault: the first rule creates it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use ManagerSession;
use Lazysite::Auth::Acl ();

my $root = repo_root();
my $data = eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ? 1 : 0;
my $ms   = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nextensions:\n  - extensions/data.pl\n" );
my $d    = $ms->docroot;
my $ACLS = "$d/lazysite/auth/acls.json";

my @ALL = qw(ui manage_users manage_content manage_data api);
$ms->add_user('boss');
$ms->grant( 'boss', 'sysops', [qw(ui manage_users manage_content manage_data)], \@ALL );
$ms->users( 'group-set', 'sysops', 'manager', 'on' );
$ms->add_user('mia');
$ms->grant( 'mia', 'members', [qw(ui manage_content manage_data)], \@ALL );

sub put   { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }
put( "$d/a.md", "---\ntitle: A\n---\nA.\n" );
if ($data) {
    make_path("$d/lazysite/db/tables");
    put( "$d/lazysite/db/tables/notes.yaml",
        "title: Notes\nkey: slug\nfields:\n  slug:\n    type: text\n" );
}

my $DAMAGED = '{"private/":{"owner":"boss","read":["boss"]},"team/":{"read":["@staff"]';

sub refused_cannot_tell {
    my ( $r, $label ) = @_;
    is( $ms->last_status, 503, "$label: refused (503)" ) or diag explain $r;
    is( $r->{kind},  'cannot-tell',             "$label: as cannot-tell" );
    is( $r->{store}, 'lazysite/auth/acls.json', "$label: naming the store" );
    like( $r->{error} // '', qr/lazysite check --docroot/, "$label: and the check that names it" );
    is( slurp($ACLS), $DAMAGED, "$label: the damaged file is byte-identical" );
}

subtest 'BROKEN acls.json: every rule write is refused and nothing is lost' => sub {
    put( $ACLS, $DAMAGED );
    refused_cannot_tell(
        $ms->call( 'boss', 'acl-set', body => { owner => 'boss', read => ['boss'] },
            query => 'action=acl-set&path=a.md' ),
        'the operator setting a rule' );
    refused_cannot_tell(
        $ms->call( 'boss', 'acl-remove', body => {}, query => 'action=acl-remove&path=private/' ),
        'the operator removing a rule' );
    refused_cannot_tell(
        $ms->call( 'boss', 'acl-remove', body => {}, query => 'action=acl-remove&path=/' ),
        'the operator removing the site-wide rule' );
    refused_cannot_tell(
        $ms->call( 'boss', 'copy', body => {}, query => 'action=copy&path=a.md&to=a-copy.md' ),
        'the operator copying a file' );
    ok( !-e "$d/a-copy.md", 'and no copy was made' );
  SKIP: {
        skip 'DBI/DBD::SQLite/YAML::PP not available', 6 unless $data;
        refused_cannot_tell(
            $ms->call( 'mia', 'data-table-acl-set', body => { table => 'notes', read => ['mia'] } ),
            'a manage_data holder creating a table rule' );
    }
    {
        no warnings 'once';
        local $Lazysite::Auth::Acl::DOCROOT = $d;
        ok( !Lazysite::Auth::Acl::save_acls( { 'a.md' => { owner => 'boss' } } ),
            'save_acls itself refuses' );
        is( slurp($ACLS), $DAMAGED, 'and leaves the file byte-identical' );
    }
    my $check = TestHelper::run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
    like( $check, qr/acls\.json does not decode as a JSON object/, 'lazysite check names the file' );
    like( $check, qr/every rule change and file copy is refused/, 'and says rule changes are refused' );
};

subtest 'ABSENT acls.json: no fault, the first rule creates the store' => sub {
    unlink $ACLS, "$d/a-copy.md";
    my $r = $ms->call( 'boss', 'acl-set', body => { owner => 'boss', read => ['boss'] },
        query => 'action=acl-set&path=a.md' );
    ok( $r->{ok}, 'the operator sets a rule' ) or diag explain $r;
    like( slurp($ACLS) // '', qr/"a\.md"/, 'and the store holds it' );
    $r = $ms->call( 'boss', 'copy', body => {}, query => 'action=copy&path=a.md&to=a-copy.md' );
    ok( $r->{ok}, 'a copy is made' ) or diag explain $r;
    like( slurp($ACLS) // '', qr/"a-copy\.md"/, 'and its owner rule is added beside the first' );
    like( slurp($ACLS) // '', qr/"a\.md"/, 'which is kept' );
  SKIP: {
        skip 'DBI/DBD::SQLite/YAML::PP not available', 1 unless $data;
        $r = $ms->call( 'mia', 'data-table-acl-set', body => { table => 'notes', read => ['mia'] } );
        ok( $r->{ok}, 'a table rule is set' ) or diag explain $r;
    }
};

done_testing();
