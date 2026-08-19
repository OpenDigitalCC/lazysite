#!/usr/bin/perl
# SM288: which @group entries reach which accounts, resolved not named.
#
# SM288 made every channel honour an account's real groups. On MCP and the
# control API those @group entries had been silently inert, so the fix WIDENS
# effective access on live sites - intended, and still a change of permissions
# an operator is entitled to see rather than meet.
#
# WHY NOT IN lazysite-check. That tool names the entries and stops, deliberately:
# it is core-Perl by design, and resolving membership there would be a fourth
# answer to "which groups is this account in" - the defect SM288 exists to
# remove. Reporting DIRECT membership only would be worse than not reporting,
# because it would tell an operator somebody does not gain access when they do.
#
# So this lives where groups_for_user() is already loaded, and the NESTED case
# below is the one that matters: it is precisely what a direct-membership
# shortcut would get wrong, and it would get it wrong in the under-reporting
# direction.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $acl  = "$root/tools/lazysite-acl.pl";
my $usr  = "$root/tools/lazysite-users.pl";
plan skip_all => 'tools missing' unless -f $acl && -f $usr;

my $d = tempdir( 'lazysite-reach-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path("$d/upcoming");
open my $p, '>', "$d/upcoming/index.md" or die $!;
print {$p} "---\ntitle: U\n---\n\nx\n";
close $p;

sub users { return run_cmd( $^X, $usr, '--docroot', $d, @_ ) }
sub acl { return run_cmd( $^X, $acl, @_, '--docroot', $d, '--actor', 'local' ) }

users( 'add',       'partner',  'ppass123456' );
users( 'add',       'nested',   'npass123456' );
users( 'add',       'outsider', 'opass123456' );
users( 'group-add', 'partner',  'agents' );

# NESTED: 'inner' is a member of 'agents', and 'nested' is in 'inner'. A report
# that only looked at direct membership would miss this account entirely.
# The closure walks UPWARD: a user's groups, plus every group listing one of
# them as a member. Both groups must exist before the nest, which is why
# 'agents' is given a capability first - the same order t/unit/users/25 uses.
users( 'group-add', 'nested', 'inner' );
users( 'group-set', 'agents', 'ui', 'on' );
my $nest = users( 'group-nest', 'inner', 'agents' );

# THE REAL WRITER, never a hand-built store: a reader test driven from a
# hand-made file proves the reader agrees with the test author, not with the
# writer.
acl( 'set', '/upcoming', '--read', '@agents' );

# run_cmd returns the OUTPUT as a string, not a structure. An earlier version
# of this file checked ->{status} on it, which is always undef on a string - so
# the fixture assertion could never pass and the nested case never ran.
my $text = acl('group-reach') // '';

subtest 'the fixture really wrote an @group entry' => sub {
    like( $text, qr/\@agents/, 'the entry is reported at all' )
        or diag( "got:\n$text\n"
            . 'If the writer did not store it, everything below is vacuous.' );
};

subtest 'direct membership is resolved' => sub {
    like( $text, qr/reaches:.*\bpartner\b/, 'the direct member is named' )
        or diag("got:\n$text");
    unlike( $text, qr/reaches:.*\boutsider\b/,
        'and an account in no relevant group is not' )
        or diag( 'Over-reporting is its own failure: an operator told an '
            . 'account gains access when it does not will go looking for a '
            . 'grant that was never there.' );
};

subtest 'nested membership is resolved too' => sub {
    # NO SKIP HERE. The first version skipped when the nest command failed,
    # which meant a fixture that silently did not nest reported as "nothing to
    # check" - the same shape as the skip_all SM388 removed from t/lint/42.
    # If the nest did not happen, that is a failure of this test's setup and it
    # should say so.
    like( $nest, qr/nested inside/,
        'the fixture nested the groups' )
        or diag( 'Without the nest there is no nested case to resolve, and the '
            . 'assertion below would pass or fail for unrelated reasons.' );

    like( $text, qr/reaches:.*\bnested\b/,
        'an account reached only through a nested group is named' )
        or diag( "got:\n$text\n"
            . 'This is exactly what a direct-membership shortcut misses, and '
            . 'it misses it in the UNDER-reporting direction - telling an '
            . 'operator nobody gains access when somebody does.' );
};

subtest 'and it says the widening already happened' => sub {
    like( $text, qr/EVERY channel/i,
        'the report states the reach is now all channels' );
    like( $text, qr/gained access/i,
        'and which direction the change went' )
        or diag( 'Nobody should read this as "partners gain groups". They had '
            . 'them; two channels were discarding them.' );
};

done_testing();
