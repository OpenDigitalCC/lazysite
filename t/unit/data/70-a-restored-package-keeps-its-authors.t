#!/usr/bin/perl
# P21 revise (WORK-PLAN-0154, ruled 2026-10-12 "Keep original authors"): a
# restored site package's rows keep the created_by/updated_by they were
# exported with, and the restore is recorded as the account that applied it.
#
# n398 (SM989) stamped every restored row with the applier, which fixed rows
# restored as nobody and replaced their real authors with whoever ran the
# restore. The ruling keeps the authors: they travel beside the rows in the
# package, and insert_row takes them as `authors =>`, beside `actor =>` and
# never instead of it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Data::Tables         qw(apply_schema insert_row update_row read_rows);
use Lazysite::Manager::SitePackage ();
use Lazysite::Manager::Domains     ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $DESC = "title: Notes\nkey: code\nfields:\n  code:\n    type: text\n    required: true\n"
    . "  body:\n    type: text\n";

sub instance {
    my ($timestamps) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/backups", "$d/lazysite/db/tables" );
    spit( "$d/lazysite.conf",         "site_name: t\n" );
    spit( "$d/lazysite/domains.conf", '' );
    spit( "$d/index.md",              "---\ntitle: Home\n---\nHome\n" );
    spit( "$d/lazysite/db/tables/notes.yaml", ( $timestamps ? "timestamps: true\n" : '' ) . $DESC );
    apply_schema( $d, 'notes' );
    return $d;
}

my @logged;
{
    no warnings 'redefine';
    my $real = \&Lazysite::Manager::SitePackage::log_event;
    *Lazysite::Manager::SitePackage::log_event = sub { push @logged, [@_]; return $real->(@_) };
}

sub package_of {
    my ($src) = @_;
    local $Lazysite::Manager::SitePackage::DOCROOT   = $src;
    local $Lazysite::Manager::SitePackage::auth_user = 'packer';
    local $Lazysite::Manager::Domains::DOCROOT       = $src;
    my $b = Lazysite::Manager::SitePackage::package_create( '(default)', data_tables => ['notes'] );
    die $b->{error} // 'package failed' unless $b->{ok};
    my ($pkg) = glob "$src/lazysite/backups/$b->{name}";
    return $pkg;
}

sub apply_as {
    my ( $pkg, $dst, $who ) = @_;
    local $Lazysite::Manager::SitePackage::DOCROOT   = $dst;
    local $Lazysite::Manager::SitePackage::auth_user = $who;
    local $Lazysite::Manager::Domains::DOCROOT       = $dst;
    @logged = ();
    return Lazysite::Manager::SitePackage::package_apply( $pkg, content_root => 'client' );
}

sub rows_of {
    my ($d) = @_;
    return { map { $_->{code} => $_ } @{ read_rows( $d, 'notes', as => 'operator' )->{rows} } };
}

subtest 'a restored row keeps the authors it was exported with' => sub {
    my $src = instance(1);
    insert_row( $src, 'notes', { code => 'A', body => 'by alice' }, actor => 'alice' );
    insert_row( $src, 'notes', { code => 'B', body => 'by bob' },   actor => 'bob' );
    update_row( $src, 'notes', 'B', { body => 'edited' }, actor => 'dora', as => 'operator' );
    insert_row( $src, 'notes', { code => 'C', body => 'a public form' }, actor => '' );

    my $dst = instance(1);
    my $r   = apply_as( package_of($src), $dst, 'carol' );
    ok( $r->{ok}, 'the apply succeeds' ) or diag( $r->{error} );
    my ($done) = grep { $_->{table} eq 'notes' } @{ $r->{data_restored} || [] };
    is( $done->{rows},         3, 'three rows restored' );
    is( $done->{authors_kept}, 3, 'each with the authors it was exported with' );

    my $got = rows_of($dst);
    is( $got->{A}{created_by}, 'alice', 'A: created by alice, not carol' );
    is( $got->{A}{updated_by}, 'alice', 'A: updated by alice' );
    is( $got->{B}{created_by}, 'bob',   'B: created by bob' );
    is( $got->{B}{updated_by}, 'dora',  'B: last updated by dora' );
    is( $got->{C}{created_by}, undef,   'C: written anonymously stays anonymous' );

    my ($line) = grep { $_->[2] eq 'table rows restored' } @logged;
    ok( $line, 'the restore is logged per table' ) or return;
    my %f = @{$line}[ 3 .. $#$line ];
    is( $f{user},         'carol', 'naming the account that applied the package' );
    is( $f{authors_kept}, 3,       'and how many rows kept their authors' );
};

subtest 'a package that carries no authors restores as the applier' => sub {
    # The source table has no timestamps, so its export has nothing to keep -
    # the shape a package built before the authors travelled has.
    my $src = instance(0);
    insert_row( $src, 'notes', { code => 'A', body => 'x' }, actor => 'alice' );
    my $dst    = instance(1);
    my $r      = apply_as( package_of($src), $dst, 'carol' );
    my ($done) = grep { $_->{table} eq 'notes' } @{ $r->{data_restored} || [] };
    is( $done->{authors_kept}, 0, 'no authors kept' );
    is( rows_of($dst)->{A}{created_by}, 'carol', 'the row is the applier\'s, as an import\'s is the importer\'s' );
};

subtest 'authors are never taken without an actor, nor in a bad shape' => sub {
    my $d  = instance(1);
    my %ok = ( created_by => 'alice', updated_by => 'bob' );
    my $no = insert_row( $d, 'notes', { code => 'N1' }, authors => \%ok );
    ok( !$no->{ok}, 'authors with no actor is refused' );
    is( $no->{rule}, 'authors_need_actor', 'saying the restore is still written by someone' );
    ok( !insert_row( $d, 'notes', { code => 'N2' }, actor => '', authors => \%ok )->{ok},
        'an empty actor is no actor' );
    for my $bad ( [ 'not a mapping', 'alice' ],
        [ 'an unknown column',   { created_at => '2020-01-01' } ],
        [ 'a control character', { created_by => "ali\nce" } ],
        [ 'a reference',         { created_by => ['alice'] } ],
        [ 'too long',            { created_by => 'a' x 255 } ] )
    {
        my $r = insert_row( $d, 'notes', { code => 'N3' }, actor => 'carol', authors => $bad->[1] );
        ok( !$r->{ok}, "$bad->[0] is refused" );
    }
    is( scalar keys %{ rows_of($d) }, 0, 'and none of them wrote a row' );
    my $good = insert_row( $d, 'notes', { code => 'N4' }, actor => 'carol', authors => \%ok );
    ok( $good->{ok}, 'a well-formed pair is written' );
    is( rows_of($d)->{N4}{created_by}, 'alice', 'as the authors, not the actor' );
};

done_testing();
