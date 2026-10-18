#!/usr/bin/perl
# SM1173: `lazysite check` names each READ binding whose own caps are exactly
# 20 per caller and 200 per binding - the old manager-form default, saved into
# bindings made before reads had room for a scanner. WARN, because the operator
# may have meant it; the stored values are never changed. A read at other
# values, a write at 20/200 (the right default for a write) and a binding that
# names no caps are not named.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use OdooTest qw(oom_or_skip shop_ready bind oom_lib oom_test_lib);

BEGIN { oom_or_skip() }

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

my ($d) = shop_ready();

bind( $d, id => 'r-old',   operation => 'shop.products', modes => 'public', rate_per_visitor_hour => 20, rate_per_hour => 200 );
bind( $d, id => 'r-other', operation => 'shop.products', modes => 'public', rate_per_visitor_hour => 30, rate_per_hour => 300 );
bind( $d, id => 'r-unset', operation => 'shop.products', modes => 'public' );
bind( $d, id => 'w-old',   operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', visitor_param => 'basket_key', rate_per_visitor_hour => 20, rate_per_hour => 200 );

my $inc = join ' ', map { "-I\Q$_\E" } repo_root() . '/lib', repo_root() . '/t/lib', oom_lib(), oom_test_lib();
my $out = qx($^X $inc \Q$script\E --docroot \Q$d\E 2>&1);
sub line { my ($re) = @_; my ($l) = grep { /$re/ } split /\n/, $out; return $l // '' }

like( line(qr/binding r-old/), qr/WARN|warn/i, 'a read capped at 20/200 is a warning' );
like( line(qr/binding r-old/), qr/is a read capped at 20\/200 per hour, the old form default; clear its two Cap fields in the manager to take 2000\/20000/,
    'in the supervisor\'s words' );
is( line(qr/binding r-other/), '', 'a read at other values is silent' );
is( line(qr/binding r-unset/), '', 'a read with no caps is silent' );
is( line(qr/binding w-old/),   '', 'a write at 20/200 is silent' );

done_testing();
