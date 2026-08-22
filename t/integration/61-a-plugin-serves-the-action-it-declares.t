#!/usr/bin/perl
# SM477: every action a plugin DECLARES must be one its own run() can SERVE.
#
# THE FAULT THIS EXISTS TO CATCH, reported from the manager UI: clicking the
# data plugin's Status button returned
#
#     usage: --describe | --action status --docroot DIR
#
# The two halves of one plugin disagreed about their own contract. The manager
# invokes a declared action as `--scan` unless the action says
# `run => 'action'`; data.pl declared no such thing and implemented only
# `--action status`, so the button ran the fall-through and printed the usage
# string at an operator.
#
# WHY THIS IS A TEST AND NOT A GREP. The obvious check - does the source
# mention the action id - passes for a plugin that mentions it in a comment and
# fails for one that dispatches through a table. The only thing that settles it
# is invoking the plugin the way the MANAGER does and seeing whether it
# understood.
#
# WHAT IT ASSERTS, AND DELIBERATELY NOTHING MORE: the invocation was
# RECOGNISED. Not that it succeeded - most of these refuse against an empty
# docroot, which is correct and is the point of running them against one. A
# plugin that answers "no SMTP configured" understood the question. A plugin
# that answers "usage:" did not.
#
# THE EMPTY DOCROOT IS THE SAFETY MECHANISM. Actions here include git-sync's
# push. Against a directory with no configuration every such action refuses
# before it does anything, so this file runs them all without touching a
# remote, a repository or a live store.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @plugins = sort glob("$root/plugins/*.pl");
ok( scalar @plugins, 'there are plugins to check' ) or BAIL_OUT('no plugins found');

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

# The manager's own rule, from Lazysite::Manager::Plugins::action_plugin_action:
# `--scan` by default, `--action <id>` when the action declares run => 'action'.
# Restated here rather than imported, because a test that shares the code under
# test cannot disagree with it - and disagreement is the entire fault.
sub argv_for {
    my ($action) = @_;
    return ( ( $action->{run} // '' ) eq 'action' )
        ? ( '--action', $action->{id} )
        : ('--scan');
}

for my $script (@plugins) {
    my $name = $script;
    $name =~ s{.*/}{};

    my $json = qx($^X \Q$script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) };
    unless ( ref $desc eq 'HASH' ) {
        ok( 1, "$name does not describe itself - not a plugin" );
        next;
    }

    my @actions = @{ $desc->{actions} // [] };
    unless (@actions) {
        ok( 1, "$name declares no actions" );
        next;
    }

    for my $a (@actions) {
        next if $a->{link};    # a link is a URL, not an invocation
        my @argv = argv_for($a);
        my $args = join ' ', map { quotemeta } @argv;

        # The invocation as a SCALAR for the messages below. t/lint/40 refuses
        # a list interpolated into a double-quoted string, and it is right to:
        # the same shape in a qx() re-splits on whitespace the moment an
        # argument contains a space. Joining once, here, means the message and
        # the command cannot drift apart either.
        my $shown = join ' ', @argv;
        my $out = qx($^X \Q$script\E $args --docroot \Q$docroot\E 2>/dev/null);

        my $r = eval { decode_json( $out // '' ) };
        ok( ref $r eq 'HASH', "$name/$a->{id}: answers JSON to $shown" )
            or diag( "got: " . ( $out // '(nothing)' ) );

        my $err = ( ref $r eq 'HASH' ) ? ( $r->{error} // '' ) : '';
        unlike( $err, qr/\busage\b|\bunknown (?:option|argument|action)\b/i,
            "$name/$a->{id}: the plugin RECOGNISED how the manager invokes it" )
            or diag(
                  "The manager runs `$shown` for this action, and the plugin "
                . "did not understand it. Either declare run => 'action' so "
                . "the manager sends --action $a->{id}, or serve --scan. "
                . "This is what an operator sees when they click the button." );
    }
}

done_testing();
