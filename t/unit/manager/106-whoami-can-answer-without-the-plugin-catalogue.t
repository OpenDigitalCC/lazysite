#!/usr/bin/perl
# SM671: `whoami` can answer without the plugin inventory.
#
# WHAT WAS REPORTED. `whoami` is what an agent calls to learn who it is and what
# it may do, and the field found the answer to be mostly a plugin catalogue.
# That is paid on every preflight - and a preflight per account per run is now
# standing practice for the testing agent, precisely because a brief can be
# stale (SM690).
#
# WHY OPT-OUT AND NOT OPT-IN. Omitting the array by default is the leaner answer
# and a BREAKING one: a client reading `plugins` would silently start seeing an
# empty list rather than an error, and this line is bound for a stable fleet.
# The caller who cares about the cost is the caller who will pass the flag, so
# the cost falls where the benefit does.
use strict;
use warnings;
use Test::More;
use FindBin;

my $api = "$FindBin::Bin/../../../lazysite-manager-api.pl";
plan skip_all => "no $api" unless -f $api;
my $src = do { open my $fh, '<', $api or die $!; local $/; <$fh> };

subtest 'the flag reaches the action' => sub {
    like( $src, qr/action_whoami\(\s*\$auth_user,\s*\$params\{plugins\}\s*\)/,
        'the dispatch passes the parameter' )
        or diag( 'A flag the action never receives is a flag that lies.' );
    like( $src, qr/my \( \$user, \$want_plugins \) = \@_;/,
        'and the action takes it' );
};

subtest 'only an explicit falsey value omits the catalogue' => sub {
    my ($fn) = $src =~ /(sub action_whoami \{.*?\n\})/s;
    ok( $fn, 'action_whoami was found' ) or return;

    like( $fn, qr/\\A\(\?:0\|no\|false\|off\)\\z/,
        'the spellings are explicit and closed' )
        or diag( 'A loose test would let an unrelated value silently strip a '
            . 'field a client depends on - the destructive direction for a '
            . 'default that must stay backward compatible.' );

    # THE DEFAULT MUST BE THE OLD SHAPE. This is the assertion that protects
    # every existing client, and the reason the flag is opt-out.
    like( $fn, qr/\$skip_plugins \? \(\) : \( plugins => \[/,
        'the array is present unless the caller asks otherwise' )
        or diag( 'If this inverts, every client reading `plugins` sees an '
            . 'empty list and no error - a silent break across a stable fleet.' );
};

subtest 'nothing else in the answer moved' => sub {
    my ($fn) = $src =~ /(sub action_whoami \{.*?\n\})/s;
    # The parts a preflight actually reads must be unconditional: an agent
    # checking its grant before a run needs these whatever it asked about
    # plugins.
    for my $key (qw(capabilities reachable groups scope site_capabilities)) {
        like( $fn, qr/\b\Q$key\E\s*=>/, "$key is still answered unconditionally" )
            or diag( "A preflight reads $key. Making it conditional on the "
                . 'plugin flag would trade one bloated answer for an '
                . 'incomplete one.' );
    }
};

done_testing();
