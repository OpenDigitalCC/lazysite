#!/usr/bin/perl
# SM222 L0: a unit switched off in the manager does no work in a render.
#
# The finding, corrected against the source before it was built on: the access
# log DOES have a switch - `first_party` in stats.conf, default on, published by
# the stats plugin's own config schema. What it did not have was any connection
# to the switch an operator actually reaches for. Turning the stats unit OFF
# stopped the reading and left the recording running, because the reader lives in
# the manager tree and the recorder lives in lazysite-processor.pl, which is
# module-free by ADR 0001 and so consulted `plugin_enabled` at zero sites.
#
# `plugins:` in lazysite.conf was always the registry. Nothing on the render path
# read it. That is the whole of L0 here: not a new mechanism, a reader.
#
# WHAT MAKES THE RECORDER WILLING TO WRITE, stated because it is not obvious
# and an earlier draft of this file got it wrong: %ACCESS_REC is a file-scoped
# LEXICAL in lazysite-processor.pl, so a test cannot set it - an assignment to
# %main::ACCESS_REC touches a different variable entirely and does nothing.
# TestHelper::load_processor runs the processor with `do`, which executes its
# final handle_one_request(), and the outcome of that request is left in the
# lexical. That leftover is why _access_record() has something to record here.
#
# The first assertion below is the canary for it: if that state ever stops
# being there, the test reports 0 records where it expects 1 and FAILS rather
# than quietly asserting nothing. A no-output test that cannot observe output
# passes against a deleted implementation, which is the trap this whole file
# is built to avoid.
#
# Checked by removing the guard: assertion 2 fails and the other three pass.
#
# THE TEST ASSERTS NO OUTPUT, which is the point. "The action refuses" was
# already true of the manager surface and is exactly what made this invisible -
# a unit that refuses when asked and records when not asked looks healthy from
# every direction an operator can see.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

my $docroot = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($docroot);
load_processor($docroot);

my $lz   = "$docroot/lazysite";
my $conf = "$lz/lazysite.conf";

# Write the registry, then record one request outcome and report what landed.
sub record_with {
    my (%opt) = @_;
    open my $fh, '>>', $conf or die $!;
    print $fh "plugins:\n  - plugins/stats.pl\n" if $opt{unit_on};
    close $fh;

    if ( defined $opt{first_party} ) {
        open my $sf, '>', "$lz/stats.conf" or die $!;
        print $sf "first_party: $opt{first_party}\n";
        close $sf;
    }

    main::_reset_units();    # an FCGI worker re-reads; so must the test
    local $ENV{REDIRECT_URL} = '/a-page';
    main::_access_record();

    my $dir = "$lz/logs";
    opendir my $dh, $dir or return 0;
    my @f = grep {/^access-\d{8}\.jsonl$/} readdir $dh;
    closedir $dh;
    my $lines = 0;
    for my $n (@f) {
        open my $lf, '<', "$dir/$n" or next;
        $lines++ while <$lf>;
        close $lf;
    }
    return $lines;
}

# Reset the conf to a known state between cases: the registry is what we vary.
sub reset_conf {
    open my $fh, '>', $conf or die $!;
    print $fh "site_name: L0 test\n";
    close $fh;
    unlink glob "$lz/logs/access-*.jsonl";
    return;
}

# --- THE DISCRIMINATING MEASURE ---------------------------------------------
# A "nothing was written" test that can never write anything passes against any
# implementation, including a deleted one. So prove the rig can see a record
# FIRST, on the same code path, differing only in the registry.
reset_conf();
is( record_with( unit_on => 1, first_party => 'true' ), 1,
    'with the stats unit in the registry, one request writes one record' );

# --- THE FINDING ------------------------------------------------------------
reset_conf();
is( record_with( unit_on => 0, first_party => 'true' ), 0,
    'with the unit absent from the registry, the render records NOTHING'
) or diag 'the unit is off and the engine is still accumulating visitor data';

# --- THE RUNTIME AXIS still works, and is not the same switch ---------------
# first_party is "offered, but not currently recording" - SM222's runtime state,
# already built for one unit before the contract had a name for it. A site that
# set it keeps its behaviour.
reset_conf();
is( record_with( unit_on => 1, first_party => 'off' ), 0,
    'the unit is registered and first_party: off still stops the recording' );

# And the two switches are independent rather than one spelled twice.
reset_conf();
is( record_with( unit_on => 0, first_party => 'off' ), 0,
    'both off records nothing, which is the uninteresting corner' );

done_testing();
