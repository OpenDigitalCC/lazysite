#!/usr/bin/perl
# N141B-C: an audit row names WHAT was acted on, not just what was done.
#
# Three entries recorded an action and no subject, all from the same cause the
# reporting agent named: actions whose subject is not a file path passed no
# target, and the generic default is the request path - which for these is '/'.
#
#   * EVERY CONNECTOR ACTION recorded target='/'. connector-secret-set is the
#     sharp one: it is the row an auditor reads to answer "whose credential
#     changed", and it answered the second half only. With two connectors that
#     is a coin toss, and two calls to DIFFERENT connectors were observed
#     sharing a timestamp, so even ordering does not separate them.
#
#   * user-group-nest recorded NOTHING - target empty, detail empty. The branch
#     that fills the target looks for `group`/`username`; the UI sends `sub` and
#     `parent`. So the change that alters what a whole group of people can do
#     left a row naming an action and no subject at all. The CLI has recorded it
#     correctly since SM121, so the two surfaces disagreed about one event and
#     the blank one was the surface operators actually use.
#
#   * user-group-settings-set named the group and not the capability or its new
#     value - so the row says somebody changed a group's permissions and an
#     auditor asking WHICH has to diff the store against a backup. A refusal
#     already records why it was refused; the success recorded less than its own
#     failure, which is the wrong way round for the record that exists to answer
#     "what changed".
#
# These are SOURCE checks. Driving them needs a session, a CSRF token and a
# writable audit store, and the logic under test is a handful of branches in one
# dispatcher - t/lint/37 and t/lint/45 already read source by the same method.
# What is asserted is the shape of the branch, not the presence of a word.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $api = repo_root() . '/lazysite-manager-api.pl';
open my $fh, '<', $api or BAIL_OUT("no manager api: $!");
my $src = do { local $/; <$fh> };
close $fh;

# Comments explain the defects at length; the checks are about what RUNS.
( my $code = $src ) =~ s/^\s*#.*$//mg;

# --- connectors name the connector -------------------------------------------
my ($implicit) = $code =~ /sub _audit_implicit_target\b(.*?)\n\}/s;
ok( $implicit, 'the implicit-target resolver was found' )
    or do { done_testing(); exit };

like( $implicit, qr/\$action\s*=~\s*.\^connector-/,
    'the implicit-target resolver has a connector branch' )
    or diag( 'Without one, every connector action records the request path - '
        . "which is '/' - and the audit cannot say which connector was "
        . 'touched, including when its credential was replaced.' );

like( $implicit, qr/\bid\b/,
    'and reads the connector id, which every connector action already sends' );

# It must come back as the TARGET, not merely be looked at.
like( $implicit, qr/\^connector-.*?return\s+\$v/s,
    'and returns it' );

# --- nesting a group names both groups ---------------------------------------
like( $code, qr/\$sub\s+eq\s+'group-nest'/,
    'the users block special-cases group-nest' )
    or diag( 'The generic branch reads `group` and `username`. A nest sends '
        . '`sub` and `parent`, so without this the row has no target at all.' );

like( $code, qr/group-nest.*?\$b->\{sub\}.*?\$b->\{parent\}/s,
    'reading the two fields a nest actually sends' );

# The same spelling as the CLI (sub@parent), so an audit reader filtering on a
# target does not need to know which surface made the change.
like( $code, qr/group-nest.*?"\$s\\\@\$p"/s,
    'and records them as sub@parent, the spelling the CLI already uses' )
    or diag( 'Two spellings for one event means a filter that finds half the '
        . 'history.' );

# --- a capability change names the capability --------------------------------
like( $code, qr/\$sub\s+eq\s+'group-settings-set'/,
    'the users block special-cases group-settings-set' );

like( $code, qr/group-settings-set.*?\$b->\{key\}/s,
    'and records which key changed' )
    or diag( 'Naming the group alone leaves the auditor to diff the store '
        . 'against a backup to learn which permission moved.' );

like( $code, qr/group-settings-set.*?\$b->\{value\}/s,
    'and what it became' );

# --- a success detail must never displace a refusal reason -------------------
#
# $detail is the failure channel. Folding the success specifics in
# unconditionally would overwrite the reason a refusal was refused, trading one
# silent record for another.
like( $code, qr/\$detail\s*=\s*\$aud_extra\s+if\s+\$ok\b/,
    'the success detail is only used when the action SUCCEEDED' )
    or diag( 'Written unconditionally, this would overwrite the refusal reason '
        . 'that SM711 put there - a fix that breaks the thing it copies.' );

done_testing();
