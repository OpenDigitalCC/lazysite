#!/usr/bin/perl
# lazysite-log.pl - Logging configuration plugin for lazysite manager

use strict;
use warnings;

if ( grep { $_ eq '--describe' } @ARGV ) {
    use JSON::PP;
    print encode_json( {
            id          => 'logging',
            name        => 'Logging & forwarding',
            description => 'Log level and format for all lazysite components, plus '
                . 'optional forwarding of the audit trail and diagnostics to syslog '
                . '(for an external log collector). Forwarding is best-effort and '
                . 'never blocks the site; the on-disk logs remain the record.',
            version     => '1.1',
            # Operator/host concern, not a site-manager one: hidden from the
            # Plugin Manager. Still configured from the CLI via the lazysite.conf
            # keys below (log_level, forwarding, syslog facility).
            unlisted    => JSON::PP::true(),
            config_file => 'lazysite/lazysite.conf',
            config_keys => [ 'log_level', 'log_format', 'forward_audit',
                'forward_diagnostics', 'syslog_facility' ],
            config_schema => [
                {
                    key     => 'log_level',
                    label   => 'Log level',
                    type    => 'select',
                    options => [ 'ERROR', 'WARN', 'INFO', 'DEBUG' ],
                    default => 'INFO',
                },
                {
                    key     => 'log_format',
                    label   => 'Log format',
                    type    => 'select',
                    options => [ 'text', 'json' ],
                    default => 'text',
                },
                {
                    key     => 'forward_audit',
                    label   => 'Forward the audit trail to syslog',
                    type    => 'boolean',
                    default => 'false',
                    note    => 'Each audit entry (the pipe-format line) is also sent '
                        . 'to syslog at INFO priority, tagged "lazysite".',
                },
                {
                    # SM932: a LEVEL, not a boolean, and blank is not off - blank
                    # forwards WARN and above, which is what an install that
                    # never touches this field now does. NO `default` KEY: a
                    # pre-filled value makes the form assert a setting the
                    # operator never chose, which is the SM925 X2 trap (a
                    # descriptor's `default => '5222'` overruled the SRV record
                    # on every site whose operator left the field alone).
                    key     => 'forward_diagnostics',
                    label   => 'Forward diagnostics to syslog',
                    type    => 'select',
                    options => [ '', 'off', 'error', 'warn', 'info', 'debug', 'on' ],
                    note    => 'Application log events are also sent to syslog at '
                        . 'their mapped priority (DEBUG/INFO/WARNING/ERR). Leave '
                        . 'BLANK for the default, which forwards WARN and above. '
                        . 'A level forwards that level and above; "on" forwards '
                        . 'every level; "off" forwards nothing.',
                },
                {
                    key     => 'syslog_facility',
                    label   => 'Syslog facility',
                    type    => 'select',
                    options => [ 'daemon', 'local0', 'local1', 'local2', 'local3',
                        'local4', 'local5', 'local6', 'local7' ],
                    default => 'daemon',
                },
            ],
            actions => [],
    } );
    exit 0;
}

print "Usage: plugins/log.pl --describe\n";
exit 1;
