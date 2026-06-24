#!/usr/bin/perl
# SM078: the audit trail records the TARGET of an action (path / config key),
# with a backward-compatible reader for old 5-field lines.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");
BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $d;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# A new entry carries the target column.
main::audit_log( 'alice', 'save', 'content/about.md', '1.2.3.4', 'ok' );
my $r = main::action_audit();
ok( $r->{ok}, 'audit reads back' );
my $e = $r->{entries}[0];
is( $e->{action}, 'save',             'action recorded' );
is( $e->{target}, 'content/about.md', 'SM078: target recorded' );
is( $e->{user},   'alice',            'user recorded' );
is( $e->{status}, 'ok',               'status recorded' );

# A config-key target is just as valid.
main::audit_log( 'alice', 'config-set', 'site_name', '1.2.3.4', 'ok' );
is( main::action_audit()->{entries}[0]{target}, 'site_name', 'config key as target' );

# Backward compatibility: an old 5-field line (no target) still parses.
open my $fh, '>>', "$d/lazysite/logs/audit.log" or die $!;
print {$fh} "2026-01-01T00:00:00Z | bob | delete | 9.9.9.9 | fail\n";
close $fh;
my ($old) = grep { ( $_->{user} // '' ) eq 'bob' } @{ main::action_audit( user => 'bob' )->{entries} };
is( $old->{action}, 'delete', 'old line: action parsed' );
is( $old->{target}, '',       'old line: empty target (back-compat)' );
is( $old->{status}, 'fail',   'old line: status parsed' );

# A pipe in a value cannot corrupt the columns.
main::audit_log( 'eve', 'save', 'a|b/c.md', '1.2.3.4', 'ok' );
like( main::action_audit()->{entries}[0]{target}, qr{a b/c\.md}, 'pipe in target is sanitised' );

done_testing();
