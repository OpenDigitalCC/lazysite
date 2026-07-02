#!/usr/bin/perl
# gen-capability-docs.pl - generate the human-facing capability docs from the
# same Lazysite::Capabilities builder the describe_capabilities endpoint uses,
# so the docs and the live map cannot disagree (SM126 B).
#
#   perl tools/gen-capability-docs.pl map        > docs/reference/capability-map.md
#   perl tools/gen-capability-docs.pl quickstarts > docs/reference/quickstarts.md
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

my $what = shift @ARGV // '';
my $map  = describe();   # static model, no caller grant

if    ( $what eq 'map' )         { print render_map($map) }
elsif ( $what eq 'quickstarts' ) { print render_quickstarts($map) }
else { die "usage: gen-capability-docs.pl map|quickstarts\n" }

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
