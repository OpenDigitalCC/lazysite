#!/usr/bin/perl
# SM929: the render path's copy of the setting READER answers the same four states
# as the module's.
#
# t/lint/205 pins the two ALGORITHMS identical by comparing their bodies. The
# readers that fetch `trusted_proxies` out of lazysite.conf cannot be pinned that
# way, because the processor reads $CONF_FILE itself and the module is given a
# directory - so this exercises both and compares the answers.
#
# WHY A READER WAS WRITTEN AT ALL rather than using resolve_site_vars: its
# `^(\w+)\h*:\h*(.+)$` requires a value AFTER the colon, so a bare
# `trusted_proxies:` line does not reach %sv and reads as ABSENT. Absent means the
# private-range default; empty means trust nothing. Two different answers from one
# spelling is exactly the drift this filing was raised about, and it would have
# been invisible: the site would quietly keep trusting the default after an
# operator cleared the field to turn the feature off.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(setup_minimal_site load_processor);
use Lazysite::Util qw(trusted_proxy_spec);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

my $lazysite_dir = "$docroot/lazysite";
my $conf         = "$lazysite_dir/lazysite.conf";

sub set_conf {
    my ($extra) = @_;
    open my $fh, '>', $conf or die "$conf: $!";
    print {$fh} "site_name: T\n$extra";
    close $fh;
    return;
}

# Each case: what the conf says, and the ONE answer both readers must give.
my @CASES = (
    [ 'the key is absent',            '',                              undef ],
    [ 'the key is present and empty', "trusted_proxies:\n",            '' ],
    [ 'a single range',               "trusted_proxies: 10.0.0.0/8\n", '10.0.0.0/8' ],
    [ 'a list, kept whole',
        "trusted_proxies: 10.0.0.0/8, 192.0.2.1\n",
        '10.0.0.0/8, 192.0.2.1'
    ],
    [ 'trailing whitespace is trimmed', "trusted_proxies: 10.0.0.0/8   \n", '10.0.0.0/8' ],
    [ 'the word none',                  "trusted_proxies: none\n",          'none' ],
);

for my $c (@CASES) {
    my ( $what, $extra, $want ) = @{$c};
    set_conf($extra);

    my $from_module    = trusted_proxy_spec($lazysite_dir);
    my $from_processor = main::_trusted_proxy_spec();

    is( $from_module,    $want,        "module: $what" );
    is( $from_processor, $want,        "processor: $what" );
    is( $from_processor, $from_module, "AND THEY AGREE: $what" );
}

# BOTH READERS REPORT FAITHFULLY - absent is undef, empty is '' - and the PARSER
# then treats those two alike on purpose (an empty field is what pressing Save on
# the Config page writes). The reader keeps the distinction rather than flattening
# it, so the decision lives in one place and can be read there instead of being
# buried in a reader that could not tell the difference.
set_conf('');
my $absent = main::_trusted_proxy_spec();
set_conf("trusted_proxies:\n");
my $empty = main::_trusted_proxy_spec();
ok( !defined $absent,                 'an absent key reads as undef' );
ok( defined $empty && !length $empty, 'and an empty one as the empty string' );

my ($set_absent) = main::_parse_trusted_proxies($absent);
my ($set_empty)  = main::_parse_trusted_proxies($empty);
is_deeply( $set_empty, $set_absent,
    'and the parser gives both the private-range default, so Save changes nothing' );
my ($set_none) = main::_parse_trusted_proxies('none');
is_deeply( $set_none, [], q{while `none` is the one spelling that turns it off} );

done_testing();
