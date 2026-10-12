#!/usr/bin/perl
# P17 (WORK-PLAN-0154, ruled 2026-10-12 "Allow own rows"): `(mine)` returns
# only rows whose created_by is the signed-in viewer EVEN WHEN THE TABLE'S READ
# RULE EXCLUDES THEM; anonymous gets nothing; the data endpoint and listings
# still follow the rule.
#
# Reported: a member following posts could be shown their own follow list only
# if members could read the table - which let every member read every row
# (usernames and followed posts). The ruling lets (mine) through for the
# viewer's own rows alone. SECURITY-SENSITIVE, so this proves the negative as
# carefully as the positive: no other viewer's row, no total, no count and no
# single row by key reaches a viewer who may not read the table - through the
# page, and not at all through the data endpoint.
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
use Lazysite::Data::Tables qw(apply_schema insert_row resolve_binding);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $docroot = site_tempdir();
setup_test_site($docroot);
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );

# NOT published, and read only by @editors: a member may not read it.
spit( "$docroot/lazysite/db/tables/follows.yaml",
    "title: Follows\ntimestamps: true\nfields:\n  post:\n    type: text\n" );
spit( "$docroot/lazysite/db/tables/plain.yaml", "title: Plain\nfields:\n  post:\n    type: text\n" );
spit( "$docroot/lazysite/auth/acls.json",
    encode_json( { 'lazysite/db/tables/follows' => { read => ['@editors'] },
            'lazysite/db/tables/plain' => { read => ['@editors'] } } ) );
apply_schema( $docroot, $_ ) for qw(follows plain);

my %key;
for my $row ( [ 'ann', 'P-ANN-1' ], [ 'ann', 'P-ANN-2' ], [ 'bob', 'P-BOB-1' ], [ 'carol', 'P-CAROL-1' ] ) {
    my $r = insert_row( $docroot, 'follows', { post => $row->[1] }, actor => $row->[0] );
    $key{ $row->[1] } = $r->{key};
}
insert_row( $docroot, 'follows', { post => 'P-NOBODY' }, actor => '' );
insert_row( $docroot, 'plain',   { post => 'PLAIN-1' },  actor => 'ann' );

open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "plugins:\n  - plugins/data.pl\n";
close $cf;

my $LIST = '[% FOREACH i IN items %]<li>[% i.post %]</li>[% END %]';
spit( "$docroot/mine.md",
    "---\ntitle: Mine\ntt_page_var:\n  items: db:follows(mine,order=post)\n"
        . "  n: db:follows.count(mine)\n---\n$LIST count=[% n %] total=[% items_total %]\n" );
spit( "$docroot/mine-filtered.md",
    "---\ntitle: M\ntt_page_var:\n  items: db:follows(mine,post=P-ANN-2)\n---\n$LIST\n" );
spit( "$docroot/all.md", "---\ntitle: All\ntt_page_var:\n  items: db:follows(order=post)\n---\n$LIST\n" );
spit( "$docroot/count.md", "---\ntitle: C\ntt_page_var:\n  n: db:follows.count\n---\ncount=[% n %]\n" );
spit( "$docroot/plain-mine.md", "---\ntitle: P\ntt_page_var:\n  items: db:plain(mine)\n---\n$LIST\n" );
for my $p ( 'P-BOB-1', 'P-ANN-1' ) {
    spit( "$docroot/field-$p.md",
        "---\ntitle: F\ntt_page_var:\n  v: db:follows.field(post,id=$key{$p},mine)\n---\nfield=[% v %]\n" );
}

sub render {
    my ( $uri, %as ) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_/ } keys %ENV;
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REDIRECT_URL}   = $uri;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{QUERY_STRING}   = '';
    if ( defined $as{user} ) {
        $ENV{HTTP_X_REMOTE_USER}    = $as{user};
        $ENV{HTTP_X_REMOTE_GROUPS}  = $as{groups} // '';
        $ENV{LAZYSITE_AUTH_TRUSTED} = '1' unless $as{forged};
    }
    unlink glob("$docroot/*.html");
    my $proc = processor_path();
    return scalar qx($^X \Q$proc\E 2>/dev/null);
}
sub bodies { my ($o) = @_; return join ',', sort( $o =~ m{<li>([A-Z]+(?:-[A-Z0-9]+)+)</li>}g ) }

subtest 'a member sees their own rows of a table they may not read, and nobody else\'s' => sub {
    my $o = render( '/mine', user => 'ann' );
    is( bodies($o), 'P-ANN-1,P-ANN-2', 'ann: her two rows' );
    like( $o, qr/count=2 total=2/, 'the count and the total are of her rows, not the table\'s 5' );
    $o = render( '/mine', user => 'bob' );
    is( bodies($o), 'P-BOB-1', 'bob: his one row' );
    like( $o, qr/count=1 total=1/, '...and his count' );
    is( bodies( render( '/mine-filtered', user => 'ann' ) ), 'P-ANN-2', 'a filter narrows her rows further' );
};

subtest 'nothing else reaches a viewer the rule excludes' => sub {
    is( bodies( render( '/all', user => 'ann' ) ), '', 'a binding without (mine): no rows, as before' );
    unlike( render( '/count', user => 'ann' ), qr/count=[1-9]/, 'a .count without (mine): nothing of the table' );
    like( render( '/field-P-BOB-1', user => 'ann' ), qr{field=</p>}, 'bob\'s row by its key, (mine): nothing' );
    like( render( '/field-P-ANN-1', user => 'ann' ), qr/field=P-ANN-1/, 'her own row by its key: hers' );
    is( bodies( render( '/plain-mine', user => 'ann' ) ), '', 'a table with no created_by: refused, no rows' );
};

subtest 'anonymous and a forged identity get nothing' => sub {
    is( bodies( render('/mine') ), '', 'anonymous: no rows' );
    unlike( render('/mine'), qr/count=[1-9]|total=[1-9]/, '...and no count or total' );
    is( bodies( render( '/mine', user => 'ann', forged => 1 ) ), '', 'an untrusted X-Remote-User: no rows' );
};

subtest 'a reader the rule admits is unchanged' => sub {
    is( bodies( render( '/all', user => 'carol', groups => 'editors' ) ),
        'P-ANN-1,P-ANN-2,P-BOB-1,P-CAROL-1,P-NOBODY', 'an editor reads every row' );
    is( bodies( render( '/mine', user => 'carol', groups => 'editors' ) ), 'P-CAROL-1', 'and (mine) is still hers' );
};

subtest 'the data endpoint and every other caller still follow the rule' => sub {
    # lazysite-data.pl assembles its binding from table, order_by, order, limit
    # and offset only, and passes no opt-in - so this is its read, and a (mine)
    # without the opt-in is refused the same way.
    my $as = { user => 'ann', groups => [] };
    for my $spec ( 'follows', 'follows(mine)', 'follows.count(mine)' ) {
        my $r = resolve_binding( $docroot, $spec, $as );
        is( $r->{kind} // '', 'no_such_table', "without the opt-in, '$spec' is refused as absent" );
        ok( !exists $r->{rows} && !exists $r->{value}, '...carrying nothing' );
    }
    my $r = resolve_binding( $docroot, 'follows(order=post)', $as, mine_reads_own => 1 );
    is( $r->{kind} // '', 'no_such_table', 'the opt-in without (mine) is refused' );
    $r = resolve_binding( $docroot, 'follows(mine)', { user => '', groups => [] }, mine_reads_own => 1 );
    is( $r->{kind} // '', 'no_such_table', 'the opt-in for nobody is refused' );
    $r = resolve_binding( $docroot, 'follows(mine,order=post)', $as, mine_reads_own => 1 );
    ok( $r->{ok}, 'the opt-in with (mine) for a viewer reads' );
    is_deeply( [ map { $_->{created_by} } @{ $r->{rows} } ], [ 'ann', 'ann' ], '...rows whose created_by is the viewer' );
    is( $r->{total}, 2, '...and the total of those rows' );
    $r = resolve_binding( $docroot, 'follows(mine,created_by=bob)', $as, mine_reads_own => 1 );
    ok( !$r->{ok} && !exists $r->{rows}, 'a literal owner beside (mine) is refused, not read' );
};

done_testing();
