package Lazysite::Data::Schedule;

# SM1356: A SCHEDULE - WEEKLY OPENING PERIODS AND THEIR EXCEPTIONS - AND WHAT IT
# SAYS AT A GIVEN MOMENT.
#
# WHERE A SCHEDULE LIVES. A declared data table whose descriptor says
# `schedule: true` (chosen over a schedule file; the filing says why): it is
# edited through the doors every table already has - the manager's data page,
# data-row-save, save_data_row, the data endpoint - read through the same gate,
# published by the same `public:` flag, backed up and restored with the store.
# The descriptor loader gives such a table its fields (schedule_fields below);
# a row is either a weekly PERIOD (a day, an opening time, a closing time) or an
# EXCEPTION (a date or a date range: closed, or other hours that replace the
# week's for those days).
#
# TIME IS THE SITE'S. `time_zone:` in lazysite.conf names a zone from the
# host's zoneinfo (Europe/London); a name the host cannot find is UTC, and
# lazysite check says so. The arithmetic is POSIX's own mktime and localtime
# under that zone, so a change to or from summer time is the system's answer,
# not a table of ours.
#
# WHAT "NOW" COSTS. A page that shows whether the site is open now is only
# right until the next opening or closing, so state() returns `expires`: the
# next change of state, or the next local midnight (when "tomorrow" becomes
# "today"), whichever is sooner. The processor caches such a page until then
# and no longer.
#
# EXCEPTIONS THAT HAVE PASSED are removed (ruling 164) by sweep_passed, which
# the daemon runs: each removal is written to the audit trail with the
# exception it removed, so the history reads back. With the audit trail off
# nothing is removed - the ruling's condition is that the log keeps the trail.
# A passed exception changes nothing a visitor sees either way: state() reads
# from today on.

use strict;
use warnings;
use POSIX           ();
use Time::Local     ();
use JSON::PP        ();
use Lazysite::Util  ();
use Lazysite::Paths ();

our @DAYS = qw(mon tue wed thu fri sat sun);
my %DAY_NAME = (
    mon => 'Monday', tue => 'Tuesday',  wed => 'Wednesday', thu => 'Thursday',
    fri => 'Friday', sat => 'Saturday', sun => 'Sunday',
);
my @MONTH = qw(January February March April May June July August September
    October November December);

# How far ahead "opens at" looks. Two weeks covers a closure over a holiday
# fortnight; past that the label is "Closed" and the next exception says why.
our $LOOKAHEAD_DAYS = 14;

# --- the table's shape ---------------------------------------------------------

# The fields a `schedule: true` table has. The engine's, so every schedule reads
# the same way and no layout has to learn a site's own spelling. A descriptor may
# declare more fields beside them; it may not redeclare these.
sub schedule_fields {
    return {
        kind       => { type => 'enum', values => [qw(period exception)], required => 1 },
        day        => { type => 'enum', values => [@DAYS] },
        opens      => { type => 'text', max    => 5 },
        closes     => { type => 'text', max    => 5 },
        date_from  => { type => 'date' },
        date_until => { type => 'date' },
        closed     => { type => 'boolean', default => 0 },
        note       => { type => 'text',    max     => 200 },
    };
}

# 'HH:MM' -> minutes since midnight, or undef. 24:00 is a closing time.
sub _minutes {
    my ($t) = @_;
    return undef unless defined $t && !ref $t;
    return 24 * 60 if $t eq '24:00';
    return undef unless $t =~ /\A([01]\d|2[0-3]):([0-5]\d)\z/;
    return $1 * 60 + $2;
}

# Is this row a schedule row the engine can read? Returns a refusal sentence, or
# undef. $partial is an update: only the fields it carries are checked, because
# the rest of the row is the stored one.
sub row_refusal {
    my ( $values, $partial ) = @_;
    return undef unless ref $values eq 'HASH';
    for my $f (qw(opens closes)) {
        next unless defined $values->{$f} && length $values->{$f};
        return "$f '$values->{$f}' is not a time (HH:MM, 00:00 to 24:00)"
            unless defined _minutes( $values->{$f} );
    }
    return "opens cannot be 24:00 - a day's last opening is 23:59"
        if ( $values->{opens} // '' ) eq '24:00';
    if ( length( $values->{date_from} // '' )
        && length( $values->{date_until} // '' )
        && $values->{date_until} lt $values->{date_from} )
    {
        return "date_until ($values->{date_until}) is before date_from ($values->{date_from})";
    }
    return undef if $partial;
    my $kind = $values->{kind} // '';
    if ( $kind eq 'period' ) {
        for my $f (qw(day opens closes)) {
            return "a period needs $f"
                unless length( $values->{$f} // '' );
        }
    }
    elsif ( $kind eq 'exception' ) {
        return 'an exception needs date_from' unless length( $values->{date_from} // '' );
        return 'an exception is either closed or has other hours: give opens and closes, or closed: true'
            unless $values->{closed}
            || ( length( $values->{opens} // '' ) && length( $values->{closes} // '' ) );
    }
    return undef;
}

# --- the site's time zone --------------------------------------------------------

# A zone name the host can use, or undef. Shaped like a zoneinfo name and present
# under the host's zoneinfo, so a conf value never names a file outside it.
sub valid_zone {
    my ($tz) = @_;
    return undef unless defined $tz && !ref $tz;
    $tz =~ s/\A\s+|\s+\z//g;
    return 'UTC' if $tz eq 'UTC' || $tz eq 'Etc/UTC';
    return undef unless $tz =~ m{\A[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+){0,2}\z};
    my $dir = $ENV{TZDIR} && -d $ENV{TZDIR} ? $ENV{TZDIR} : '/usr/share/zoneinfo';
    return -f "$dir/$tz" ? $tz : undef;
}

# The site's zone from its lazysite.conf, and whether the name was usable:
# ( zone, '' ) or ( 'UTC', 'the reason' ).
sub site_zone {
    my ($docroot) = @_;
    my $conf      = Lazysite::Paths::lazysite_dir($docroot) . '/lazysite.conf';
    my $text      = '';
    if ( open my $fh, '<:utf8', $conf ) { local $/; $text = <$fh>; close $fh }
    my $raw = Lazysite::Util::conf_text_value( $text, 'time_zone' );
    return ( 'UTC', '' ) unless defined $raw && length $raw;
    my $tz = valid_zone($raw);
    return ( $tz,   '' ) if defined $tz;
    return ( 'UTC', "time_zone '$raw' is not a zone this host knows - using UTC" );
}

# Run $code with the process's zone set to $tz, then put it back.
sub _in_zone {
    my ( $tz, $code ) = @_;
    my $had = exists $ENV{TZ};
    my $old = $ENV{TZ};
    $ENV{TZ} = $tz;
    POSIX::tzset();
    my @r   = eval { $code->() };
    my $err = $@;
    if ($had) { $ENV{TZ} = $old }
    else      { delete $ENV{TZ} }
    POSIX::tzset();
    die $err if $err;
    return wantarray ? @r : $r[0];
}

# --- calendar arithmetic (no zone: a date is a date) ----------------------------

sub _ymd_epoch {    # noon UTC of a YYYY-MM-DD, for stepping days
    my ($ymd) = @_;
    my ( $y, $m, $d ) = $ymd =~ /\A(\d{4})-(\d{2})-(\d{2})\z/ or return undef;
    return eval { Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y ) };
}

sub _add_days {
    my ( $ymd, $n ) = @_;
    my $e = _ymd_epoch($ymd);
    return undef unless defined $e;
    my @g = gmtime( $e + 86400 * $n );
    return sprintf( '%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3] );
}

sub _dow {    # 'mon'..'sun' of a YYYY-MM-DD
    my ($ymd) = @_;
    my @g = gmtime( _ymd_epoch($ymd) );
    return $DAYS[ ( $g[6] + 6 ) % 7 ];
}

sub _long_date {
    my ($ymd) = @_;
    my ( $y, $m, $d ) = split /-/, $ymd;
    return sprintf( '%s %d %s', $DAY_NAME{ _dow($ymd) }, $d, $MONTH[ $m - 1 ] );
}

# The epoch of a local wall-clock time on a date, in the zone already set.
# mktime with isdst -1 asks the zone, so a summer-time date gets summer time.
sub _local_epoch {
    my ( $ymd, $minutes ) = @_;
    my ( $y, $m, $d ) = split /-/, $ymd;
    return POSIX::mktime( 0, $minutes % 60, int( $minutes / 60 ), $d, $m - 1, $y - 1900, 0, 0, -1 );
}

sub _hhmm {
    my ($min) = @_;
    return sprintf( '%02d:%02d', int( $min / 60 ), $min % 60 );
}

# --- reading a schedule ----------------------------------------------------------

# The rows, sorted into periods (by day) and exceptions, the unreadable ones
# left out and counted.
sub _sort_rows {
    my ($rows) = @_;
    my ( %periods, @exceptions, $bad );
    for my $r ( @{ $rows || [] } ) {
        next unless ref $r eq 'HASH';
        my $kind = $r->{kind} // '';
        if ( $kind eq 'period' ) {
            my ( $o, $c ) = ( _minutes( $r->{opens} ), _minutes( $r->{closes} ) );
            my $day = $r->{day} // '';
            if ( !defined $o || !defined $c || !$DAY_NAME{$day} ) { $bad++; next }
            push @{ $periods{$day} }, { opens => $o, closes => $c };
        }
        elsif ( $kind eq 'exception' ) {
            my $from = $r->{date_from} // '';
            if ( !defined _ymd_epoch($from) ) { $bad++; next }
            my $until = length( $r->{date_until} // '' ) ? $r->{date_until} : $from;
            $until = $from unless defined _ymd_epoch($until) && $until ge $from;
            my $closed = $r->{closed} ? 1 : 0;
            my ( $o, $c ) = ( _minutes( $r->{opens} ), _minutes( $r->{closes} ) );
            if ( !$closed && ( !defined $o || !defined $c ) ) { $bad++; next }
            push @exceptions, {
                from   => $from,
                until  => $until,
                closed => $closed,
                ( $closed ? () : ( opens => $o, closes => $c ) ),
                note => ( $r->{note} // '' ),
                ( defined $r->{id} ? ( id => $r->{id} ) : () ),
            };
        }
        else { $bad++ }
    }
    for my $d ( keys %periods ) {
        $periods{$d} = [ sort { $a->{opens} <=> $b->{opens} } @{ $periods{$d} } ];
    }
    @exceptions = sort { $a->{from} cmp $b->{from} || $a->{until} cmp $b->{until} } @exceptions;
    return ( \%periods, \@exceptions, $bad // 0 );
}

# The periods that apply on one date: an exception covering it replaces the
# week's periods for that day (closed wins over other hours on the same day).
sub _day_periods {
    my ( $periods, $exceptions, $ymd ) = @_;
    my @cover = grep { $_->{from} le $ymd && $_->{until} ge $ymd } @$exceptions;
    if (@cover) {
        return ( [], 1, \@cover ) if grep { $_->{closed} } @cover;
        my @p = sort { $a->{opens} <=> $b->{opens} }
            map { { opens => $_->{opens}, closes => $_->{closes} } } @cover;
        return ( \@p, 0, \@cover );
    }
    return ( $periods->{ _dow($ymd) } || [], 0, [] );
}

sub _period_view {
    my ($p) = @_;
    return { opens => _hhmm( $p->{opens} ), closes => _hhmm( $p->{closes} ) };
}

# What the schedule says at $now. $tz must already be a valid zone.
sub state {
    my ( $rows, $tz, $now ) = @_;
    $now //= time;
    my ( $periods, $exceptions, $bad ) = _sort_rows($rows);
    return _in_zone( $tz, sub { _state( $periods, $exceptions, $tz, $now, $bad ) } );
}

sub _state {
    my ( $periods, $exceptions, $tz, $now, $bad ) = @_;
    my @lt    = localtime($now);
    my $today = sprintf( '%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3] );

    # Every opening interval from yesterday (a period running past midnight
    # into today) to the lookahead, as epochs, merged where they touch.
    my @iv;
    for my $n ( -1 .. $LOOKAHEAD_DAYS ) {
        my $ymd = _add_days( $today, $n );
        my ($ps) = _day_periods( $periods, $exceptions, $ymd );
        for my $p (@$ps) {
            my $start = _local_epoch( $ymd, $p->{opens} );
            my $end
                = $p->{closes} > $p->{opens}
                ? _local_epoch( $ymd,                 $p->{closes} )
                : _local_epoch( _add_days( $ymd, 1 ), $p->{closes} );    # past midnight
            $end = _local_epoch( _add_days( $ymd, 1 ), 0 ) if $p->{closes} == 24 * 60;
            push @iv, [ $start, $end, $ymd ] if $end > $start;
        }
    }
    @iv = sort { $a->[0] <=> $b->[0] } @iv;
    my @merged;
    for my $i (@iv) {
        if ( @merged && $i->[0] <= $merged[-1][1] ) {
            $merged[-1][1] = $i->[1] if $i->[1] > $merged[-1][1];
        }
        else { push @merged, [@$i] }
    }

    my ( $open, $changes_at, $until, $next ) = ( 0, undef, '', undef );
    for my $m (@merged) {
        if ( $m->[0] <= $now && $now < $m->[1] ) {
            ( $open, $changes_at ) = ( 1, $m->[1] );
            my @u = localtime( $m->[1] );
            $until = sprintf( '%02d:%02d', $u[2], $u[1] );
            last;
        }
        if ( $m->[0] > $now ) {
            $changes_at = $m->[0];
            my @s   = localtime( $m->[0] );
            my $ymd = sprintf( '%04d-%02d-%02d', $s[5] + 1900, $s[4] + 1, $s[3] );
            $next = {
                date => $ymd,
                day  => $DAY_NAME{ _dow($ymd) },
                time => sprintf( '%02d:%02d', $s[2], $s[1] ),
                when => ( $ymd eq $today ? 'today'
                    : $ymd eq _add_days( $today, 1 ) ? 'tomorrow'
                    :                                  'later' ),
            };
            last;
        }
    }

    my $label
        = $open                       ? "Open now until $until"
        : !$next                      ? 'Closed'
        : $next->{when} eq 'today'    ? "Opens at $next->{time}"
        : $next->{when} eq 'tomorrow' ? "Opens tomorrow at $next->{time}"
        :                               "Opens $next->{day} at $next->{time}";

    # The next local midnight: "tomorrow" becomes "today", the week's today moves
    # and a passed exception leaves the list. Asked of the zone, so the night the
    # clocks change is 23 or 25 hours long, as it is.
    my $midnight = _local_epoch( _add_days( $today, 1 ), 0 );
    my $expires = defined $changes_at && $changes_at < $midnight ? $changes_at : $midnight;

    my @week;
    for my $d (@DAYS) {
        my $ps = $periods->{$d} || [];
        push @week, {
            day     => $d,
            name    => $DAY_NAME{$d},
            periods => [ map { _period_view($_) } @$ps ],
            closed  => ( @$ps               ? 0 : 1 ),
            today   => ( $d eq _dow($today) ? 1 : 0 ),
        };
    }

    my ( $tps, $tclosed, $tcover ) = _day_periods( $periods, $exceptions, $today );
    my @upcoming = grep { $_->{until} ge $today } @$exceptions;
    my @exc_view = map  { _exception_view($_) } @upcoming;

    return {
        timezone => $tz,
        open     => $open,
        label    => $label,
        until    => $until,
        ( $next ? ( next_open => $next ) : () ),
        today => {
            date      => $today,
            name      => $DAY_NAME{ _dow($today) },
            periods   => [ map { _period_view($_) } @$tps ],
            closed    => ( @$tps    ? 0 : 1 ),
            exception => ( @$tcover ? 1 : 0 ),
        },
        week       => \@week,
        exceptions => \@exc_view,
        ( @exc_view ? ( next_exception => $exc_view[0] ) : () ),
        expires => $expires,
        ( $bad ? ( unreadable_rows => $bad ) : () ),
    };
}

sub _exception_view {
    my ($e) = @_;
    my $when = $e->{from} eq $e->{until}
        ? _long_date( $e->{from} )
        : _long_date( $e->{from} ) . ' to ' . _long_date( $e->{until} );
    my $hours = $e->{closed} ? '' : _hhmm( $e->{opens} ) . ' to ' . _hhmm( $e->{closes} );
    return {
        date_from  => $e->{from},
        date_until => $e->{until},
        closed     => $e->{closed},
        opens      => ( $e->{closed} ? '' : _hhmm( $e->{opens} ) ),
        closes     => ( $e->{closed} ? '' : _hhmm( $e->{closes} ) ),
        note       => $e->{note},
        label      => ( $e->{closed} ? "Closed $when" : "$when: open $hours" ),
    };
}

# schema.org OpeningHoursSpecification entries for the week and the exceptions
# still to come, for SM1357's organisation entry. Plain data; the caller encodes.
sub opening_hours_spec {
    my ( $rows, $tz, $now ) = @_;
    my ( $periods, $exceptions ) = _sort_rows($rows);
    my $today = _in_zone( $tz, sub {
            my @lt = localtime( $now // time );
            sprintf( '%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3] );
    } );
    my @spec;
    for my $d (@DAYS) {
        for my $p ( @{ $periods->{$d} || [] } ) {
            push @spec, {
                '@type'   => 'OpeningHoursSpecification',
                dayOfWeek => 'https://schema.org/' . $DAY_NAME{$d},
                opens     => _hhmm( $p->{opens} ),
                closes => ( $p->{closes} == 24 * 60 ? '23:59' : _hhmm( $p->{closes} ) ),
            };
        }
    }
    for my $e ( grep { $_->{until} ge $today } @$exceptions ) {
        push @spec, {
            '@type'      => 'OpeningHoursSpecification',
            validFrom    => $e->{from},
            validThrough => $e->{until},
            ( $e->{closed}
                ? ( opens => '00:00', closes => '00:00' )
                : ( opens => _hhmm( $e->{opens} ),
                    closes => ( $e->{closes} == 24 * 60 ? '23:59' : _hhmm( $e->{closes} ) ) ) ),
        };
    }
    return \@spec;
}

# Opening hours as lines of text, for the AI-readable summary.
sub hours_lines {
    my ( $rows, $tz, $now ) = @_;
    my $s = state ( $rows, $tz, $now );
    my @lines;
    for my $d ( @{ $s->{week} } ) {
        push @lines, $d->{closed}
            ? "$d->{name}: closed"
            : "$d->{name}: " . join( ', ', map { "$_->{opens} to $_->{closes}" } @{ $d->{periods} } );
    }
    push @lines, $_->{label} for @{ $s->{exceptions} };
    return \@lines;
}

# --- passed exceptions (ruling 164) ----------------------------------------------

# Remove every exception whose last day is before today in the site's zone, from
# every schedule table, recording each in the audit trail first with the row it
# removes (the row's fields as JSON in the line's detail field, `|` written as
# | so the line's own separator never appears in it). Returns
# { ok, removed, kept, tables, [reason] }.
#
# NOTHING IS REMOVED WITH THE AUDIT TRAIL OFF: the ruling keeps the removal on
# the condition that the trail is kept, and a removal the trail cannot hold
# would be the history the ruling asked for, lost.
sub sweep_passed {
    my ( $docroot, %opt ) = @_;
    my $actor = $opt{actor} // 'daemon';
    my $now   = $opt{now}   // time;
    require Lazysite::Data::Tables;
    require Lazysite::Audit;
    my $lz    = Lazysite::Paths::lazysite_dir($docroot);
    my ($tz)  = site_zone($docroot);
    my $today = _in_zone( $tz, sub {
            my @lt = localtime($now);
            sprintf( '%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3] );
    } );

    my @tables = grep {
        my $d = Lazysite::Data::Tables::load_table( $docroot, $_ );
        $d->{ok} && $d->{schedule};
    } @{ Lazysite::Data::Tables::list_tables($docroot) };
    my ( $removed, $kept, @named ) = ( 0, 0 );
    my $trail = Lazysite::Audit::audit_trail_state($lz);

    for my $name (@tables) {
        my $r = Lazysite::Data::Tables::read_rows( $docroot, $name, as => 'operator',
            where => { kind => 'exception' }, limit => 500 );
        next unless $r->{ok};
        my @passed = grep {
            my $last = length( $_->{date_until} // '' ) ? $_->{date_until} : ( $_->{date_from} // '' );
            length $last && $last lt $today;
        } @{ $r->{rows} || [] };
        next unless @passed;
        push @named, $name;
        if ( $trail eq 'off' ) { $kept += @passed; next }
        for my $row (@passed) {
            my $json = JSON::PP->new->canonical->encode( { table => $name, row => $row } );
            $json =~ s/\|/\\u007c/g;
            no warnings 'once';
            local $Lazysite::Audit::LAZYSITE_DIR = $lz;
            Lazysite::Audit::audit_log( $actor, 'data-schedule-exception-removed',
                "$name/$row->{id}", '-', 'ok', 'daemon', $json );
            my $d = Lazysite::Data::Tables::delete_row( $docroot, $name, $row->{id}, as => 'operator' );
            if   ( $d->{ok} ) { $removed++ }
            else              { $kept++ }
        }
    }
    return {
        ok      => 1,
        removed => $removed,
        kept    => $kept,
        tables  => \@named,
        ( $trail eq 'off' && $kept
            ? ( reason => 'the audit trail is off, and a passed exception is removed only where '
                    . 'the trail records the removal (ruling 164)' )
            : () ),
    };
}

# Read back what the sweep removed: the audit trail's removal lines, newest last,
# as { at, actor, table, row }.
sub removed_exceptions {
    my ($docroot) = @_;
    my $log = Lazysite::Paths::lazysite_dir($docroot) . '/logs/audit.log';
    open my $fh, '<:utf8', $log or return [];
    my @out;
    while ( my $l = <$fh> ) {
        chomp $l;
        my @f = split / \| /, $l, 8;
        next unless @f >= 8 && $f[2] eq 'data-schedule-exception-removed';
        my $d = eval { JSON::PP->new->decode( $f[7] ) } or next;
        push @out, { at => $f[0], actor => $f[1], table => $d->{table}, row => $d->{row} };
    }
    close $fh;
    return \@out;
}

1;
