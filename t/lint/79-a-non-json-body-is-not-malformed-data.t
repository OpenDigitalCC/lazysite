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
plan skip_all => 'manager pages missing' unless -f $layout && -f $files;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
my $lt = slurp($layout);
my $fm = slurp($files);

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
    my ($fn) = $fm =~ /function openHistoryOverview\(\) \{(.*?)\n\}/s;
    ok( defined $fn, 'openHistoryOverview is present' ) or return;

    like( $fn, qr/mgJson/, 'the overview parses through mgJson' )
        or diag( 'A bare r.json() here is the whole defect.' );
    unlike( $fn, qr/\.then\(function\(r\) \{ return r\.json\(\); \}\)/,
        'and not through a bare r.json()' );
    like( $fn, qr/could not be\s*'?\s*\+?\s*'?loaded/,
        'the failure message describes the FETCH, not the data' );
};

subtest 'the control is shown again, and only when history is on' => sub {
    my ($fn) = $fm =~ /function loadGitStatus\(\) \{(.*?)\n\}/s;
    ok( defined $fn, 'loadGitStatus is present' ) or return;
    unlike( $fn, qr/hb\.style\.display = 'none';\s*\n\s*\}\)/,
        'the beta hide is gone' );
    like( $fn, qr/GIT\.enabled \? '' : 'none'/,
        'and the control follows whether content history is enabled' )
        or diag( 'Showing it on a site with no history would offer a button '
            . 'whose only possible answer is "not enabled".' );
};

subtest 'the placement half is recorded as still open' => sub {
    # A fix that quietly answers half a filing and says nothing leaves the
    # other half looking done.
    like( $fm, qr/PLACEMENT half of SM461 is untouched and still open/,
        'the code says which half was not addressed' );
};

done_testing();
