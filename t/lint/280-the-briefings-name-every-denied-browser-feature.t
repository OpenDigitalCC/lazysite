#!/usr/bin/perl
# SM1267 (SM710's "also worth doing", P-7): the authoring and layouts briefings,
# and the front matter reference, name every browser feature Permissions-Policy
# denies, and say how a page asks for one.
#
# Before: the briefings said nothing about the denied list, so an author could
# ship a microphone or location feature that could not work and get no warning
# until a visitor reported it (SM710). Pinned against the module's own list, so
# a feature added to @DENIED_FEATURES without a word in the docs fails here.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(repo_root);
use Lazysite::SecurityHeaders ();

my $root = repo_root();
sub slurp { my ($p) = @_; open my $fh, '<:utf8', "$root/$p" or die "$p: $!"; local $/; return scalar <$fh> }

my @denied = @Lazysite::SecurityHeaders::DENIED_FEATURES;
cmp_ok( scalar @denied, '>=', 10, 'the denied list was read' );

for my $doc (qw(starter/docs/ai-briefing-authoring.md starter/docs/ai-briefing-layouts.md)) {
    my $text = slurp($doc);
    subtest $doc => sub {
        my @missing = grep { $text !~ /`\Q$_\E`/ } @denied;
        is_deeply( \@missing, [], 'names every denied feature' )
            or diag("Not named: @missing - an author reading this cannot tell those are denied.");
        like( $text, qr/Permissions-Policy/,      'says which header denies them' );
        like( $text, qr/`<feature>: self`/,       'says how a page asks for one' );
        like( $text, qr/https only|over https/i,  'and that it holds over https only' );
    };
}

subtest 'the front matter reference names every feature a page may ask for' => sub {
    my $text    = slurp('starter/docs/frontmatter.md');
    my @missing = grep { $text !~ /`\Q$_\E`/ } @Lazysite::SecurityHeaders::PAGE_FEATURES;
    is_deeply( \@missing, [], 'every feature' ) or diag("Not named: @missing");
    like( $text, qr/`geolocation: self`/, 'with the page key spelled out' );
};

done_testing;
