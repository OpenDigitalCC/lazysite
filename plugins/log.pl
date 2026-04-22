#!/usr/bin/perl
# lazysite-log.pl - Logging configuration plugin for lazysite manager

use strict;
use warnings;

if ( grep { $_ eq '--describe' } @ARGV ) {
    use JSON::PP;
    print encode_json({
        id          => 'logging',
        name        => 'Logging',
        description => 'Log level and format for all lazysite components',
        version     => '1.0',
        config_file => 'lazysite/lazysite.conf',
        config_keys => ['log_level', 'log_format'],
        config_schema => [
            {
                key     => 'log_level',
                label   => 'Log level',
                type    => 'select',
                options => ['ERROR', 'WARN', 'INFO', 'DEBUG'],
                default => 'INFO',
            },
            {
                key     => 'log_format',
                label   => 'Log format',
                type    => 'select',
                options => ['text', 'json'],
                default => 'text',
            },
        ],
        actions => [],
    });
    exit 0;
}

print "Usage: plugins/log.pl --describe\n";
exit 1;
