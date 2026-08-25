#!/usr/bin/perl
# SM516 MA-18: the manager API shells out to two tools it does not ship in its
# own directory - the users tool and the stats plugin - and it found each with
# the same four-candidate ladder, written out twice: the named environment
# override, the cgi-bin sibling of tools/, the run-in-place repo root, then the
# docroot's parent. The two copies are now one _tool_path.
#
# Worth pinning rather than trusting to the diff, because a ladder that
# resolves nothing fails a long way from its cause: _users_tool_path returning
# undef surfaces as "User management not available" on an unrelated action,
# with nothing naming the path it looked for.
#
# The rungs are exercised against a tree this test builds, not against the
# checkout - a first cut asserted the repo-root rung and passed or failed on
# whether the HOST happened to have a tools/ directory beside /srv/tmp, which
# is a test that reports the machine rather than the code.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $d    = tempdir( CLEANUP => 1 );
my $root = repo_root();

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $d;
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# An install laid out the way a packaged one is: cgi-bin/ beside tools/.
my $inst = "$d/inst";
make_path("$inst/tools");
make_path("$inst/cgi-bin");
open my $fh, '>', "$inst/tools/lazysite-users.pl" or die $!;
print {$fh} "#!/usr/bin/perl\n";
close $fh;

# --- the environment override wins ------------------------------------------
{
    local $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl";
    is( main::_users_tool_path(), "$root/tools/lazysite-users.pl",
        'LAZYSITE_USERS_TOOL is taken when it names a file' );
}
{
    local $ENV{LAZYSITE_STATS_TOOL} = "$root/plugins/stats.pl";
    is( main::_stats_tool_path(), "$root/plugins/stats.pl",
        'LAZYSITE_STATS_TOOL is taken when it names a file' );
}

# --- the cgi-bin sibling, which is the production layout --------------------
{
    delete local $ENV{LAZYSITE_USERS_TOOL};
    local $0 = "$inst/cgi-bin/lazysite-manager-api.pl";
    is( main::_users_tool_path(), "$inst/cgi-bin/../tools/lazysite-users.pl",
        'a cgi-bin install finds the tool in its sibling tools/' );
}

# --- run-in-place: tools/ under the script's own directory ------------------
{
    delete local $ENV{LAZYSITE_USERS_TOOL};
    local $0 = "$inst/lazysite-manager-api.pl";
    is( main::_users_tool_path(), "$inst/tools/lazysite-users.pl",
        'a run-in-place checkout finds tools/ beneath itself' );
}

# --- a stale override does not take the tool away ---------------------------
{
    local $ENV{LAZYSITE_USERS_TOOL} = "$d/there-is-no-such-tool.pl";
    local $0 = "$inst/lazysite-manager-api.pl";
    is( main::_users_tool_path(), "$inst/tools/lazysite-users.pl",
        'an override naming nothing falls through rather than failing closed' );
}

# --- nothing to find is undef, not a guess ----------------------------------
{
    delete local $ENV{LAZYSITE_NO_SUCH_TOOL};
    local $0 = "$inst/lazysite-manager-api.pl";
    is( main::_tool_path( 'LAZYSITE_NO_SUCH_TOOL', 'tools/not-a-shipped-tool.pl' ),
        undef, 'a ladder with no rung that exists returns undef' );
}

done_testing();
