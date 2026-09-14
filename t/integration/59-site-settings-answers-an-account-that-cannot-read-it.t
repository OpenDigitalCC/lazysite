#!/usr/bin/perl
# N141-04: what Site settings ACTUALLY renders to a real account holding `ui`
# and not `manage_config`.
#
# THE REPORT. Walking tier B on 0.13.16, the site agent found that Site settings
# offers itself UNPADLOCKED to such an account - while Domains, Audit log,
# Connectors and Data tables are all correctly padlocked in the same nav - and
# then renders "the nav chrome and nothing else - document.body.innerText is 480
# characters ... No refusal, no 'you need manage_config', no empty-state." Two
# people concluded from that page that the Services panel did not exist; the
# operator's words were "there isn't such a page AFAIK".
#
# THE PADLOCK IS NOT THE FIX and this test does not ask for one. `href="/manager"`
# with the active state matching ^/manager/config means this is the manager
# LANDING PAGE - you cannot padlock where somebody lands. So an account with
# `ui` and no `manage_config` arrives here at EVERY login, and a blank page is
# indistinguishable from a broken one.
#
# WHY THIS TEST EXISTS BESIDE t/lint/141. That test asserts the sentence SM775
# added, and says plainly what it cannot settle: "The fixture has no session at
# all, so `manager_caps` is empty and `manage_config` is falsy - which takes the
# same branch as an account holding `ui` and not `manage_config`, but is not the
# same situation." It also strips `auth: manager` to render at all.
#
# This one closes that gap: a REAL account, in a group granting `ui` and not
# `manage_config`, with the page's own `auth: manager` left intact and a trusted
# session supplied - which is the arrangement the field actually reported on. If
# the page is right, this pins it against the real capability set rather than
# against an empty one. If it is wrong, this is the reproduction nobody had.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site run_processor
    add_account grant_caps env_passthrough);
use File::Path qw(make_path);

my $root = repo_root();
my $src  = "$root/starter/manager/config.md";
plan skip_all => "no $src" unless -f $src;

my $d = site_tempdir();
setup_test_site($d);

# The manager has to be switched ON, or handle_manager_path refuses the whole
# path before any capability is consulted - a 403 that looks like an access
# decision and is not one. Found the first time this test ran: it reported a
# reproduction of the field defect, and what it had actually reproduced was its
# own fixture. Appended rather than rewritten so the helper's own keys stand.
do {
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "manager: enabled\n";
};

# The manager page where a real site serves it.
make_path("$d/manager");
do {
    open my $in,  '<', $src                   or die "$src: $!";
    open my $out, '>', "$d/manager/config.md" or die $!;
    local $/;
    print {$out} <$in>;
};

# THE ACCOUNT THE REPORT IS ABOUT: it can use the manager UI, and cannot read
# the site configuration. Nothing else - no manage_users either, because the
# remedy SM807 offers branches on that and the reported account had neither.
add_account( $d, 'deskuser' );
my $group = grant_caps( $d, 'deskuser', 'ui' );
ok( $group, "the account is in a group granting ui and nothing else" );

# BOTH HEADERS, because that is what the auth wrapper supplies. _is_manager
# decides the `ui` channel from HTTP_X_REMOTE_GROUPS, not from the account's
# stored membership - lazysite-auth.pl resolves the groups once and passes them
# on. Sending only the user produced the API/MCP-account refusal ("this account
# is not permitted to use the manager interface"), which is the RIGHT answer to
# the question my fixture was actually asking and not the question this test is
# about.
my $rendered = run_processor( $d, '/manager/config',
    HTTP_X_REMOTE_USER    => 'deskuser',
    HTTP_X_REMOTE_GROUPS  => $group,
    LAZYSITE_AUTH_TRUSTED => 1,
);

ok( length $rendered, 'the page rendered' ) or do { done_testing(); exit };

# Strip the HTTP headers and tags so what is measured is what a READER sees -
# the report's own measure was document.body.innerText, not the markup.
( my $body = $rendered ) =~ s/\A.*?\r?\n\r?\n//s;
( my $text = $body )     =~ s/<script\b.*?<\/script>//gsi;
$text                    =~ s/<style\b.*?<\/style>//gsi;
$text                    =~ s/<[^>]+>/ /g;
$text                    =~ s/\s+/ /g;
$text                    =~ s/\A\s+|\s+\z//g;

# --- the reader is TOLD, rather than shown an empty page ---------------------
like( $text, qr/Site settings are read by an account holding/i,
    'the account is told why the page is empty' )
    or diag( "THE FIELD REPORT REPRODUCES. The rendered body text is "
        . length($text)
        . " characters and does not contain the refusal sentence.\n"
        . "First 400 characters:\n  "
        . substr( $text, 0, 400 ) );

like( $text, qr/Configuration/,
    'and the capability it needs is named, so it can be asked for' );

# --- the remedy suits a reader who cannot grant it themselves (SM807) --------
like( $text, qr/user manager can grant/i,
    'and is pointed at somebody who can grant it' )
    or diag( 'This account holds no manage_users, so telling it to grant the '
        . 'capability itself sends the one person who cannot fix this to fix '
        . 'it.' );

# --- the form really is withheld, so this is a refusal and not a hedge -------
unlike( $body, qr/id="site-settings"/,
    'the settings form is not rendered to a reader who cannot read it' );

# --- NO LENGTH ASSERTION, and that is deliberate -----------------------------
#
# My first version asserted the body was longer than 600 characters, turning the
# report's "480 characters" into a threshold. It failed at 347 - and the failure
# was the test's, not the product's: this fixture renders no manager nav, so 347
# characters is the refusal ALONE, where the field's 480 was chrome plus nothing.
# The two numbers count different things and comparing them proves nothing.
#
# A character count is the wrong instrument anyway. What matters is whether the
# reader is told, and the assertions above ask that directly.

# --- WHAT THIS SETTLES ---------------------------------------------------
#
# The field report does NOT reproduce. Given a real account holding `ui` and not
# `manage_config`, with the page's own `auth: manager` intact and the headers
# the auth wrapper really sends, /manager/config renders the refusal, names the
# capability, and points at somebody who can grant it.
#
# So the fault is not in this template, and t/lint/141's careful hedge - "if
# this passes and the field still sees a blank page, the fault is between the
# account's real capability set and this template" - is now narrowed further:
# it is not the capability set either, because this test supplies exactly the
# one described.
#
# WHAT IS LEFT, stated as a hypothesis and NOT as a finding: SM775 added this
# empty state in v0.13.9, and N141-05 later proved that a pooled site goes on
# running the engine its worker loaded until something restarts it - which
# nothing did before 0.14.1. A site serving pre-0.13.9 code would show exactly
# the reported page. That is consistent, it is not evidence, and the way to
# settle it is to ask the walked site what it was actually running rather than
# what it had been upgraded to.

done_testing();
