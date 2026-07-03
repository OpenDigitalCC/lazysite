#!/usr/bin/perl
# bad-url-blocker.pl - the bad-URL auto-blocker's descriptor (SM128).
#
# The blocker recognises vulnerability-scanner probes (/wp-login.php, /.env,
# *.php on a Markdown site, ...), counts them per source IP in a rolling window,
# and blocks an IP after a threshold. Detection + counting + the block store live
# in Lazysite::BadUrl; enforcement runs in the auth wrapper (lazysite-auth.pl).
# This descriptor just exposes the settings on the Plugin Config page and marks
# the feature enabled by default. The blocked-IP list + unblock live on the Stats
# page (control-API actions bad-url-blocks / bad-url-unblock).

use strict;
use warnings;

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json(
        {
            id          => 'bad-url-blocker',
            name        => 'Bad-URL auto-blocker',
            description => 'Auto-blocks source IPs that hammer scanner/probe URLs '
                . '(/wp-login.php, /.env, *.php on a Markdown site, ...). On by '
                . 'default. Blocked IPs and unblock are on the Visitor Statistics page.',
            version     => '1.0',
            config_file => 'lazysite/lazysite.conf',
            config_keys => [qw(bad_url_block bad_url_threshold bad_url_window bad_url_extra)],
            config_schema => [
                {
                    key     => 'bad_url_block',
                    label   => 'Auto-block scanner IPs',
                    type    => 'toggle',
                    on      => 'enabled',
                    off     => 'disabled',
                    default => 'enabled',
                    note    => 'Refuse an IP after it hits too many probe URLs in the '
                        . 'window. Enforced in the auth wrapper, so it protects '
                        . 'auth-wrapped sites.',
                },
                {
                    key     => 'bad_url_threshold',
                    label   => 'Probes before block',
                    type    => 'text',
                    default => '10',
                    note    => 'Number of probe hits from one IP within the window that '
                        . 'triggers a block.',
                },
                {
                    key     => 'bad_url_window',
                    label   => 'Window (seconds)',
                    type    => 'text',
                    default => '3600',
                    note    => 'Rolling window over which probe hits are counted.',
                },
                {
                    key     => 'bad_url_extra',
                    label   => 'Extra probe paths',
                    type    => 'text',
                    default => '',
                    note    => 'Comma-separated substrings to treat as probes on top of '
                        . 'the built-ins.',
                },
            ],
        }
    );
    exit 0;
}

print "usage: bad-url-blocker.pl --describe\n";
exit 0;
