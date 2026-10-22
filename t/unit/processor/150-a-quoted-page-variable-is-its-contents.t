#!/usr/bin/perl
# SM1254: A QUOTED tt_page_var VALUE IS ITS CONTENTS.
#
# A top-level front-matter key has its one matched pair of quotes taken off
# (_front_matter_scalars); a `tt_page_var:` entry kept them. So
# `hero_cards: "a,b,c"` reached the layout as `"a,b,c"`, and a layout splitting
# it on commas got `"a` as the first item (lazysite.io /hero-preview,
# 2026-10-22, K-3). Read directly and through a render with a layout.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site setup_test_site run_processor site_tempdir);

my $s = site_tempdir();
setup_minimal_site($s);
load_processor($s);

sub var_of {
    my ( $line, $key ) = @_;
    my ($meta) = main::parse_yaml_front_matter("---\ntitle: T\ntt_page_var:\n  $line\n---\nBody.\n");
    return $meta->{tt_page_var}{$key};
}

is( var_of( 'hero_cards: "a,b,c"', 'hero_cards' ), 'a,b,c', 'a double-quoted value loses its quotes' );
is( var_of( q{greeting: 'Hello there'}, 'greeting' ), 'Hello there', 'and a single-quoted one' );
is( var_of( 'label: "Time: 10:00"  ', 'label' ), 'Time: 10:00',
    'a quoted value with a colon, and trailing space after the quote' );
is( var_of( 'plain: a,b,c', 'plain' ), 'a,b,c', 'an unquoted value is as it was' );
is( var_of( 'inner: say "hi" now', 'inner' ), 'say "hi" now', 'quotes inside a value are kept' );
is( var_of( q{mixed: "a,b'}, 'mixed' ), q{"a,b'}, 'an unmatched pair is not a pair, and is kept' );
is( var_of( 'one: "', 'one' ), '"', 'a lone quote is a value of its own' );

# Through the render: the layout splits it, as the reporting layout did.
my $d = tempdir( CLEANUP => 1 );
setup_test_site($d);
open my $lf, '>', "$d/lazysite/layouts/test/layout.tt" or die $!;
print {$lf} '<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>'
    . 'FIRST=[[% hero_cards.split(",").0 %]] LAST=[[% hero_cards.split(",").last %]] '
    . '[% content %]</body></html>';
close $lf;
open my $pf, '>', "$d/hero.md" or die $!;
print {$pf} "---\ntitle: Hero\ntt_page_var:\n  hero_cards: \"a,b,c\"\n---\nBody.\n";
close $pf;
my $out = run_processor( $d, '/hero' );
like( $out, qr/FIRST=\[a\]/, 'the layout\'s first split item is a, not "a' );
like( $out, qr/LAST=\[c\]/,  'and its last is c, not c"' );

done_testing();
