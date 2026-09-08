#!/usr/bin/perl
# SM766 (SM760's lesson, made a rule): a store reader never turns an
# unopenable file into an empty answer in silence.
#
# `open ... or return {}` on a file that EXISTS turned a permissions fault
# into "this account holds nothing" for the runtime and a dead process for
# Status - both read as facts about the site, both wrong, neither logged.
# The field's rule: "a store reader must never turn an unopenable file into
# an empty answer." Every read-open in the auth and daemon stores whose
# failure branch returns must route through Lazysite::Util::cannot_read,
# which WARNs (file, error, unix user) unless the file is simply absent.
#
# SM768: the connector store (lazysite/connectors/, new in 0.13.5) was not
# on this list, and the field found it the same way: has_secret: 0 for a
# secret that was merely unreadable. Its readers are covered here now, and
# they may not hide behind a -f guard either - a stat the process is not
# allowed to make is the same fault as an open it is not allowed to make,
# and `return {} unless -f` renders it as absence before the open is reached.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;

my $root = "$FindBin::Bin/../..";
my @src;
find( { wanted => sub { push @src, $File::Find::name if /\.pm\z/ && -f }, no_chdir => 1 },
    "$root/lib/Lazysite/Auth", "$root/lib/Lazysite/Daemon", "$root/lib/Lazysite/Manager/Connectors.pm" );

my ( $n, @bad ) = (0);
for my $f ( sort @src ) {
    open my $fh, '<', $f or die "$f: $!";
    my $rel = $f =~ s{^\Q$root\E/}{}r;
    my $i   = 0;
    while ( my $l = <$fh> ) {
        $i++;
        next if $l =~ /^\s*#/;
        # a read-open whose failure branch returns on the same line
        next unless $l =~ /\bopen\s*\(?\s*my\s+\$\w+\s*,\s*'<[^']*'\s*,[^;]*\bor\s+(?:return|next)\b/;
        $n++;
        next if $l =~ /cannot_read\s*\(/;
        next if $l =~ /# not a store/;  # /proc and the like: absence is the ordinary case
        push @bad, "$rel:$i: $l" =~ s/\s+$//r;
    }
    close $fh;
}
cmp_ok( $n, '>=', 8, "read-opens with a return branch found ($n)" );
is_deeply( \@bad, [], 'every one reports through cannot_read before returning empty' )
    or diag join "\n", @bad;

# the connector store: no stat guard stands in front of an open
{
    my $c = "$root/lib/Lazysite/Manager/Connectors.pm";
    open my $fh, '<', $c or die "$c: $!";
    my @guards;
    my $i = 0;
    while ( my $l = <$fh> ) {
        $i++;
        next if $l =~ /^\s*#/;
        push @guards, "Connectors.pm:$i: $l" =~ s/\s+$//r if $l =~ /\b(?:return|next)\b[^;]*\b(?:unless|if\s*!)\s*-[fe]\b/;
    }
    close $fh;
    is_deeply( \@guards, [], 'the connector store reads without a -f/-e guard (absence is the open\'s ENOENT, nothing else)' )
        or diag join "\n", @guards;
}
done_testing;
