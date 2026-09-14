#!/usr/bin/perl
# N141-04: a manager page whose reader cannot read it RENDERS a sentence saying
# so, and names the capability that would open it.
#
# WHY THIS EXISTS. The site agent reported, walking tier B on 0.13.16, that Site
# settings offers itself unpadlocked to an account without `manage_config` and
# then renders "the nav chrome and nothing else - document.body.innerText is 480
# characters ... No refusal, no 'you need manage_config', no empty-state."
#
# The code says otherwise. SM775 added exactly that empty state, server-rendered,
# and SM807 branched its remedy on whether the reader could grant the capability
# themselves - and both landed in v0.13.9, so both were present in the build
# walked. Two people also concluded from that page that the Services panel did
# not exist, which is the cost the report is really about.
#
# NOTHING IN THE SUITE TESTED THAT BRANCH, so neither account could be checked
# against evidence. t/lint/136 renders every manager page and parses its scripts
# - it proves the page is not broken, and says nothing about what it SAYS. This
# asserts the sentence.
#
# WHAT IT CANNOT SETTLE, said plainly. The fixture has no session at all, so
# `manager_caps` is empty and `manage_config` is falsy - which takes the same
# branch as an account holding `ui` and not `manage_config`, but is not the same
# situation. If this passes and the field still sees a blank page, the fault is
# between the account's real capability set and this template, not in the
# template - and that is a useful thing to have narrowed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor site_tempdir setup_test_site);

my $root = repo_root();
my $page = "$root/starter/manager/config.md";

open my $in, '<', $page or BAIL_OUT("no config.md: $!");
my $src = do { local $/; <$in> };
close $in;

# The gate is what the page SAYS, not its access rule: a manager page declares
# `auth: manager` and this fixture has no session. Same treatment as t/lint/136.
$src =~ s/^auth:.*\n//m;

my $d = site_tempdir();
setup_test_site($d);
open my $out, '>', "$d/lint141-config.md" or die $!;
print {$out} $src;
close $out;

my $rendered = run_processor( $d, '/lint141-config' );
ok( length $rendered, 'the page rendered at all' ) or do { done_testing(); exit };

# --- it says something, and the something names the capability ---------------
like( $rendered, qr/Site settings are read by an account holding/,
    'a reader without manage_config is told why the page is empty' )
    or diag( 'SM775 put this sentence here. If it is missing, an account that '
        . 'cannot use the page sees a heading and nothing - which reads as a '
        . 'BROKEN page rather than a refusal, and that is the shape that cost '
        . "this line a release at 0.13.13.\n  rendered "
        . length($rendered)
        . " bytes" );

like( $rendered, qr/Configuration/,
    'and the capability is named, so the reader knows what to ask for' );

# --- the remedy fits the reader (SM807) --------------------------------------
#
# This fixture holds no manage_users either, so the remedy must be the
# find-somebody-else form. Telling an account that IS a user manager to go and
# find a user manager sends the one person who can fix this to look for the
# person who can fix this - which is how the field put it.
like( $rendered, qr/A user manager can grant\s+it/,
    'an account that cannot grant it is told to find somebody who can' );
unlike( $rendered, qr/You can grant it on the/,
    'and is NOT told to grant it itself, which it cannot' );

# --- and the form is genuinely absent, so this is a refusal and not a hedge ---
unlike( $rendered, qr/id="site-settings"/,
    'the settings form is not rendered to a reader who cannot read it' );

done_testing();
