#!/usr/bin/perl
# SM887 F1: the dev server refused to start over a module nothing loads.
#
# FOUND BY RUNNING IT, which is the only way this could have been found. A
# clean ubuntu:24.04 container, the .deb installed exactly as the packaging
# describes - and `lazysite-common` lists libwww-perl under RECOMMENDS, so an
# install with everything the engine DEPENDS on had no LWP::UserAgent. The dev
# server's preflight demanded it and stopped, printing `sudo apt-get install
# libwww-perl`: advice to fix a problem the operator does not have.
#
# LWP is used by the PROCESSOR, lazily, inside fetch_url / fetch_oembed, for
# remote includes (P-1 defers it on purpose). A page with no remote include
# never loads it, and the dev server never mentions it again after the list.
#
# THE SHAPE OF THE RULE, not the one module: a preflight that demands more than
# the code uses turns an optional feature into an install blocker, and the
# person who meets it has no way to tell which it is.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $tool = repo_root() . '/tools/lazysite-server.pl';
open my $fh, '<', $tool or BAIL_OUT("no dev server at $tool: $!");
my $src = do { local $/; <$fh> };
close $fh;

my ($block) = $src =~ /my \@required = \((.*?)\);/s;
ok( defined $block, 'the preflight list was found' )
    or do { done_testing(); exit };

my @required = ( $block =~ /\[\s*'([\w:]+)'/g );
cmp_ok( scalar @required, '>=', 3, 'and it names modules' );

for my $mod (@required) {
    # Either this file uses it, or it is a hard dependency of the processor
    # this server exists to drive. Both are legitimate; "it was in the list"
    # is not.
    my $used_here = $src =~ /\b\Q$mod\E\b(?!.*\@required)/s
        && ( () = $src =~ /\b\Q$mod\E\b/g ) > 1;
    my $engine_core = $mod =~ /^(?:Template|Text::MultiMarkdown|IO::Socket::INET|JSON::PP)$/;
    ok( $used_here || $engine_core,
        "the preflight demands '$mod' because something actually needs it" )
        or diag( "$mod is named once, in the list, and nowhere else. A "
            . 'preflight that demands more than the code uses turns an '
            . 'optional feature into an install blocker.' );
}

unlike( $block, qr/LWP::UserAgent/,
    'LWP::UserAgent is NOT demanded - the processor requires it lazily, for remote includes only' )
    or diag( 'This stopped the dev server from starting in a container that '
        . 'had everything the engine declares it depends on.' );

done_testing();
