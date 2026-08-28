#!/usr/bin/perl
# SM461: an overview that could not load says what happened, instead of
# blaming the data.
#
# THE REPORT: the all-files history overview showed "Error: JSON.parse:
# unexpected character at line 1 column 1" while the data behind it was fine -
# git-history-summary returns valid JSON over the API, 15,307 bytes, 131 files.
# So the fault was in the page's handling, and the message pointed the operator
# at their content when what had happened was a 500, a die, or a proxy timeout.
#
# SM445 FIXED THE 401 HALF of this class in the shared wrapper. The rest did
# not go away: every other non-JSON body still reached r.json() and became a
# parse error attributed to the data.
#
# WHAT IS STILL OPEN, deliberately: the PLACEMENT argument. Seeing this
# overview requires the Files app - full read and write over content - and an
# auditor who needs to know what changed should not need permission to change
# it. That needs a capability decision and is not this.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";
my $files  = "$root/starter/manager/files.md";
# SM664: the all-files overview moved to the content-history plugin's row on
# the Plugin Config page. The per-file History control stays on Files, so both
# pages are still read here - the guard being tested is a property of the
# FETCH and has to hold wherever the fetch lives.
my $plug   = "$root/starter/manager/plugin-config.md";
plan skip_all => 'manager pages missing'
    unless -f $layout && -f $files && -f $plug;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
my $lt = slurp($layout);
my $fm = slurp($files);
my $pc = slurp($plug);

subtest 'the shared parser exists and checks before it parses' => sub {
    my ($fn) = $lt =~ /window\.mgJson = function \(r\) \{(.*?)\n    \};/s;
    ok( defined $fn, 'mgJson is defined in the shared layout' )
        or diag( 'One place, so a fix cannot be half-applied - the reason '
            . 'SM445 was fixed here rather than in 96 call sites.' );

    # THE CONDITION, not the presence of the words. An earlier version matched
    # /content-type/ anywhere in the function, so removing the check from the
    # `if` while leaving the variable that reads the header still passed - the
    # string was there and the test was satisfied by it.
    # `[^)]*` was wrong here: the condition contains parentheses of its own
    # (a method call), so it matched nothing and every assertion under it
    # failed for the wrong reason.
    my ($cond) = $fn =~ /\n\s*if \((.+)\) return r\.json\(\);/;
    ok( defined $cond, 'the parse is guarded by a findable condition' );
    like( $cond, qr/r\.ok/, 'the guard checks the status' );
    like( $cond, qr/\bct\b/, 'and the content type' )
        or diag( "the guard was: " . ( $cond // '(none)' ) . "\n"
            . 'A 200 returning an HTML error page is the case a status check '
            . 'alone still misreads.' );
    like( $fn, qr/r\.status/, 'and the failure names the status' );
    like( $fn, qr/r\.text\(\)/, 'reading the body as TEXT to report it' )
        or diag( 'Calling r.json() on it is exactly the mistake being fixed.' );
};

subtest 'the overview uses it, and no longer blames the data' => sub {
    my ($fn) = $pc =~ /function openHistoryOverview\(\) \{(.*?)\n\}/s;
    ok( defined $fn, 'openHistoryOverview is present' ) or return;

    like( $fn, qr/mgJson/, 'the overview parses through mgJson' )
        or diag( 'A bare r.json() here is the whole defect.' );
    unlike( $fn, qr/\.then\(function\(r\) \{ return r\.json\(\); \}\)/,
        'and not through a bare r.json()' );
    like( $fn, qr/could not be\s*'?\s*\+?\s*'?loaded/,
        'the failure message describes the FETCH, not the data' );
};

subtest 'the overview is offered from the plugin that owns it' => sub {
    # SM664 closed SM461's placement half: the button is on the content-history
    # plugin's row, not at the top of the file browser. This replaces the
    # assertion that the placement half was still open - which was true, and
    # stopped being true, and a test that outlived its filing would have made
    # the fix look like a regression.
    like( $pc, qr/openHistoryOverview\(\)/,
        'the Plugin Config page offers the overview' );
    like( $pc, qr/plugin\.id === 'content-history'/,
        'on the content-history row specifically' );
    unlike( $fm, qr/hist-overview/,
        'and the Files page no longer carries it' )
        or diag( 'Left behind, the two copies drift and only one gets fixed.' );
};

done_testing();
