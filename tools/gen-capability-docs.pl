#!/usr/bin/perl
# gen-capability-docs.pl - generate the human-facing capability docs from the
# same Lazysite::Capabilities builder the describe_capabilities endpoint uses,
# so the docs and the live map cannot disagree (SM126 B).
#
#   perl tools/gen-capability-docs.pl map        > docs/reference/capability-map.md
#   perl tools/gen-capability-docs.pl quickstarts > docs/reference/quickstarts.md
#   perl tools/gen-capability-docs.pl actions     > docs/reference/control-api-actions.md
#
# t/tools/26-capability-docs.t fails if a committed doc differs from this output.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

BEGIN {
    my $root = dirname( dirname( abs_path($0) ) );
    unshift @INC, "$root/lib";
}
use Lazysite::Capabilities qw(describe channel_keys action_keys);
use Lazysite::ControlApi::Actions ();    # SM350

my $what = shift @ARGV // '';
my $map  = describe();   # static model, no caller grant

if    ( $what eq 'map' )         { print render_map($map) }
elsif ( $what eq 'quickstarts' ) { print render_quickstarts($map) }
elsif ( $what eq 'actions' )     { print render_actions() }
else { die "usage: gen-capability-docs.pl map|quickstarts|actions\n" }

sub gen_note {
    return "**Generated file - do not edit by hand.** Produced by "
        . "`tools/gen-capability-docs.pl` from `lib/Lazysite/Capabilities.pm`, the "
        . "same builder behind the `describe_capabilities` endpoint. An agent with "
        . "a session should call that endpoint (it also reports what THIS account "
        . "holds); this doc is the static model for humans and un-authenticated "
        . "readers.\n";
}

sub render_map {
    my ($m) = @_;
    my @o;
    push @o, "---\n";
    push @o, "title: \"lazysite - capability map\"\n";
    push @o, "subtitle: \"What a connected partner may do, and how\"\n";
    push @o, "brand: plain\n";
    push @o, "standard-margins: true\n";
    push @o, "---\n\n";
    push @o, gen_note();

    push @o, "\n## Channels\n\n";
    push @o, "A capability is a channel (where you operate) crossed with an action "
        . "(what you may do). All four channels are enforced.\n\n";
    for my $c ( channel_keys() ) {
        push @o, "$c\n: $m->{channels}{$c}{note}\n\n";
    }

    push @o, "## Capabilities\n\n";
    push @o, "```datatable\n";
    push @o, "columns: Capability | What it lets you do | Where\n";
    push @o, "widths: 4.6cm | X | 5cm\n";
    push @o, "bold: 1\n";
    push @o, "tone: medium\n";
    push @o, "text: 2\n";
    push @o, "---\n";
    for my $a ( action_keys() ) {
        my $cap = $m->{capabilities}{$a};
        my $where = join( '; ', map {
            my $ch = $_;
            "$ch: " . join( ', ', @{ $cap->{unlocks}{$ch} } )
        } grep { $cap->{unlocks}{$_} } channel_keys() );
        $where = '-' unless length $where;
        push @o, "$a | $cap->{title} | $where\n";
    }
    push @o, "```\n\n";

    push @o, "## Engine-owned paths (do not write)\n\n";
    push @o, "These are protected - the WebDAV endpoint refuses them. Use the API "
        . "or MCP tools rather than trying to edit the engine:\n\n";
    push @o, "- $_\n" for @{ $m->{engine_owned} };
    push @o, "\n";

    push @o, "## Getting started\n\n";
    push @o, "See [the quickstarts](quickstarts) for copy-pasteable recipes, or call "
        . "the `describe_capabilities` MCP tool / `describe-capabilities` control-API "
        . "action to get this map plus your own grant in one response.\n";

    return join '', @o;
}

sub render_quickstarts {
    my ($m) = @_;
    my @o;
    push @o, "---\n";
    push @o, "title: \"lazysite - agent quickstarts\"\n";
    push @o, "subtitle: \"The sanctioned path for common jobs\"\n";
    push @o, "brand: plain\n";
    push @o, "standard-margins: true\n";
    push @o, "---\n\n";
    push @o, gen_note();

    push @o, "\nEach recipe uses the supported surfaces (WebDAV / control API / MCP) "
        . "- never editing the engine directly. The capability each needs is listed; "
        . "if a step is refused, call `describe_capabilities` to see what your account "
        . "holds.\n\n";

    for my $t ( @{ $m->{tasks} } ) {
        push @o, "## $t->{title}\n\n";
        push @o, "Requires: " . join( ', ', map { "`$_`" } @{ $t->{requires} } ) . "\n\n";
        my $n = 1;
        for my $step ( @{ $t->{steps} } ) {
            push @o, ( $n++ ) . ". $step\n";
        }
        push @o, "\n";
    }
    return join '', @o;
}

# SM350: the control API's action reference. MCP publishes tools/list with a
# schema per tool; this is the same thing for the other enforced channel, which
# had no equivalent and no documentation page at all.
#
# Generated from Lazysite::ControlApi::Actions, which t/lint/58 re-extracts from
# the dispatch chain - so this page cannot drift from the code by more than the
# lint allows, which is nothing.
sub render_actions {
    my %A = %Lazysite::ControlApi::Actions::ACTION;
    my @o;
    push @o, "---\n";
    push @o, "title: \"lazysite - control API actions\"\n";
    push @o, "subtitle: \"Every action the control API dispatches, what it "
        . "requires, and what it takes\"\n";
    push @o, "brand: plain\n";
    push @o, "standard-margins: true\n";
    push @o, "---\n\n";
    push @o, "**Generated file - do not edit by hand.** Produced by "
        . "`tools/gen-capability-docs.pl actions` from "
        . "`lib/Lazysite/ControlApi/Actions.pm`, which "
        . "`t/lint/58-action-reference-matches-the-dispatch.t` re-extracts from "
        . "the dispatcher in `lazysite-manager-api.pl` and fails on any "
        . "difference.\n\n";
    push @o, "An authenticated caller should ask `action=actions-list` instead: "
        . "it returns this same table already narrowed to what that account may "
        . "call. This page is the static model, for humans and for readers with "
        . "no credential.\n\n";

    push @o, "## Reading the capability column\n\n";
    push @o, "any of the listed\n: hold any ONE of them and the action is "
        . "available.\n\n";
    push @o, "any authenticated\n: introspection - no particular grant needed.\n\n";
    push @o, "cookie only\n: **not reachable with a token.** The manager UI "
        . "calls it and an agent cannot. This is the state a caller can discover "
        . "no other way, and the reason a refusal here is a boundary rather than "
        . "a missing grant.\n\n";

    push @o, "## Reading the parameters column\n\n";
    push @o, "`query`\n: read from the query string.\n\n";
    push @o, "`body`\n: read from the JSON request body.\n\n";
    push @o, "`query_or_body`\n: the action accepts either. Several read the "
        . "query string and fall back to the body, so a caller sending only one "
        . "of them still works.\n\n";
    push @o, "A blank cell means the dispatcher reads no parameter of its own "
        . "for that action. Where a branch hands the request to a helper that "
        . "reads one internally, neither the table nor the lint can see it - so "
        . "this page is accurate about what it lists rather than exhaustive per "
        . "action.\n\n";

    push @o, "## The actions\n\n";
    push @o, "```datatable\n";
    push @o, "columns: Action | Requires | Parameters\n";
    push @o, "widths: 5.4cm | 4.8cm | X\n";
    push @o, "bold: 1\n";
    push @o, "tone: medium\n";
    push @o, "---\n";
    for my $name ( sort keys %A ) {
        my $spec = $A{$name};
        my $req
            = !defined $spec->{caps} ? 'cookie only'
            : !@{ $spec->{caps} }    ? 'any authenticated'
            :   join( ' / ', @{ $spec->{caps} } );
        my $params = join ', ',
            map { "$_->{name} ($_->{in})" } @{ $spec->{params} };
        push @o, "`$name` | $req | " . ( length $params ? $params : ' ' ) . "\n";
    }
    push @o, "---\n";
    push @o, "```\n";
    return join '', @o;
}
