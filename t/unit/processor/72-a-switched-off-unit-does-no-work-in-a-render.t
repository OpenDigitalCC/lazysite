#!/usr/bin/perl
# SM222 L0: a unit switched off does no work inside an ordinary page render.
#
# The class this covers is INLINE work - the kind that happens during a render
# rather than at an endpoint - and the reason L1/L2/L3 never reached it is that
# there is no request arriving anywhere to refuse. `plugins:` in lazysite.conf
# was always the registry; nothing on the render path read it.
#
# THE FIRST MEMBER IS THE DATA UNIT, by the release manager's ruling of
# 2026-09-10, and it is a CONTRACT plugin. That matters: SM409 / ADR 0009
# already rule that a contract plugin executes only when listed and defaults to
# disabled. Manager/Data.pm honours it and resolve_db did not, so this restores
# a standing ruling on one code path rather than changing behaviour in the
# field. (The access log was tried first and reverted: plugins/stats.pl is a
# LEGACY descriptor, which the same ADR says must keep running until its own
# migration - and `plugins:` cannot express "off" for a unit nobody has listed,
# so absence there is not a decision.)
#
# ASSERTS NO OUTPUT. "The action refuses" was already true of the manager
# surface and is exactly what made this invisible: a unit that refuses when
# asked through the manager and works when asked through a page looks healthy
# from every direction an operator can see.
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

my $docroot = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($docroot);

# A real table with real rows, so "no rows" can only mean the gate.
make_path("$docroot/lazysite/db/tables");
open my $df, '>', "$docroot/lazysite/db/tables/things.yaml" or die $!;
print {$df}
    "title: Things\npublic: true\nkey: slug\nfields:\n  slug:\n    type: text\n";
close $df;
apply_schema( $docroot, 'things' );
insert_row( $docroot, 'things', { slug => "s$_" } ) for 1 .. 3;

load_processor($docroot);
my $conf = "$docroot/lazysite/lazysite.conf";

# Set the registry, then ask the render path for the table.
sub rows_with_unit {
    my ($listed) = @_;
    open my $fh, '>:utf8', $conf or die $!;
    print $fh "site_name: L0 test\n";
    print $fh "plugins:\n  - plugins/data.pl\n" if $listed;
    close $fh;

    main::_reset_units();    # an FCGI worker re-reads; so must the test

    # LIST CONTEXT, and it is not a detail: resolve_db returns
    # ( \@rows, $total ), so a scalar assignment silently takes the TOTAL
    # and an earlier draft of this file asserted against the number 3
    # believing it was a row list.
    my $out = '';
    my @got;
    {
        local *STDERR;
        open STDERR, '>', \$out or die "capture STDERR: $!";
        @got = main::resolve_db( 'things', 'items' );
        close STDERR;
    }
    return ( $got[0], defined $out ? $out : '' );
}

# --- THE DISCRIMINATING MEASURE ---------------------------------------------
# A "no rows" assertion that can never produce rows passes against a deleted
# implementation. Prove the rig can see the work happen FIRST, on the same call,
# differing only in the registry.
{
    my ( $rows, $log ) = rows_with_unit(1);
    is( ref $rows, 'ARRAY', 'the render path returns a list for a bound table' );
    is( scalar @$rows, 3,
        'with the data unit listed, the page render reads the three rows' )
        or diag 'the rig cannot observe the work, so the negative below proves nothing';
    unlike( $log, qr/switched off/, 'and says nothing about being switched off' );
}

# --- THE FINDING ------------------------------------------------------------
{
    my ( $rows, $log ) = rows_with_unit(0);
    is( ref $rows, 'ARRAY', 'a switched-off unit still returns a list, not undef' );
    is( scalar @$rows, 0,
        'with the unit absent from the registry, the render does NO WORK' )
        or diag 'the operator switched the data extension off and pages still serve its rows';

    # Silence here would be the defect wearing a disguise: a page rendering zero
    # rows is indistinguishable from a page whose table is empty, which is how
    # the lazy-require bug in this very sub survived to reach the field.
    like( $log, qr/switched off/,
        'and the log says the unit is off rather than leaving an empty page to explain itself' );
    like( $log, qr/items/, '...naming the page variable, so it can be found' );
}

done_testing();
