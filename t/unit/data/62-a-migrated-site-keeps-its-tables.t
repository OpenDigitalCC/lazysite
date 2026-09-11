#!/usr/bin/perl
# SM850: a site that moved its engine tree out of the docroot keeps its tables.
#
# SM293 lets a site move `lazysite/` out of the document root to
# `<docroot>-lazysite/`, and Lazysite::Paths::lazysite_dir answers with
# whichever exists. The data store did not ask: its descriptors were read from
# "$docroot/lazysite/db/tables" and its SQLite file opened at
# "$docroot/lazysite/db/data.sqlite", so on a migrated site every declared table
# read as undeclared - a db: page rendered nothing and a form bound to a table
# stored nothing. The same hand-built path was in 38 files; t/lint/37 now holds
# them all to the resolver. This drives the two paths the filing named, on a
# migrated fixture: a binding a db: page resolves, and a form into a table
# through the real handler.
#
# Reproduced before the fix: every assertion after the canaries failed.
use strict;
use warnings;
use Test::More;
use File::Basename ();
use File::Path     qw(make_path);
use Digest::SHA    qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Paths        ();
use Lazysite::Data::Tables qw(apply_schema list_tables read_rows resolve_binding);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d    = site_tempdir();
my $base = File::Basename::dirname($d);
my $lz   = Lazysite::Paths::external_lazysite_dir($d);
make_path( $d, "$lz/db/tables", "$lz/forms", "$lz/logs" );
spit( "$lz/lazysite.conf",        "site_name: T\nplugins:\n  - plugins/data.pl\n" );
spit( "$lz/db/tables/leads.yaml", "public: true\nfields:\n  name:\n    type: text\n" );
spit( "$lz/forms/.secret",        'b' x 64 );
spit( "$lz/forms/join.conf", "spam_dwell: off\nrate_limit: off\ntargets:\n  - handler: leads\n" );
spit( "$lz/forms/handlers.conf",
    "handlers:\n  - id: leads\n    type: table\n    name: Leads\n    table: leads\n    fields: name=name\n" );

is( Lazysite::Paths::lazysite_dir($d), $lz, 'the canary: the fixture is a migrated site' );
ok( !-e "$d/lazysite", 'with no engine tree inside the docroot' );

is_deeply( list_tables($d), ['leads'], 'the declared table is found where the tree is' );
my $s = apply_schema( $d, 'leads' );
ok( $s->{ok},                'its schema applies' ) or diag explain $s;
ok( -f "$lz/db/data.sqlite", 'into the store beside the docroot' );

subtest 'a form bound to the table stores its row' => sub {
    my $ts   = time - 10;
    my $tk   = hmac_sha256_hex( $ts, 'b' x 64 );
    my $body = "_form=join&name=Ada&_hp=&_ts=$ts&_tk=$tk";
    my $bf   = "$base/.body";
    spit( $bf, $body );
    my $handler = repo_root() . '/plugins/form-handler.pl';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
    );
    my $out = qx($^X \Q$handler\E < \Q$bf\E 2>&1);
    like( $out, qr/"ok":1/, 'the submission is accepted' ) or diag $out;
    my $r = read_rows( $d, 'leads', as => 'operator' );
    is_deeply( [ map { $_->{name} } @{ $r->{rows} || [] } ], ['Ada'], 'and the row is in the table' )
        or diag explain $r;
};

subtest 'a db: page resolves its binding' => sub {
    my $r = resolve_binding( $d, 'leads', { user => '', groups => [] } );
    ok( $r && $r->{ok}, 'the binding resolves for a visitor' ) or diag explain $r;
    is_deeply( [ map { $_->{name} } @{ $r->{rows} || [] } ], ['Ada'], 'with the stored row' )
        or diag explain $r;
};

ok( !-e "$d/lazysite", 'and nothing recreated an engine tree inside the docroot' );

done_testing();
