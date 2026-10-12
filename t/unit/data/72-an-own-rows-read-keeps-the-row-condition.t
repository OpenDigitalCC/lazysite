#!/usr/bin/perl
# P17 x SM982 (WORK-PLAN-0154, ruled 2026-10-12 "Apply where: too"): a `(mine)`
# own-rows read still applies the published table's row condition (`where:`),
# so a row a moderator has hidden disappears for its author too.
#
# SM1003 lets (mine) read the viewer's own rows of a table whose read rule
# excludes them. SM982 (the security stack, n380..n387) gives a table a row
# condition that every visitor surface applies. The two were built apart, and
# the ruling says how they meet: the own-rows read is a visitor surface like
# any other, and its author is not shown the row the condition holds back - nor
# counted, nor reached by key.
#
# THIS TEST BINDS ONCE BOTH ARE IN THE TREE. Without SM982 there is no `where:`
# to apply, and it skips, saying so; with it, every assertion runs. The own-rows
# read takes its options from the same %opt as every other binding in
# resolve_binding, which is where SM982 puts the condition, so the requirement
# is met by the two landing together - and this is what proves it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir processor_path);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Descriptor ();
use Lazysite::Data::Tables     qw(apply_schema insert_row resolve_binding);

plan skip_all => 'no table row condition in this tree (SM982, `where:`, is on the security stack): '
    . 'the requirement binds when both are in'
    unless Lazysite::Data::Descriptor->can('_check_where');

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_test_site($docroot);
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );

# Read only by @editors, so a member reads it only through (mine); and a row
# condition that holds back what a moderator marked hidden.
spit( "$docroot/lazysite/db/tables/posts.yaml",
    "title: Posts\ntimestamps: true\nwhere: status != hidden\n"
        . "fields:\n  body:\n    type: text\n  status:\n    type: text\n" );
spit( "$docroot/lazysite/auth/acls.json",
    encode_json( { 'lazysite/db/tables/posts' => { read => ['@editors'] } } ) );
my $loaded = Lazysite::Data::Tables::load_table( $docroot, 'posts' );
ok( $loaded->{ok}, 'the descriptor with a row condition loads' ) or BAIL_OUT( $loaded->{error} // '' );
apply_schema( $docroot, 'posts' );

my %key;
for my $row ( [ 'ann', 'ANN-SHOWN', undef ], [ 'ann', 'ANN-HIDDEN', 'hidden' ],
    [ 'ann', 'ANN-OK', 'ok' ], [ 'bob', 'BOB-SHOWN', undef ] )
{
    my $r = insert_row( $docroot, 'posts', { body => $row->[1], ( defined $row->[2] ? ( status => $row->[2] ) : () ) },
        actor => $row->[0] );
    ok( $r->{ok}, "row $row->[1] written" ) or diag( $r->{error} );
    $key{ $row->[1] } = $r->{key};
}

my $ann = { user => 'ann', groups => [] };

subtest 'the own-rows read leaves out the row the condition holds back' => sub {
    my $r = resolve_binding( $docroot, 'posts(mine,order=body)', $ann, mine_reads_own => 1 );
    ok( $r->{ok}, 'ann reads her own rows past the read rule' ) or return;
    is_deeply( [ map { $_->{body} } @{ $r->{rows} } ], [ 'ANN-OK', 'ANN-SHOWN' ],
        'her rows, without the one marked hidden' );
    is( $r->{total}, 2, 'the total does not count it' );
    my $n = resolve_binding( $docroot, 'posts.count(mine)', $ann, mine_reads_own => 1 );
    is( $n->{value}, 2, 'nor does .count' );
    my $f = resolve_binding( $docroot, "posts.field(body,id=$key{'ANN-HIDDEN'},mine)", $ann, mine_reads_own => 1 );
    ok( $f->{ok}, '.field by the hidden row\'s key answers' );
    is( $f->{value}, undef, '...with nothing: her own hidden row is not reached by its key' );
    $f = resolve_binding( $docroot, "posts.field(body,id=$key{'ANN-OK'},mine)", $ann, mine_reads_own => 1 );
    is( $f->{value}, 'ANN-OK', 'a shown row of hers is' );
};

subtest 'a filter in the binding cannot widen it' => sub {
    my $r = resolve_binding( $docroot, 'posts(mine,status=hidden)', $ann, mine_reads_own => 1 );
    ok( $r->{ok}, 'a binding asking for the hidden rows reads' ) or return;
    is_deeply( $r->{rows}, [], '...and gets none of them' );
};

subtest 'the same holds through a rendered page' => sub {
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "plugins:\n  - plugins/data.pl\n";
    close $cf;
    spit( "$docroot/mine.md",
        "---\ntitle: Mine\ntt_page_var:\n  items: db:posts(mine,order=body)\n"
            . "  n: db:posts.count(mine)\n---\n"
            . "[% FOREACH i IN items %]<li>[% i.body %]</li>[% END %] count=[% n %]\n" );
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_/ } keys %ENV;
    $ENV{DOCUMENT_ROOT}         = $docroot;
    $ENV{REDIRECT_URL}          = '/mine';
    $ENV{REQUEST_METHOD}        = 'GET';
    $ENV{QUERY_STRING}          = '';
    $ENV{HTTP_X_REMOTE_USER}    = 'ann';
    $ENV{HTTP_X_REMOTE_GROUPS}  = '';
    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
    my $proc = processor_path();
    my $out  = qx($^X \Q$proc\E 2>/dev/null);
    is( join( ',', $out =~ m{<li>([A-Z-]+)</li>}g ), 'ANN-OK,ANN-SHOWN', 'ann\'s page shows her shown rows only' );
    like( $out, qr/count=2/, '...and counts them' );
    unlike( $out, qr/ANN-HIDDEN/, '...and never the hidden one' );
};

done_testing();
