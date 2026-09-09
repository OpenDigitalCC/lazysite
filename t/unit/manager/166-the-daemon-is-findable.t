#!/usr/bin/perl
# SM809, filed at the operator's request after 139E-04. The daemon WAS running
# on edge; the field recorded the ref as blocked because nothing pointed at it,
# and took nine steps to answer "is the daemon running" - one of them reading
# the manager UI's own JavaScript to learn the real contract.
#
# The information was never missing. The status output needed no interpretation
# at all: every job, its actor, its outcome and a meaningful detail. Only the
# PATH to it was missing, which is the kind of defect no test of behaviour
# catches.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root);
use Lazysite::Manager::Plugins ();

my $root = repo_root();

# The registry reads from a docroot; these assertions are about the REFUSAL
# text, which is decided before any lookup, so a scratch docroot keeps the
# module from warning about an unset global.
$Lazysite::Manager::Plugins::DOCROOT = $root;
sub src {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or die "$f: $!";
    local $/;
    return <$fh>;
}

# 1. The name shares a token with everything else it is called.
subtest 'the word everyone uses appears where a person searches' => sub {
    my $d = src('plugins/daemon.pl');
    my ($name) = $d =~ /name\s*=>\s*'([^']+)'/;
    like( $name, qr/daemon/i,
        'the plugin name contains "daemon"' )
        or diag( 'Its id is daemon, its script daemon.pl, its config '
            . 'daemon.conf, its jobs daemon-*, and every filing calls it the '
            . 'daemon. Searching the manager for that word found nothing.' );
    like( $name, qr/Persistent runtime/,
        'and still says what it is, for somebody who does not know the word' );
};

# 2. The parameter the declaration names is the one that works.
subtest 'a plugin resolves by the parameter the declaration names' => sub {
    my $decl = src('lib/Lazysite/ControlApi/Actions.pm');
    for my $a (qw(plugin-read plugin-save plugin-action)) {
        like( $decl, qr/'\Q$a\E'[^\n]*name => 'plugin'/,
            "$a declares a `plugin` parameter" );
    }

    my $p = src('lib/Lazysite/Manager/Plugins.pm');
    for my $sub (qw(action_plugin_read action_plugin_save action_plugin_action)) {
        my ($body) = $p =~ /(sub \Q$sub\E \{.*?\n\})/s;
        ok( $body, "$sub was found" ) or next;
        like( $body, qr/_resolve_plugin_or_why\(\s*\$plugin_id, \$script\s*\)/,
            "$sub resolves on EITHER, so `plugin` is no longer accepted and ignored" );
    }
};

# 3. And the refusal is about the parameter, not about the plugin.
subtest 'a missing plugin parameter is named as missing' => sub {
    my ( $full, $why ) = Lazysite::Manager::Plugins::_resolve_plugin_or_why( undef, undef );
    ok( !$full, 'nothing resolves' );
    like( $why, qr/a plugin is required/, 'the refusal names the parameter' );
    like( $why, qr/\?plugin=/,            'and the query-string spelling' );
    like( $why, qr/"script"/,             'and the body spelling' );
    like( $why, qr/plugin-list/,          'and where the ids come from' );
    unlike( $why, qr/Plugin not found/,
        'it does not say the plugin is missing when the PARAMETER was - that '
            . 'sentence sent the field looking for a plugin that was there' );

    my ( $f2, $why2 ) = Lazysite::Manager::Plugins::_resolve_plugin_or_why( 'nosuchplugin', undef );
    ok( !$f2, 'a named plugin that is not installed still fails' );
    like( $why2, qr/no plugin 'nosuchplugin' is installed/,
        'and THAT refusal is about the plugin, because that is what was wrong' );
    like( $why2, qr/plugin-list/, 'still pointing at the list' );
};

done_testing;
