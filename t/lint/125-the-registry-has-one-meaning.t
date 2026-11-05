#!/usr/bin/perl
# SM222 L0: the two readers of the unit registry agree.
#
# `extensions:` in lazysite.conf is the registry. It has TWO readers by necessity,
# not by accident: Lazysite::Manager::Plugins::_enabled_map for the manager tree,
# and a marked copy in lazysite-processor.pl for the render path, which is
# deliberately module-free under ADR 0001 and cannot call the first one.
#
# ADR 0001 sets the convention for a copy like this - it is allowed, it is
# marked, and it is pinned by something that fails when the copies drift. That
# pin is this file. Without it the render path could quietly start disagreeing
# with the manager about which units are on, which is SM666's failure and
# SEC-2026-07 F3's: one flag reaching one reader and not another.
#
# ASSERTED BY RUNNING BOTH READERS ON THE SAME CONF, never by comparing their
# source. A textual pin passes whenever somebody edits both copies wrongly in the
# same way, and fails whenever somebody reformats one harmlessly. What matters is
# whether they return the same answer, so that is what is measured - including on
# the shapes where a hand-rolled list parser is most likely to differ.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

my $docroot = site_tempdir();
setup_minimal_site($docroot);
load_processor($docroot);

eval { require Lazysite::Manager::Plugins; 1 }
    or plan skip_all => "cannot load Lazysite::Manager::Plugins: $@";

my $conf = "$docroot/lazysite/lazysite.conf";

# The shapes a list parser gets wrong. Each is a conf body plus the entries that
# must be considered enabled in it.
my @CASES = (
    [ 'a plain list',
      "extensions:\n  - extensions/stats.pl\n  - extensions/data.pl\n",
      [ 'extensions/stats.pl', 'extensions/data.pl' ] ],

    [ 'trailing whitespace on an entry',
      "extensions:\n  - extensions/stats.pl   \n",
      ['extensions/stats.pl'] ],

    [ 'a key after the list ends the list',
      "extensions:\n  - extensions/stats.pl\nsite_name: After\n",
      ['extensions/stats.pl'] ],

    [ 'a key BEFORE the list does not join it',
      "site_name: Before\nextensions:\n  - extensions/data.pl\n",
      ['extensions/data.pl'] ],

    [ 'an empty list enables nothing',
      "extensions:\nsite_name: Empty\n",
      [] ],

    [ 'no plugins key at all enables nothing',
      "site_name: None\n",
      [] ],

    [ 'deeper indentation is still an entry',
      "extensions:\n    - extensions/stats.pl\n",
      ['extensions/stats.pl'] ],

    [ 'the key, a key after it',
      "extensions:\n  - extensions/data.pl\nsite_name: After\n",
      ['extensions/data.pl'] ],

    # SM1142 (R3): `extensions:` is the one name. The upgrade rewrites the old
    # one, and after it BOTH readers must stop reading it together - a reader
    # that kept the old spelling would put a unit in its list and out of the
    # other's, which is exactly what this file is for.
    # old-name: begin (SM1142, the readers are shown to refuse it)
    [ 'the old header opens nothing',
      "plugins:\n  - extensions/stats.pl\n",
      [] ],

    [ 'beside the one name, the old header adds nothing',
      "extensions:\n  - extensions/data.pl\nplugins:\n  - extensions/stats.pl\n",
      ['extensions/data.pl'] ],
    # old-name: end
);

# Every entry either case mentions, so we test the NEGATIVE answers too - a
# reader that returned true for everything would pass a positives-only check.
my @UNIVERSE = qw(extensions/stats.pl extensions/data.pl extensions/briefs.pl);

for my $c (@CASES) {
    my ( $name, $body, $on ) = @$c;
    open my $fh, '>:utf8', $conf or die $!;
    print $fh $body;
    close $fh;

    my %expect = map { $_ => 1 } @$on;

    main::_reset_units();
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;

    my ( @proc, @mgr, @want );
    for my $e (@UNIVERSE) {
        push @want, "$e=" . ( $expect{$e}       ? 1 : 0 );
        push @proc, "$e=" . ( main::_unit_enabled($e) ? 1 : 0 );
        push @mgr,
            "$e=" . ( Lazysite::Manager::Plugins::plugin_enabled($e) ? 1 : 0 );
    }

    is( "@proc", "@want", "render path reads '$name' correctly" );
    is( "@mgr",  "@want", "manager tree reads '$name' correctly" );
    is( "@proc", "@mgr",  "...and the two readers agree on '$name'" );
}

done_testing();
