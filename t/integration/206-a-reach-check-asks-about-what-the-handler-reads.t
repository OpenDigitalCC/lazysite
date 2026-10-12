#!/usr/bin/perl
# SM1047 (P-9's class): a reach check asks about the value the handler uses.
#
# P-9 was acl-set's scope check reading the query while the handler had a body
# path. The sweep of every control-API action that takes a path, a store or a
# reference found two more of the same shape, each a cross-domain read by a
# domain-confined caller:
#
#   form-submissions  the check read `form` when it was sent, the handler reads
#                     `file` when it is sent: form=<mine>&file=<other's store>
#                     returned the other domain's submissions.
#   brief-read/append the check took the typed (table) branch for ANY `type`,
#                     the handler only for type=row: type=table&table=<mine>&
#                     path=<other's page> read and appended to the other brief.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
plan skip_all => 'DBI / DBD::SQLite / YAML::PP not available'
    unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }

my @WORK = qw(manage_content manage_forms read_submissions manage_briefs manage_data);
my @ALL  = ( qw(api ui manage_users manage_domains), @WORK );
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nextensions:\n  - plugins/data.pl\n  - plugins/briefs.pl\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/db/tables", "$d/lazysite/forms/submissions" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
for my $f (qw(mine other)) {
    spit( "$d/sites/$f/contact.md", "---\ntitle: Contact\nform: ${f}_form\n---\n\n:::form\nname | Name\n:::\n" );
    spit( "$d/lazysite/forms/${f}_form.conf", "targets:\n" );
    spit( "$d/lazysite/forms/submissions/${f}_form.jsonl", encode_json( { name => "SECRET-OF-$f" } ) . "\n" );
}
$s->add_user('op');
$s->grant( 'op', 'g-op', [ 'ui', 'manage_users', 'manage_domains', @WORK ], \@ALL );
$s->add_user( 'cks', 'pw-cks-0123456789' );
$s->grant( 'cks', 'g-cks', [ 'ui', @WORK ], \@ALL );
sub as {
    my ( $who, $a, $b, $q ) = @_;
    return $s->call( $who, $a, ( defined $b ? ( body => $b ) : () ), ( defined $q ? ( query => $q ) : () ) );
}
for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks' } ],
    )
{
    ok( as( 'op', @$set )->{ok}, "set up: $set->[0] $set->[1]{host}" );
}
spit( "$d/lazysite/db/tables/t_mine.yaml", "title: t\ndomain: mine.example.org\nkey: slug\nfields:\n  slug:\n    type: text\n" );
as( 'op', 'data-migrate', {}, 'action=data-migrate&table=t_mine' );
ok( as( 'op', 'brief-append', { entry => 'OTHER-BRIEF' }, 'action=brief-append&path=sites/other/index.md' )->{ok},
    "set up: a brief of the other domain's page" );

subtest 'form-submissions: the store read is the store checked' => sub {
    my $st = 'lazysite/forms/submissions';
    my $r = as( 'cks', 'form-submissions', undef, "action=form-submissions&form=mine_form&file=$st/other_form.jsonl" );
    ok( !$r->{ok}, "a form of mine and another domain's store: refused" );
    unlike( encode_json($r), qr/SECRET-OF-other/, "...and none of the other domain's submissions is returned" );
    like( $r->{error} // '', qr/other_form/, '...naming the form whose store it is' );

    $r = as( 'cks', 'form-submissions', undef, "action=form-submissions&form=other_form&file=$st/mine_form.jsonl" );
    ok( $r->{ok}, 'my store under another form name is my store, and is served' ) or diag( $r->{error} // '' );

    $r = as( 'cks', 'form-submissions', undef, 'action=form-submissions&form=mine_form' );
    ok( $r->{ok}, 'my form by name: served' ) or diag( $r->{error} // '' );
    $r = as( 'op', 'form-submissions', undef, "action=form-submissions&form=mine_form&file=$st/other_form.jsonl" );
    ok( $r->{ok}, 'the operator reaches every store' ) or diag( $r->{error} // '' );
};

subtest 'brief-read and brief-append: the typed branch only where the handler takes it' => sub {
    my $was = slurp("$d/lazysite/briefs/sites/other/index.md");
    for my $type (qw(table x)) {
        my $q = "type=$type&table=t_mine&path=sites/other/index.md";
        my $r = as( 'cks', 'brief-read', undef, "action=brief-read&$q" );
        ok( !$r->{ok}, "brief-read type=$type, a table of mine, another domain's page: refused" );
        unlike( encode_json($r), qr/OTHER-BRIEF/, "...and the other domain's brief is not returned" );
        $r = as( 'cks', 'brief-append', { entry => "BY-CKS-$type" }, "action=brief-append&$q" );
        ok( !$r->{ok}, "brief-append type=$type: refused" );
    }
    my $op = as( 'op', 'brief-read', undef, 'action=brief-read&path=sites/other/index.md' );
    unlike( $op->{brief} // '', qr/BY-CKS/, "...and nothing was appended to the other domain's brief" );
    like( $op->{brief} // '', qr/OTHER-BRIEF/, '...which the operator still reads' );

    my $row = as( 'cks', 'brief-append', { entry => 'ROW' }, 'action=brief-append&path=sites/other/index.md&type=row&table=t_mine&key=k1' );
    ok( $row->{ok}, 'a row brief of a table of mine: served (the path, which the row ignores, is not asked about)' ) or diag( $row->{error} // '' );
    my $own = as( 'cks', 'brief-read', undef, 'action=brief-read&path=sites/mine/index.md' );
    ok( $own->{ok}, 'the brief of my own page: served' ) or diag( $own->{error} // '' );
};

done_testing;
