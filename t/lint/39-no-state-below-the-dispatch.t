#!/usr/bin/perl
# A file-scoped `my` declared BELOW the dispatch never runs before a request is
# served. Twice now that has shipped.
#
# These scripts execute their main body near the TOP of the file and define
# their subs below it. A `my %TABLE = (...)` written down among the subs is
# therefore initialised only AFTER the request has already been handled - so
# every sub that reads it during the request sees an empty variable. Perl says
# nothing: the declaration is in scope at compile time, and an empty hash or list
# is a perfectly ordinary value.
#
# THE TWO IT HAS ALREADY COST:
#
#   SM285  `my @PROBE_EXT = qw(png pdf txt ...)` below the main body of
#          lazysite-check.pl. The ACL self-probe looped over an EMPTY list,
#          compared `@gated == @PROBE_EXT` as 0 == 0, and reported "the front
#          end respects the ACL" against a port with nothing listening. A
#          security check that passed by testing nothing, shipped.
#
#   SM293  `my %REGISTRY_CT = (...)` below the main body of
#          lazysite-processor.pl, in the SAME FILE whose comments describe the
#          SM285 version a few hundred lines away. Every registry request 404'd
#          because no name looked known.
#
# Both were found by debugging a symptom, not by review, and the second was
# written by someone who had just read the first one's warning. That is the
# argument for a test rather than a third comment.
#
# THE FIX in both cases was the same shape: make it a SUB. A sub is initialised
# at call time and cannot be too early, so `_probe_exts()` and `_registry_ct()`
# are correct where the `my` was not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# WHICH FILES, and why the rule is "after the first sub" rather than "after the
# dispatch".
#
# The obvious anchor is the line where the main body runs, and for two scripts
# that is a single named call. For the rest the main body is a long run of
# top-level statements with no one call to point at, so an anchor per file would
# be a guess - and a guess that fails OPEN, silently, which is the property this
# test exists to remove.
#
# So the boundary is COMPUTED: the last top-level statement that actually runs
# something. Everything after it is definitions, and a file-scoped `my` with an
# initialiser down there is initialised after the request has been served.
#
# "Top-level" means brace depth zero, tracked line by line - not "starts at
# column 0", which a first attempt used and which put the boundary at the first
# sub, flagging every legitimate constant in the processor. The rule has to
# describe the file's real shape or it is noise, and noise is how a check stops
# being read.
my @SCRIPTS = qw(
    lazysite-processor.pl
    lazysite-auth.pl
    lazysite-dav.pl
    lazysite-manager-api.pl
    lazysite-mcp.pl
    lazysite-oauth.pl
    lazysite-front.pl
    lazysite-data.pl
    tools/lazysite-check.pl
);

# A shipped script that nobody listed is the same gap one level up - the shape
# t/lint/31 was extended to catch. So the list is checked for completeness
# rather than trusted.
subtest 'every shipped CGI surface is accounted for' => sub {
    my %listed  = map      { $_ => 1 } @SCRIPTS;
    my @shipped = sort map { s{\A\Q$root/\E}{}r } glob("$root/lazysite-*.pl");
    my @missing = grep     { !$listed{$_} } @shipped;
    is_deeply( \@missing, [],
        'every lazysite-*.pl at the repo root has a dispatch anchor here' )
        or diag( join "\n  ", '', @missing );
};

for my $rel (@SCRIPTS) {
    my $path = "$root/$rel";
    unless ( -f $path ) {
        fail("$rel is missing - a script was renamed without updating this test");
        next;
    }

    open my $fh, '<', $path or die "$rel: $!";
    my @lines = <$fh>;
    close $fh;

    # Walk the file at brace depth zero and remember the last statement that
    # RUNS something - not a use, not a declaration, not a sub definition. That
    # is where the main body ends.
    my $depth  = 0;
    my $in_pod = 0;
    my $last_run;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        $in_pod = 1 if $l =~ /^=\w+/;
        if ($in_pod) { $in_pod = 0 if $l =~ /^=cut/; next }

        if ( $depth == 0
            && $l !~ /^\s*(?:#|$)/
            && $l !~ /^(?:use|no|require|package|sub|our)\b/
            && $l !~ /^my\b/
            && $l =~ /\S/ )
        {
            $last_run = $i;
        }
        $depth += ( $l =~ tr/{// );
        $depth -= ( $l =~ tr/}// );
        $depth = 0 if $depth < 0;
    }
    unless ( defined $last_run ) {
        fail("$rel: found no top-level statement - has this file changed shape?");
        next;
    }

    # Everything the subs can read: file-scoped `my` or `our` with an INITIALISER.
    # Without an initialiser there is nothing to be too late for.
    my @late;
    for my $i ( $last_run + 1 .. $#lines ) {
        my $l = $lines[$i];
        # SM522: `our` is the same trap - %FRONT_MATTER_RESERVED shipped empty
        # at request time with `our` while this test only looked for `my`.
        next unless $l =~ /^(my|our) \s+ ([\$\@\%])(\w+) \s* =/x;
        my ( $decl, $sigil, $name ) = ( $1, $2, $3 );

        # Read by a sub? That is the combination that bites: state nothing reads
        # during a request is merely dead, not wrong.
        my $used_in_sub = 0;
        my $in_sub      = 0;
        my $depth       = 0;
        for my $j ( 0 .. $#lines ) {
            next if $j == $i;
            if ( !$in_sub && $lines[$j] =~ /^sub\s+\w+/ ) { $in_sub = 1; $depth = 0 }
            next unless $in_sub;
            $depth += ( $lines[$j] =~ tr/{// );
            $depth -= ( $lines[$j] =~ tr/}// );
            $used_in_sub = 1 if $lines[$j] =~ /\Q$sigil$name\E\b|\$\Q$name\E\{|\$\Q$name\E\[/;
            $in_sub      = 0 if $depth <= 0 && $lines[$j] =~ /\}/;
        }
        next unless $used_in_sub;

        # An explicit waiver, for state that genuinely is only used after the
        # dispatch has returned (lazysite-check's report formatting, say).
        next if $l =~ /##\s*no-dispatch-order/;

        push @late, sprintf( '%s:%d: %s %s%s', $rel, $i + 1, $decl, $sigil, $name );
    }

    is_deeply( \@late, [],
        "$rel: no file-scoped state is initialised below the main body" )
        or diag( join "\n  ",
        '',
        @late,
        '',
        'Each of these is EMPTY when a request is served. Make it a sub - a sub',
        'is initialised at call time and cannot be too early - or add',
        '"## no-dispatch-order" if it is genuinely read only after dispatch.' );
}

done_testing();
