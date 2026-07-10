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

our @EXPORT_OK = qw(log_event const_eq unlink_host_copies clear_host_cache);

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

# SM110 phase 2: the host-keyed page cache. An alias host's rendered pages
# live at lazysite/cache/hosts/<host>/<rel>.html (written by the processor,
# mirroring the page's docroot-relative path). Every surface that removes or
# overwrites a page's sibling .html cache must ALSO drop the per-host copies,
# or an alias host keeps serving the stale render after an edit.
#
# unlink_host_copies($docroot, $abs_html): given the SIBLING cache path
# ($docroot/<rel>.html), unlink <rel>.html under every host slot. Returns the
# number removed. Guards against traversal in the rel path (callers pass
# operator/user-derived paths).
sub unlink_host_copies {
    my ( $docroot, $abs_html ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $abs_html;
    my $hosts = "$docroot/lazysite/cache/hosts";
    return 0 unless -d $hosts;
    ( my $rel = $abs_html ) =~ s{^\Q$docroot\E/?}{};
    return 0 unless length $rel && $rel =~ /\.html\z/;
    return 0 if index( $rel, 'lazysite/' ) == 0;                # never a slot path itself
    return 0 if $rel =~ m{(?:^|/)\.\.(?:/|$)} || $rel =~ /\0/;  # no traversal
    my $n = 0;
    opendir my $dh, $hosts or return 0;
    for my $h ( readdir $dh ) {
        next if $h =~ /^\./;
        my $copy = "$hosts/$h/$rel";
        $n++ if -f $copy && unlink $copy;
    }
    closedir $dh;
    return $n;
}

# clear_host_cache($docroot): remove the whole hosts tree. Used where a sweep
# already drops every sibling cache (clear-all, theme/layout activation, nav
# change, backup restore) - wholesale removal is the simple, always-correct
# choice there; everything regenerates on the next request per host.
sub clear_host_cache {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    my $hosts = "$docroot/lazysite/cache/hosts";
    return 0 unless -d $hosts;
    require File::Path;
    File::Path::remove_tree( $hosts, { safe => 1 } );
    return 1;
}

1;
