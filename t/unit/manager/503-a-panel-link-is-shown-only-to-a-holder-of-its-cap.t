#!/usr/bin/perl
# SM1369 X6, H-8 (ruling 194, C-38): AN EXTENSION'S CARD LINKS ITS PAGE ONLY FOR A
# CALLER WHO HOLDS THE PAGE'S CAPABILITY.
#
# The extension listing is cached and knows no caller, so the extension-config
# page filters at render: it asks whoami for the caller's capabilities before it
# draws the cards, and extensionPanels links a declared page only when the
# caller holds its `cap`. The page itself still refuses anyone else with 403
# (t/unit/extensions/92). Run here in node, with the page's own function:
#
#   * with the capability: the link, at /manager/<id>-<name>, with its label;
#   * without it, or before whoami has answered, or when whoami failed: none;
#   * the page asks whoami before it renders the cards.
#
# Sabotage: drop the `held[p.cap]` test from extensionPanels and the caller
# without the capability is shown the link - this fails.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript qw(page_source extract_function);

my $src = page_source( repo_root() . '/starter/manager/extension-config.md' );
my $fn  = extract_function( $src, 'extensionPanels', 'the extension-config page' );

my ($load) = $src =~ /(function loadExtensions\(\) \{.*?\n\})/s;
ok( defined $load, 'the page has loadExtensions' );
like( $load // '', qr/action=whoami.*_callerCaps.*Promise\.all/s, 'which asks whoami for the caller\'s capabilities before it renders' );

SKIP: {
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    skip 'node not installed', 5 unless length $node && -x $node;
    my $dir = tempdir( CLEANUP => 1 );
    my $ext = '{ id: "probe", owns: { hooks: { panels: [ { page: "board.md", label: "Probe board", cap: "probe_cap" } ] } } }';
    my $run = sub {
        my ($caps) = @_;
        open my $js, '>', "$dir/p.js" or die $!;
        print {$js} "var window = {};\n" . ( defined $caps ? "window._callerCaps = $caps;\n" : '' )
            . "$fn\nconsole.log(JSON.stringify(extensionPanels($ext)));\n";
        close $js;
        return decode_json(`\Q$node\E \Q$dir/p.js\E 2>&1`);
    };
    is_deeply( $run->('{ probe_cap: 1, ui: 1 }'), [ { href => '/manager/probe-board', label => 'Probe board' } ],
        'a holder of the capability is linked the page' );
    is_deeply( $run->('{ ui: 1, manage_users: 1 }'), [], 'a manager without it is not' );
    is_deeply( $run->('{ probe_cap: 0, ui: 1 }'), [], 'a capability held off is not held' );
    is_deeply( $run->('{}'), [], 'whoami answered nothing (it failed): no link' );
    is_deeply( $run->(undef), [], 'before whoami has answered: no link' );
}

done_testing;
