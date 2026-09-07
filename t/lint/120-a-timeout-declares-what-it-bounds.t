#!/usr/bin/perl
# SM763/SM764: a ceiling on work this process waits for must say what it
# bounds, because the release gate runs the suite under Devel::Cover at four
# jobs and that makes every Perl process around a test several times slower.
#
# The 0.13.4 coverage stage failed on the pandoc plugin's 20-second render
# ceiling - met under instrumentation, never met alone. Manager::Plugins had
# already learned the rule for its --describe budget (2 s plain, 30 s under
# Devel::Cover): measurement must not alter behaviour.
#
# So every `alarm` in the engine is one of two things, and says which:
#
#   - CPU- or subprocess-bound work (a render, a --describe): the operand is
#     a variable whose assignment carries the Devel::Cover branch;
#   - network-bound work (an SMTP or XMPP peer, a git remote): a literal is
#     fine, because instrumenting this process does not slow the peer - and
#     the site says so with `# network-bound` on the alarm line or the line
#     before it.
#
# A third alarm with neither is the next 0.13.4.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;

my $root = "$FindBin::Bin/../..";
my @src;
find( { wanted => sub { push @src, $File::Find::name if /\.(pm|pl)\z/ && -f }, no_chdir => 1 },
    "$root/lib", "$root/plugins", "$root/tools" );
push @src, glob("$root/lazysite-*.pl");

my ( @sites, @bad );
for my $f ( sort @src ) {
    open my $fh, '<', $f or die "$f: $!";
    my @lines = <$fh>;
    close $fh;
    my $rel = $f =~ s{^\Q$root\E/}{}r;
    my $src = join '', @lines;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;
        next unless $l =~ /\balarm\s*\(?\s*([\$\w]+)/;
        my $arg = $1;
        next if $arg eq '0';    # disarming
        push @sites, "$rel:" . ( $i + 1 );
        my $prev = $i ? $lines[ $i - 1 ] : '';
        if ( $arg =~ /^\d+$/ ) {
            next if "$prev$l" =~ /#\s*network-bound/;
            push @bad, "$rel:" . ( $i + 1 ) . ": alarm $arg - a literal with no '# network-bound' marker";
            next;
        }
        my $var = $arg =~ s/^\$//r;
        # the variable's assignment must carry the instrumentation branch
        # somewhere in the file: `$var = ... Devel::Cover ...` or a following
        # `$var = N if ... Devel::Cover`
        next if $src =~ /\$\Q$var\E\s*=[^;]*Devel::Cover/s;
        next if $src =~ /\$\Q$var\E\s*=\s*\d+\s*\n\s*if[^;]*Devel::Cover/s;
        push @bad, "$rel:" . ( $i + 1 ) . ": alarm \$$var - no Devel::Cover branch on its assignment";
    }
}
cmp_ok( scalar @sites, '>=', 4, 'alarm sites found (' . scalar(@sites) . ')' );
is_deeply( \@bad, [], 'every timeout declares what it bounds' ) or diag join "\n", @bad;
done_testing;
