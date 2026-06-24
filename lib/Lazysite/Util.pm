package Lazysite::Util;

# Shared helpers for the modular lazysite scripts (auth, dav, manager-api, the
# users tool). The processor stays self-contained and does NOT use this module -
# see docs/feature-requests/SM079-modular-refactor.md.
#
# Each script sets $Lazysite::Util::COMPONENT after `use`, so log lines are
# attributed to the right component.

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(log_event const_eq);

our $COMPONENT = 'lazysite';

# Constant-time string compare for timing-safe credential/token checks.
sub const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord( substr( $a, $_, 1 ) ) ^ ord( substr( $b, $_, 1 ) )
        for 0 .. length($a) - 1;
    return $r == 0;
}

# Minimal JSON string escaper for the structured log format.
sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

# Levelled logging to STDERR (text or json), honouring LAZYSITE_LOG_LEVEL and
# LAZYSITE_LOG_FORMAT. Component comes from $COMPONENT.
sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts = POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    no warnings 'uninitialized';    # helper subs in unit tests may pass undef
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        print STDERR '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' ) . "}\n";
    }
    else {
        my $extras = join ' ', map { "$_=" . ( $extra{$_} // '' ) } keys %extra;
        my $ctx = $context // '';
        my $line = "[$ts] [$level] [$COMPONENT] [$ctx] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

1;
