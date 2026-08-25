#!/usr/bin/perl
# SM575: a data table belongs to the SITE, not to the principal who declared it.
# THIS IS THE DECISION - a deliberate permission, pinned here so that adding
# ownership to the data store is a change somebody has to argue for.
#
# WHY TABLES ARE SHARED. A table is a piece of the site in exactly the way a
# page is: pages render from it, forms deliver into it (SM569), the navigation
# and the search index describe what it produces. It is not an author's private
# document - it is the site's data with a schema. Ownership would mean that the
# principal who declared `products` last spring is the only one who can add a
# column to it, so the routine work of keeping a site correct would queue behind
# whoever happened to run apply_schema first, and a table declared by a partner
# who has since left the estate could never be migrated, rebuilt or dropped
# again. That is a permanent failure that grows, against a transient one - an
# unwanted change - that the safety export and the schema history both cover.
#
# The site is shared, so the CAPABILITY is the gate: manage_data is the
# operator's statement that this principal may manage this site's data, and it
# means all of it. WHAT A TABLE PUBLISHES is a separate question with a separate
# answer - the descriptor's own `public` setting, which defaults closed - so
# "shared between the operator's principals" never implies "shared with the
# world". Confusing the two would be the real risk here, and it is not what this
# file pins.
#
# This is the same answer content and briefs give (t/unit/manager/113,
# t/unit/manager/114). ACLs and themes are the two stores where the answer
# differs; each says why in its own file.
#
# WHAT PRESERVES ACCOUNTABILITY INSTEAD. Every schema operation writes a history
# row stamped with the acting principal, and every drop writes a safety export
# of the rows it destroyed. So a shared table does not lose track of who changed
# what, and a drop by the wrong principal is recoverable rather than final. The
# accountability subtest asserts both; if either were dropped, the sharing
# decision would lose its justification and this test would fail.
#
# WHAT THE FIELD MEASURED: SM575 recorded the data tables as UNVERIFIED - drop,
# rebuild and migrate gate on manage_data alone and nothing had ever asked
# whether one partner could drop another partner's table. The answer, measured
# here, is that it can, and this file makes that an answer rather than an
# absence.
#
# THIS TEST PINS A DELIBERATE PERMISSION. It would FAIL if an ownership check
# were added to the data store: four subtests assert ok:1 from a principal who
# declared nothing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper              qw(dav_users_tool grant_caps);
use Lazysite::Manager::Data qw(action_data_table_save action_data_migrate
    action_data_rows action_data_row_save action_data_table_drop
    action_data_safety_exports action_data_safety_export_read
    action_data_safety_export_delete);
use Lazysite::Manager::Common ();

BEGIN {
    unless ( eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ) {
        require Test::More;
        Test::More::plan( skip_all => 'DBI / DBD::SQLite / YAML::PP not available' );
    }
}

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/auth", "$d/lazysite/db/rebuilds" );

# The data plugin owns these actions and gates every one of them - reads
# included - on being enabled (ADR 0009 / SM469), so the rig has to enable it
# or the file would assert nothing but "the plugin is off".
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;

# The same two-principal rig as t/unit/manager/112-114: real accounts,
# capabilities through a role group, `ui` making the site SECURED. Both hold
# manage_data and nothing more - if the store gated on ownership, this is
# precisely the pair that would be separated.
dav_users_tool( $d, 'add', 'alice',   'alice-pw-0123456789' );
dav_users_tool( $d, 'add', 'mallory', 'mallory-pw-0123456789' );
grant_caps( $d, 'alice',   qw(ui manage_data) );
grant_caps( $d, 'mallory', qw(ui manage_data) );

$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Manager::Data::DOCROOT   = $d;

sub as_principal {
    my ( $user, $code ) = @_;
    local $Lazysite::Manager::Data::auth_user = $user;
    return $code->();
}

my $DESC = <<'YAML';
title: Stockists
key: slug
fields:
  slug:
    type: text
  name:
    type: text
YAML

subtest 'alice declares the table and applies its schema' => sub {
    my $s = as_principal( 'alice', sub { action_data_table_save( 'stockists', $DESC ) } );
    ok( $s->{ok}, 'descriptor written' ) or diag explain $s;
    my $m = as_principal( 'alice', sub { action_data_migrate('stockists') } );
    ok( $m->{ok}, 'schema applied' ) or diag explain $m;

    for my $n ( 1 .. 3 ) {
        my $r = as_principal( 'alice',
            sub {
                action_data_row_save( 'stockists', undef,
                    { slug => "alice$n", name => "Alice row $n" } );
            } );
        ok( $r->{ok}, "alice inserts row $n" ) or diag explain $r;
    }
};

subtest 'the store keeps NO owner to check against' => sub {

    # Structural, not an omission in one code path. A theme carries created_by
    # and an ACL carries owner; a table descriptor carries a schema and a
    # publishing setting, and the only principal it names is the per-operation
    # actor in the history. If a future change adds an owning field, this
    # notices.
    open my $fh, '<:utf8', "$d/lazysite/db/tables/stockists.yaml" or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    unlike( $raw, qr/^(?:owner|created_by):/m,
        'the descriptor records no owning principal' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY read the rows' => sub {
    my $r = as_principal( 'mallory', sub { action_data_rows('stockists') } );
    ok( $r->{ok}, 'mallory reads a table alice declared' ) or diag explain $r;
    is( scalar @{ $r->{rows} || [] }, 3, 'and sees every row' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY write a row' => sub {
    my $w = as_principal( 'mallory',
        sub {
            action_data_row_save( 'stockists', undef,
                { slug => 'mallory1', name => 'Mallory row' } );
        } );
    ok( $w->{ok}, 'mallory inserts into alice\'s table' ) or diag explain $w;

    my $u = as_principal( 'mallory',
        sub {
            action_data_row_save( 'stockists', 'alice1', { name => 'edited by mallory' } );
        } );
    ok( $u->{ok}, 'and updates a row alice wrote' ) or diag explain $u;

    my $rows = as_principal( 'mallory', sub { action_data_rows('stockists') } );
    is( scalar @{ $rows->{rows} || [] }, 4, 'the table carries both principals\' rows' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY drop the table' => sub {
    my $r = as_principal( 'mallory',
        sub { action_data_table_drop( 'stockists', 'stockists' ) } );
    ok( $r->{ok},            'mallory drops a table alice declared' ) or diag explain $r;
    ok( $r->{safety_export}, 'and a safety export is written, naming the file' )
        or diag explain $r;
};

subtest 'ACCOUNTABILITY: the history names WHO, and the drop is recoverable' => sub {

    # This is what makes the sharing decision defensible rather than merely
    # permissive: a shared table records per OPERATION who acted, exactly as a
    # shared brief records per entry, and a destructive act by the wrong
    # principal leaves the rows on disk instead of destroying them.
    my $hist   = Lazysite::Data::Tables::schema_history( $d, 'stockists' );
    my %actors = map { ( $_->{actor} // '' ) => 1 } @{$hist};
    ok( $actors{alice},   'the apply is attributed to alice' )  or diag explain $hist;
    ok( $actors{mallory}, 'the drop is attributed to mallory' ) or diag explain $hist;

    my $l = as_principal( 'mallory', sub { action_data_safety_exports() } );
    my ($e) = grep { $_->{table} eq 'stockists' } @{ $l->{exports} || [] };
    ok( $e, 'the export is listed' ) or diag explain $l;
    is( $e->{kind}, 'dropped', 'as a drop export' );
    is( $e->{rows}, 4,         'carrying every row that was destroyed' );
};

subtest 'PERMITTED BY DESIGN: a second principal MAY read and clear the export' =>
    sub {
    my $l = as_principal( 'mallory', sub { action_data_safety_exports() } );
    my ($e) = grep { $_->{table} eq 'stockists' } @{ $l->{exports} || [] };

    my $read = as_principal( 'mallory',
        sub { action_data_safety_export_read( $e->{file} ) } );
    ok( $read->{ok}, 'mallory reads the export of a table she did not declare' )
        or diag explain $read;

    my $del = as_principal( 'mallory',
        sub { action_data_safety_export_delete( $e->{file} ) } );
    ok( $del->{ok} && $del->{deleted},            'and clears it' ) or diag explain $del;
    ok( !-e "$d/lazysite/db/rebuilds/$e->{file}", 'the file is gone' );

    # SM512's reason, restated: an agent authorised to drop must be authorised
    # to tidy, or every drop leaves permanent debris. Ownership on this store
    # would reintroduce exactly that - the exports one principal cannot clear.
    };

done_testing();
