#!/usr/bin/perl
# SM1142 S1: ONE PLACE BUILDS THE PATH TO AN EXTENSION.
#
# Eleven places found an extension's script on disk, each with its own list of
# candidates; three fell back to the package's copy, two still looked inside the
# docroot, and moving the directory meant finding all eleven by hand. They call
# Lazysite::Extensions now (locate, extensions_dir), and this refuses a twelfth:
# no code file builds a path ending in or passing through `extensions` - the
# shape "$root/extensions", '/usr/share/lazysite/extensions/x.pl',
# "$DOCROOT/../extensions" - except the resolver itself and install.pl, which
# cannot load it (SM767) and names the directory through its classification
# placeholder.
#
# What is NOT a path to the directory, and passes: a registry key at the start
# of a string ('extensions/data.pl' - that is what a conf lists), the manager
# page /manager/extensions, a comment.
#
# Sabotage: put "$DOCROOT/../extensions/x.pl" back in Lazysite::Handlers and
# this fails naming the line.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my %ALLOWED = map { $_ => 1 } qw(lib/Lazysite/Extensions.pm install.pl);

my @src;
find( { wanted => sub { push @src, $File::Find::name if /\.(?:pm|pl)\z/ && -f }, no_chdir => 1 },
    grep { -d } map { "$root/$_" } qw(lib tools extensions lazysite-processor) );
push @src, glob("$root/*.pl");

my $PATH = qr{(?:[\w\}\)\$]|\.\.)/extensions\b};
my ( @bad, $seen );
for my $f ( sort @src ) {
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    next if $rel =~ m{^(?:tmp|dist)/};
    $seen++;
    next if $ALLOWED{$rel};
    open my $fh, '<', $f or do { fail("$rel: $!"); next };
    my ( $n, $pod ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        $n++;
        $pod = 1 if $l =~ /^=[a-z]/;
        $pod = 0, next if $l =~ /^=cut/;
        next if $pod || $l =~ /^\s*#/;
        ( my $code = $l ) =~ s{/manager/extensions\b}{}g;
        $code =~ s{t/unit/extensions\b}{}g;    # the tests' own directory
        push @bad, "$rel:$n: $l" if $code =~ $PATH;
    }
    close $fh;
}
cmp_ok( $seen, '>', 50, "the code files are found ($seen)" );
is_deeply( \@bad, [], 'no code outside the resolver builds a path to the extensions directory' )
    or diag( join( '', @bad )
        . "Ask Lazysite::Extensions::locate( \$file, \@install_roots ) for a script, or\n"
        . "extensions_dir(\$root) for the directory (SM1142).\n" );

done_testing();
