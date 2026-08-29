#!/usr/bin/perl
# SM682 round 2: `writable_by` binds write_data on EVERY surface that writes a row.
#
# WHAT WAS MEASURED, AND BY WHOM. The edge-testing agent drove a write_data-only
# partner token (`manage_data` FALSE, `manage_users` FALSE, one group) against
# the control-API `data-row-save` on 0.11.5, over four tables differing only in
# `writable_by`:
#
#   writable_by: [its own group]  -> ok:true   (correct)
#   no writable_by                -> ok:true   (MUST REFUSE)
#   writable_by: []               -> ok:true   (MUST REFUSE - empty is CLOSED)
#   writable_by: [another group]  -> ok:true   (MUST REFUSE - not a member)
#
# Three of the four cases that must refuse all wrote. The allow-list existed
# only in lazysite-data.pl, the app-user endpoint; the control-API path carried
# the capability gate (manage_data OR write_data) and nothing else. So on that
# surface `write_data` was an instance-wide table write - which is precisely the
# grant it exists to avoid, in the words of the comment on the branch that was
# never reached.
#
# THE FIX IS ONE DECISION, NOT TWO COPIES. SM578's warning applies verbatim:
# four package verbs each carried their own copy of one rule and two were
# missed. So this asserts the shared function directly, over the four cases, for
# both capabilities - and separately that neither surface reimplements it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require YAML::PP; 1 } or plan skip_all => 'YAML::PP not available';
}

use Lazysite::Manager::Data ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;
$Lazysite::Manager::Data::DOCROOT = $docroot;

sub declare {
    my ( $name, $wb ) = @_;
    open my $fh, '>', "$docroot/lazysite/db/tables/$name.yml" or die $!;
    print {$fh} "title: $name\nkey: code\nfields:\n  code:\n    type: text\n";
    print {$fh} $wb if defined $wb;
    close $fh;
}

declare( 'named',   "writable_by:\n  - editors\n" );
declare( 'other',   "writable_by:\n  - somebody-else\n" );
declare( 'empty',   "writable_by: []\n" );
declare( 'absent',  undef );

my $WRITE_ONLY  = { write_data  => 1 };
my $MANAGE_DATA = { manage_data => 1 };
my @GROUPS      = ('editors');

sub refused {
    my ( $table, $caps ) = @_;
    return Lazysite::Manager::Data::row_write_refusal( $table, $caps, \@GROUPS );
}

subtest 'write_data: the list is an ALLOW-LIST, and empty is closed' => sub {
    ok( !refused( 'named', $WRITE_ONLY ),
        'a table naming your group is writable' );

    ok( refused( 'other', $WRITE_ONLY ),
        'a table naming a group you are not in is REFUSED' )
        or diag( 'Measured writing on 0.11.5 - the allow-list was not consulted '
            . 'on the control-API path.' );

    ok( refused( 'empty', $WRITE_ONLY ),
        'an explicitly empty list is CLOSED, not open' )
        or diag( 'An empty list means "no restriction" to manage_data. To '
            . 'write_data it must mean the opposite, or write_data is '
            . 'instance-wide write under another name.' );

    ok( refused( 'absent', $WRITE_ONLY ),
        'a table with no writable_by at all is closed to write_data' );
};

subtest 'manage_data: the same list NARROWS, and empty means unrestricted' => sub {
    ok( !refused( 'named', $MANAGE_DATA ), 'named: writable' );
    ok( refused( 'other', $MANAGE_DATA ),
        'a list naming somebody else still narrows an administrator' );
    ok( !refused( 'empty',  $MANAGE_DATA ), 'empty: unrestricted (historic behaviour)' );
    ok( !refused( 'absent', $MANAGE_DATA ), 'absent: unrestricted (historic behaviour)' );
};

subtest 'the refusal names the table and why' => sub {
    my $r = refused( 'other', $WRITE_ONLY );
    like( $r->{error}, qr/somebody-else/,
        'it names the groups that MAY write' );
    is( $r->{kind}, 'forbidden', 'and refuses as forbidden' );
    my $e = refused( 'empty', $WRITE_ONLY );
    like( $e->{error}, qr/names no writable_by groups/,
        'the empty case explains itself differently, because it is a different'
            . ' situation for the operator to fix' );
};

# THE SURFACE, DRIVEN. The unit cases above prove the RULE; this proves the
# control-API path actually asks it, which is the half that was missing on
# 0.11.5. A source-level check is not enough here: a call left in place but
# neutered would satisfy it, and the whole defect was a rule that existed and a
# surface that did not consult it.
subtest 'the control API refuses the four cases the field measured' => sub {
    eval { require ManagerSession; ManagerSession->import('new_site'); 1 }
        or plan skip_all => 'ManagerSession not available';
    my $root = "$FindBin::Bin/../../..";
    plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

    my @ALL = qw(ui manage_data write_data);
    my $site = new_site(
        root => $root,
        conf => "control_api_enabled: true\nplugins:\n  - plugins/data.pl\n"
    );
    make_path( $site->docroot . '/lazysite/db/tables' );

    my $BASE = "key: code\nfields:\n  code:\n    type: text\n";
    my %desc = (
        wb_named  => "writable_by:\n  - datafolk\n" . $BASE,
        wb_other  => "writable_by:\n  - somebody-else\n" . $BASE,
        wb_empty  => "writable_by: []\n" . $BASE,
        wb_absent => $BASE,
    );
    for my $t ( sort keys %desc ) {
        open my $f, '>', $site->docroot . "/lazysite/db/tables/$t.yaml" or die $!;
        print {$f} $desc{$t};
        close $f;
    }

    # Migrate them, or an allowed write fails at the storage layer and the
    # test cannot tell "the gate let it through" from "the gate refused".
    require Lazysite::Data::Tables;
    Lazysite::Data::Tables::apply_schema( $site->docroot, $_ ) for sort keys %desc;

    $site->add_user('appuser');
    # A write_data-only partner: the exact instrument the edge agent used.
    $site->grant( 'appuser', 'datafolk', [ 'ui', 'write_data' ], \@ALL );

    my %got;
    for my $t ( sort keys %desc ) {
        # No `key`: an INSERT. Sending one makes this an update, and updating
        # the key field is refused for its own unrelated reason - which would
        # look like the gate working while proving nothing about it.
        my $r = $site->call( 'appuser', 'data-row-save',
            body => { table => $t, row => { code => 'c1' } } );
        $got{$t} = $r->{ok} ? 'wrote' : 'refused';
        note( "$t: " . ( $r->{error} // 'ok' ) );
    }

    is( $got{wb_named}, 'wrote',
        'a table naming the account\'s group is writable' );
    is( $got{wb_other}, 'refused',
        'a table naming a group it is not in is REFUSED on the control API' )
        or diag( 'Measured as `wrote` on 0.11.5 - this is the escalation.' );
    is( $got{wb_empty}, 'refused',
        'an explicitly empty list is CLOSED on the control API' );
    is( $got{wb_absent}, 'refused',
        'and a table with no writable_by is closed to write_data' )
        or diag( 'If these three write, write_data is instance-wide table '
            . 'write on this surface, which is the grant it exists to avoid.' );
};

done_testing();
