#!/usr/bin/perl
# A test that builds a shell command as a STRING and interpolates a list into it
# is one space away from lying to you.
#
# `qx($^X $tool @args)` looks like it passes @args as arguments. It does not: it
# builds one string and hands it to the shell, which re-splits it on whitespace.
# The moment any element contains a space - a header like "Host: example.test", a
# path under "My Documents", a message with two words - the command silently
# becomes a different command.
#
# WHAT MAKES IT WORSE THAN AN ORDINARY BUG is the failure signature. The tool
# receives nonsense, so it refuses everything, so EVERY assertion in the file
# fails at once. That is exactly what a completely broken feature looks like, and
# it is the most convincing wrong answer available: you go and debug the product.
#
# It cost two debugging sessions in one day:
#
#   - `lazysite acl` appeared to reject every call with "--docroot is required",
#     because the docroot argument had been re-split away;
#   - the SM293 front door appeared to route nothing to any surface, because
#     "Host: front.test" became two shell words and curl was handed a URL that
#     was not a URL. Driving the same vhost by hand answered correctly.
#
# Both times the product was fine. Neither was found by reading the harness.
#
# THE FIX is TestHelper::run_cmd, which takes a list and execs it directly - no
# shell, so nothing can re-split. A single interpolated SCALAR is left alone
# here: it is usually fine and always visible, whereas a list is neither.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files;
File::Find::find(
    { no_chdir => 1,
        wanted => sub {
            my $p = $File::Find::name;
            return unless -f $p;
            return unless $p =~ /\.(?:t|pm)\z/;
            push @files, $p;
        },
    },
    "$root/t"
);

# This file necessarily quotes the offending pattern in its own prose, and
# TestHelper documents it too. Both are exempt by name rather than by a cleverer
# regex, because a check that excludes itself accidentally is a check that can
# exclude something else accidentally.
my %EXEMPT = map { ( "$root/$_" => 1 ) }
    qw(t/lint/40-no-array-in-shell-strings.t t/lib/TestHelper.pm);

my @offenders;
for my $path ( sort @files ) {
    next if $EXEMPT{$path};
    open my $fh, '<', $path or next;
    my $n = 0;
    while ( my $line = <$fh> ) {
        $n++;
        next if $line =~ /^\s*#/;    # prose about the trap is not the trap

        # Look INSIDE the command only. A first version tested the whole line
        # and flagged `my @members = `tar tzf ...`` - where the array is the
        # ASSIGNMENT TARGET and nothing is interpolated at all. A check with
        # false positives gets waived rather than fixed, so the extraction has
        # to be honest about what it is reading.
        my @bodies;
        push @bodies, $1 while $line =~ /qx\(([^)]*)\)/g;
        push @bodies, $1 while $line =~ /qx\{([^}]*)\}/g;
        push @bodies, $1 while $line =~ /`([^`]*)`/g;
        next unless @bodies;

        # @array, @{...} and @$ref all stringify by joining on $" - a space -
        # so all three re-split the same way.
        next unless grep { /\@[\$\{]?[A-Za-z_]/ } @bodies;

        ( my $rel = $path ) =~ s{\A\Q$root/\E}{};
        push @offenders, "$rel:$n: $line";
    }
    close $fh;
}

is_deeply( \@offenders, [],
    'no test builds a shell command string with a list interpolated into it' )
    or diag( join '',
    "\n",
    @offenders,
    "\n",
    "Each of these re-splits on whitespace the moment an argument contains a\n",
    "space, and the symptom is that EVERY assertion in the file fails at once -\n",
    "which reads as a broken product, not a broken harness.\n",
    "Use TestHelper::run_cmd( \$^X, \$tool, \@args ) - list form, no shell.\n" );

done_testing();
