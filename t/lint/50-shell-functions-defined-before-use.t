#!/usr/bin/perl
# SM324: a shell function must be defined above the first line that calls it.
#
# WHAT HAPPENED. `in_list` sat near the bottom of
# lazysite-hestia-update-all.sh, below three call sites. Bash resolves a function
# at CALL time, so those calls were `command not found` - and because that
# returns 127, the idiom
#
#     in_list "$d" "${SKIPPED[@]}" && continue
#
# never continued. The re-apply sweep has therefore been sweeping the sites it
# was written to skip: ones held back by their update channel, still on an old
# version where the private store may not exist, and ones that FAILED to upgrade.
# The script's own comment says those must be excluded because sweeping them
# "would be meaningless at best".
#
# WHY A LINT AND NOT JUST A FIX. It was latent for months and surfaced only when
# an unrelated change (the SM317 ACL probe) added the first UNCONDITIONAL caller
# - the other two live behind --reapply-acls. An operator found it on their first
# rollout of the release. That is the signature of a defect class worth
# mechanising: silent, order-dependent, and invisible until something else moves.
#
# Perl does not have this problem (subs are resolved at runtime from a package
# table), which is exactly why nobody looks for it in the shell scripts.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @scripts;
for my $dir ( "$root/installers", "$root/tools", "$root/scripts" ) {
    next unless -d $dir;
    find(
        { no_chdir => 1,
            wanted => sub { push @scripts, $_ if /\.sh\z/ && -f $_ },
        },
        $dir
    );
}
@scripts = sort @scripts;
cmp_ok( scalar @scripts, '>=', 3, 'found the shell scripts' );

for my $path (@scripts) {
    ( my $rel = $path ) =~ s{\A\Q$root/\E}{};

    open my $fh, '<', $path or do { fail("$rel: unreadable"); next };
    my @lines = <$fh>;
    close $fh;

    # Where each function is defined. Both spellings bash accepts.
    my %defined_at;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;
        $defined_at{$1} //= $i + 1
            if $l =~ /^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{/;
    }
    next unless %defined_at;

    my @early;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;

        for my $fn ( keys %defined_at ) {
            # A CALL: the name in command position. Not its own definition, and
            # not a mention inside a string or a longer word.
            next unless $l =~ /(?:\A|[;&|(]|\bthen\b|\belse\b|\bdo\b)\s*\Q$fn\E(?:\s|\z)/;
            next if $l     =~ /^\s*(?:function\s+)?\Q$fn\E\s*\(\s*\)/;
            push @early, "$rel:" . ( $i + 1 ) . ": calls $fn(), defined at line $defined_at{$fn}"
                if ( $i + 1 ) < $defined_at{$fn};
        }
    }

    is_deeply( \@early, [], "$rel: every function is defined above its callers" )
        or diag( join "\n  ",
        '',
        @early,
        '',
        'Bash resolves a function at CALL time, so this is "command not found"',
        'at runtime - which returns 127, so `f x && continue` silently does not',
        'continue. Move the definition above the first caller.' );
}

done_testing();
