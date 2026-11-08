#!/usr/bin/perl
# n776 (SM1355 with SM1357): AN UNDO REFRESHES THE PAGES THAT READ THE TABLE.
#
# SM1357 (n773) made every write the data layer makes touch the table's change
# stamp (Tables::touch_stamp), and a cached page that read the table is checked
# against it, so a row written through any door refreshes the page carrying it
# at once, ttl: or not. SM1355 (n772) undoes a delete by putting the stored row
# back with Tables::reinsert_row, which was written beside n773 and touched no
# stamp: the row came back in the table and the page kept showing it gone.
#
#   * a row deleted leaves the page at once (delete_row touches the stamp);
#   * the row put back as Undo puts it back (reinsert_row) is on the page at
#     once, the render it replaces still inside the page's ttl (a db: page with a
#     ttl is served from its cache until it runs out, or until a stamp moves);
#   * and the stamp itself moved.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir run_processor);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row delete_row);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
setup_test_site($d);
make_path("$d/lazysite/db/tables");
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "extensions:\n  - extensions/data.pl\n";
close $cf;
spit( "$d/lazysite/db/tables/notices.yaml",
    "title: Notices\npublic: true\nfields:\n  title:\n    type: text\n" );
apply_schema( $d, 'notices' );
spit( "$d/notices.md", "---\ntitle: Notices\nttl: 3600\ntt_page_var:\n  rows: db:notices\n---\n"
        . "[% FOREACH r IN rows %]NOTICE:[% r.title %]\n[% END %]\nEND-OF-LIST\n" );

my $ins = insert_row( $d, 'notices', { title => 'The hall is open' } );
ok( $ins->{ok}, 'a row is written' ) or diag explain $ins;
my $key = $ins->{key};
like( run_processor( $d, '/notices' ), qr{NOTICE:The hall is open}, 'the page shows it' );

# Every input older than the render, the render a minute old and inside the
# page's ttl, so the ttl branch would serve it: only a stamp can say the table
# changed.
sub age {
    my $t = time - 60;
    utime( $t - 60, $t - 60, "$d/lazysite/lazysite.conf", glob("$d/*.md"), glob("$d/lazysite/db/stamps/*"),
        glob("$d/lazysite/db/tables/*") );
    utime( $t, $t, glob("$d/notices.html") );
    return;
}

my ($row) = Lazysite::Data::Tables::row_by_key( $d, 'notices', $key );
ok( $row && $row->{title} eq 'The hall is open', 'the stored row is read back' );
age();
my $del = delete_row( $d, 'notices', $key, as => 'operator' );
ok( $del->{ok}, 'the row is deleted' ) or diag explain $del;
my $gone = run_processor( $d, '/notices' );
like( $gone, qr{END-OF-LIST}, 'the page renders' );
unlike( $gone, qr{NOTICE:}, '... and the deleted row has left it at once' );

age();
my $stamp = "$d/lazysite/db/stamps/notices";
my $was   = ( stat $stamp )[9];
my $back  = Lazysite::Data::Tables::reinsert_row( $d, 'notices', $row );
ok( $back->{ok}, 'the row is put back as Undo puts it back' ) or diag explain $back;
cmp_ok( ( stat $stamp )[9], '>', $was, 'putting it back touches the table\'s change stamp' );
like( run_processor( $d, '/notices' ), qr{NOTICE:The hall is open}, '... and the page shows it again at once' );

done_testing();
