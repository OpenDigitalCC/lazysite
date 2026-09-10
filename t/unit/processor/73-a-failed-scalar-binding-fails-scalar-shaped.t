#!/usr/bin/perl
# SM833: a `.count` that cannot be read answered with a Perl reference.
#
# Reported from the field against 0.13.11: a page carrying `total:
# db:products.count()` rendered `ARRAY(0x564e492aa2d8)` to a visitor - a raw
# reference, and a heap address, on a public page. The shipped documentation
# (starter/docs/data-tables.md) promises "a number, not a list".
#
# THE HAPPY PATH WAS ALWAYS RIGHT, which is why reading the code first pointed
# the wrong way: resolve_db has carried "A SCALAR BINDING IS A SCALAR" since
# SM511 and returns $r->{value} for .count and .field. Reproducing it found the
# real shape of the bug in one run - every FAILURE path returned [], whatever
# the binding asked for. The field's own case is the natural one: a non-public
# table read anonymously, where the refusal is deliberate and meant to look
# exactly like an absent table. The refusal was right; its shape was not.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);
use Lazysite::Data::Query qw(parse_binding);

my $docroot = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($docroot);
make_path("$docroot/lazysite/db/tables");

# One table a visitor MAY read, and one it may not. The second is the field's
# case and the reason this is not an exotic corner.
open my $pf, '>', "$docroot/lazysite/db/tables/things.yaml" or die $!;
print {$pf} "title: Things\npublic: true\nkey: slug\nfields:\n  slug:\n    type: text\n";
close $pf;
open my $sf, '>', "$docroot/lazysite/db/tables/secret.yaml" or die $!;
print {$sf} "title: Secret\nkey: slug\nfields:\n  slug:\n    type: text\n";
close $sf;
apply_schema( $docroot, $_ ) for qw(things secret);
insert_row( $docroot, 'things', { slug => "s$_" } ) for 1 .. 3;
insert_row( $docroot, 'secret', { slug => "x$_" } ) for 1 .. 2;

open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "plugins:\n  - plugins/data.pl\n";
close $cf;

load_processor($docroot);
main::_reset_units();

# resolve_db returns ( $value_or_rows, $total ) - list context, always.
sub bind_var {
    my ($spec) = @_;
    my $out = '';
    my @got;
    {
        local *STDERR;
        open STDERR, '>', \$out or die $!;
        @got = main::resolve_db( $spec, 'total' );
        close STDERR;
    }
    return $got[0];
}

# --- THE CANARY -------------------------------------------------------------
# A "not a reference" assertion passes against a sub that returns nothing at
# all, so prove the binding genuinely works first.
{
    my $v = bind_var('things.count()');
    ok( !ref $v, 'a readable count is not a reference' );
    is( $v, 3, '...and it is the number of rows' );
}

# --- THE FINDING ------------------------------------------------------------
{
    my $v = bind_var('secret.count()');
    ok( !ref $v,
        'a count a visitor may not read answers a value, not a reference' )
        or diag "rendered on the page as: $v";
    is( $v, '', '...and the value is empty rather than a made-up 0' );
}

{
    my $v = bind_var('nosuchtable.count()');
    ok( !ref $v, 'a count of a table that does not exist is not a reference' )
        or diag "rendered on the page as: $v";
}

{
    my $v = bind_var('secret.field(slug,key=x1)');
    ok( !ref $v, 'a refused .field is not a reference either' )
        or diag "rendered on the page as: $v";
}

# --- THE OTHER SHAPE IS UNCHANGED -------------------------------------------
# A list binding must still fail as a list: a page FOREACHes it, and handing
# back '' would make an author's loop the thing that broke.
{
    my $v = bind_var('nosuchtable');
    is( ref $v, 'ARRAY', 'a refused LIST binding still fails as an empty list' );
    is( scalar @$v, 0, '...with no rows in it' );
}

# --- THE COPY IS PINNED -----------------------------------------------------
# _db_empty decides the shape from the spec because the earliest failure it
# serves is the data modules failing to LOAD, when there is no parser to ask.
# That makes it a second reader of one grammar rule, so it is pinned against the
# real parser rather than against a comment.
for my $spec (
    'things', 'things.count()', 'things.count', 'things.field(slug,key=s1)',
    'things.count(slug=s1)', 'things.nonsense()', 'things.counted()',
    )
{
    my $p          = parse_binding($spec);
    my $parser_says = ( $p->{ok} && ( $p->{scalar} // '' ) =~ /\A(?:count|field)\z/ ) ? 1 : 0;
    my $ours        = ref main::_db_empty($spec) ? 0 : 1;
    is( $ours, $parser_says,
        "_db_empty agrees with parse_binding on the shape of '$spec'" );
}

done_testing();
