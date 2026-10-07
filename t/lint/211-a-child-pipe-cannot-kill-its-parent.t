#!/usr/bin/perl
# SM959: every child process the shipped code writes to runs with SIGPIPE ignored.
#
# A child that exits before reading its input - a missing module, a compile error
# - turns the parent's next write into SIGPIPE, and the default action kills the
# parent: the form handler, the manager API, the auth CGI, with no message. Only
# the processor guarded against it. t/unit/forms/24 found it as a flake (4 runs in
# 8 under prove -j8 on main) because its stand-in mail script did not exist.
#
# The rule: a `local $SIG{PIPE}` within the three lines before every open2 or
# `'|-'` spawn. t/unit/lib/199 proves the guard does what it says.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my @files = grep { -f } map { "$root/$_" } (
    qw(install.pl lazysite-auth.pl lazysite-manager-api.pl lazysite-mcp.pl lazysite-oauth.pl
        lazysite-processor.pl lazysite-dav.pl),
    ( map { s{^\Q$root\E/}{}r } glob("$root/lib/Lazysite/*.pm"), glob("$root/lib/Lazysite/*/*.pm"),
        glob("$root/plugins/*.pl"), glob("$root/tools/*.pl") ),
);
cmp_ok( scalar @files, '>', 50, 'the shipped code was found' );

my ( @bare, $spawns );
for my $f (@files) {
    open my $fh, '<', $f or next;
    my @l = <$fh>;
    close $fh;
    for my $i ( 0 .. $#l ) {
        next if $l[$i]     =~ /^\s*#/;
        next unless $l[$i] =~ /\bopen2\(|,\s*'\|-'/;
        $spawns++;
        my $from = $i - 4 < 0 ? 0 : $i - 4;
        next if grep { /local \$SIG\{PIPE\}|\$SIG\{PIPE\}\s*=/ } @l[ $from .. $i ];
        ( my $rel = $f ) =~ s{^\Q$root\E/}{};
        push @bare, "$rel:" . ( $i + 1 );
    }
}
cmp_ok( $spawns, '>=', 10, 'the spawns were found' );
is( "@bare", '', 'every child pipe is written with SIGPIPE ignored' )
    or diag("Add `local \$SIG{PIPE} = 'IGNORE';` before the spawn, in the block that writes to it.");

done_testing();
