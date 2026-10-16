#!/usr/bin/perl
# SM1090: a manager save that fails at the write leaves an audit row.
#
# The 0.15.5 edge test plan (results file, "Found outside the rows"): every
# cookie `save` answered 400 "Cannot write file: Permission denied" and "the
# failures are not audited at all - only capability refusals are". SM943 ruling
# 1 says errors are recorded; a refused save is an error. Driven here as a
# signed-in person (ManagerSession) against a folder the web-server user cannot
# write: the save fails, and the trail must say so, with the reason.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';
plan skip_all => 'root writes anywhere' if $> == 0;

my @ALL = qw(ui manage_content);
my $s   = new_site( root => repo_root() );
my $d   = $s->docroot;
$s->add_user('writer');
$s->grant( 'writer', 'editors', [@ALL], \@ALL );

mkdir "$d/locked" or die $!;
chmod 0555, "$d/locked";

sub audit_rows {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

my $r = $s->call( 'writer', 'save', query => 'action=save&path=/locked/a.md',
    body => { content => "---\ntitle: A\n---\nbody\n" } );
ok( !$r->{ok}, 'the save fails at the write' ) or diag explain $r;
like( $r->{error} // '', qr/Cannot write file/, '...with the write error' );

# Found by the action the request named: `save`. The trail used to call it an
# `edit` (and a refused new page was never a `create`), so a reader looking for
# the save that failed found nothing.
my @rows = grep { /\| writer \| save \| \/locked\/a\.md \|/ } audit_rows();
is( scalar @rows, 1, 'the failed save left one audit row, named save' ) or diag audit_rows();
unlike( join( '', audit_rows() ), qr/\| (?:edit|create) \| \/locked\//,
    '...and it is not recorded as an edit or a create that never happened' );
like( $rows[0] // '', qr/\| fail \| ui \|/, '...a fail row on the ui origin' );
like( $rows[0] // '', qr/Cannot write file/, '...whose detail is the reason' );

# What a successful save records is unchanged.
mkdir "$d/open" or die $!;
my $ok = $s->call( 'writer', 'save', query => 'action=save&path=/open/b.md',
    body => { content => "---\ntitle: B\n---\nbody\n" } );
ok( $ok->{ok}, 'a save to a writable folder succeeds' ) or diag explain $ok;
my @ok_rows = grep { /open\/b\.md/ } audit_rows();
is( scalar @ok_rows, 1, 'a successful save writes one row' );
like( $ok_rows[0] // '', qr/\| create \| .*\| ok \| ui\s*$/, '...an ok create row, no detail' );

chmod 0755, "$d/locked";
done_testing();
