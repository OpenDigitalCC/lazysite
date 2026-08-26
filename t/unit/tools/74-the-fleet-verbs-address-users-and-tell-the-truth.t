#!/usr/bin/perl
# SM625/SM626: two defects one fleet run made visible at once.
#
# 26 sites, repaired, every one reporting "43 ok, 0 failures" - and the summary
# said "0 clean, 0 repaired, 26 need a human".
#
# SM626: a pending DECISION was counted as an unfixed DEFECT. The only thing
# outstanding was that a group seeded before this release has not been told what
# to do about capabilities the release added. That cannot be repaired; it clears
# when a human decides. Counting it with genuine failures put 26 healthy sites
# in the worst bucket, made the tally unable to improve, and exited non-zero -
# so a scheduled fleet run goes red forever and nobody reads it.
#
# SM625: the verb that settles that decision was the one verb with no fleet
# addressing. SM321 gave --domain/--all to `check` and `acl`; `repair`, `probe`
# and `migrate-engine-tree` have it; `users` was a pure pass-through. So the one
# action needed across 26 sites was the one that could only be done in a shell
# loop - which is exactly what the operator ended up writing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => "no $cli" unless -f $cli;

my $src = do { open my $fh, '<', $cli or die $!; local $/; <$fh> };

# --- 1. `users` addresses a fleet, like its siblings -------------------------
{
    # Bounded by the NEXT verb, not by the next closing brace. A sabotage that
    # collapsed this to a one-line pass-through made the loose version run on
    # into the `acl` block - which does have the addressing - so the assertions
    # passed by reading a different verb's code.
    my ($blk) = $src =~ /(elsif \( \$verb eq 'users' \).*?)(?=elsif \( \$verb eq )/s;
    ok( $blk, 'the users verb is present' );
    like( $blk, qr/extract_site_targets/,
        'users resolves --domain/--all like check, acl and repair' );
    like( $blk, qr/run_tool_per_site/,
        'and runs the tool once per site when it does' );
    like( $blk, qr/run_tool\(/,
        'while a plain invocation still passes straight through' );
}

# The usage has to SAY so, or the capability exists and nobody finds it - which
# is SM624's whole finding, filed the same day.
like( $src, qr/users \[args\.\.\.\].*?--domain NAME or --all/s,
    'the usage advertises the fleet addressing' );
like( $src, qr/group-set/,
    'with the capability decision as the worked example, since that is what '
        . 'arrives fleet-wide' );

# --- 2. the tally separates a decision from a defect -------------------------
{
    my ($fn) = $src =~ /(sub cmd_repair.*?\n\})/s;
    ok( $fn, 'cmd_repair is present' );

    like( $fn, qr/\@decide/, 'there is a bucket for "awaiting your decision"' );
    # The source carries the ESCAPED form (\[ FAIL \]) because it is a Perl
    # regex literal; matching the unescaped text finds nothing. index() rather
    # than a regex about a regex.
    # On the LINE that does the splitting, not merely somewhere in the sub:
    # "FAIL" appears in cmd_repair several times, so a bare occurrence check
    # passed even when the split was removed and every warning counted as a
    # failure again.
    like( $fn, qr/my \@fails = grep \{[^}]*FAIL[^}]*\} \@left;/,
        'failures are separated from @left by the doctor\'s own marker, not by '
            . 'matching the capability sentence, which would rot when it changes' );
    unlike( $fn, qr/have not decided on capabilities/,
        'the bucketing does not depend on that sentence\'s exact wording' );
    like( $fn, qr/awaiting your decision/, 'the summary names the bucket' );

    # The exit code is the part a scheduled run acts on.
    like( $fn, qr/exit\(\s*\@stuck \? 1 : 0\s*\)/,
        'exit status follows FAILURES only - a standing decision is not an '
            . 'incident, and a check that cries wolf every run is unread' );
    unlike( $fn, qr/exit\(\s*\(?\s*\@stuck \|\| \@decide/,
        'a pending decision does not make the run red' );
}

# --- 3. the printf has an argument for every field --------------------------
# The first version of this change added a fourth %d and left three arguments,
# so the new bucket printed as 0 on every run - a tally that had just been
# fixed, reporting a wrong number in the field it was fixed to add.
{
    my ($line) = $src =~ /(printf "\\n%d clean.*?;)/s;
    ok( $line, 'the summary line is present' );
    my $specs = () = $line =~ /%d/g;
    my $args  = () = $line =~ /scalar \@\w+/g;
    is( $args, $specs, "every %d has an argument ($specs specifiers, $args args)" )
        or diag($line);
}

done_testing();
