package Odoo::Ops::Zone;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use DateTime ();
use DateTime::TimeZone ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Zone - local date and time in a named zone or offset, as UTC

=head1 SYNOPSIS

    my $fn = Odoo::Ops::Zone->compile( '%m/%d/%Y %I:%M %p:America/New_York', 'clock_in' );
    my $utc = $fn->( '11/01/2026 01:30 AM', \@marks, $record );

=head1 DESCRIPTION

The engine of the C<datetime:FORMAT:ZONE> mapping transform (see
L<Odoo::Ops::Source>). C<compile> checks the argument at load and returns a
function C<($value, \@marks, $record)> that gives Odoo's own datetime text,
C<YYYY-MM-DD HH:MM:SS> in UTC, or undef with a mark when the value cannot be
converted. An empty value stays undef with no mark.

FORMAT is a C<strptime>-style string with the directives C<%Y %y %m %d %e %H
%I %M %S %p %b %B %z %T %%>; whitespace in the format matches any whitespace
(or none) in the value. It must name a year, a month and a day. C<%I> needs
C<%p>. ZONE is the part after the last colon that reads as a zone, one of:

=over

=item an IANA name (C<America/New_York>) or C<UTC>

=item a fixed offset (C<+05:30>, C<-0800>, C<+01>)

=item C<@column>

the zone is read from that column of the same row, in any of the above forms.

=back

When the format has C<%z> the value carries its own offset (C<+0530>,
C<-05:00>, C<Z>), which is used, and ZONE may be left out; if a ZONE is given as
well, the offset in the value wins.

A value that does not match the format, a day that is not a real date, a zone
that is not known and a C<@column> that is empty or names no zone each leave a
mark that names the value and the zone. A local time that the zone skips (the
spring clock change) or has twice (the autumn one) is not guessed: the mark
names the two instants it could be, in UTC, and the caller chooses (write the
offset in the value, or correct the source).

Zone rules come from C<DateTime::TimeZone>, which reads the tz database that
the C<tzdata> package ships; a newer database is picked up with the module.

=cut

my $ZONE_RE = qr{
    UTC | Z | @ [A-Za-z_]\w* | [+-]\d\d(?::?\d\d)? |
    [A-Za-z][A-Za-z0-9_+\-]* (?: / [A-Za-z0-9_+\-]+ )*
}x;

my %MONTH = do {
    my @m = qw(january february march april may june july august september october november december);
    my %h;
    for my $i ( 0 .. 11 ) { $h{ $m[$i] } = $h{ substr $m[$i], 0, 3 } = $i + 1 }
    %h;
};

my %TZ;    # cache of zone objects by name

sub _fail ($lf, $arg, $why) {
    Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': transform 'datetime:$arg' $why",
        fix => 'correct the transform in the mapping file (datetime:FORMAT:ZONE, e.g. datetime:%m/%d/%Y %I:%M %p:America/New_York)' );
}

# FORMAT -> [ regex, [capture names] ]
sub _format ($lf, $arg, $fmt) {
    my ( $re, @names, %seen ) = ('');
    my $num = sub ($name, $pat) { push @names, $name; $seen{$name}++; return "($pat)" };
    my $pos = 0;
    while ( $pos < length $fmt ) {
        my $ch = substr $fmt, $pos, 1;
        if ( $ch eq '%' ) {
            my $d = substr $fmt, $pos + 1, 1;
            $pos += 2;
            if    ( $d eq 'Y' ) { $re .= $num->( Y => '\d{4}' ) }
            elsif ( $d eq 'y' ) { $re .= $num->( y => '\d\d' ) }
            elsif ( $d eq 'm' ) { $re .= $num->( m => '\d{1,2}' ) }
            elsif ( $d eq 'd' ) { $re .= $num->( d => '\d{1,2}' ) }
            elsif ( $d eq 'e' ) { $re .= '\s*' . $num->( d => '\d{1,2}' ) }
            elsif ( $d eq 'H' ) { $re .= $num->( H => '\d{1,2}' ) }
            elsif ( $d eq 'I' ) { $re .= $num->( I => '\d{1,2}' ) }
            elsif ( $d eq 'M' ) { $re .= $num->( M => '\d\d' ) }
            elsif ( $d eq 'S' ) { $re .= $num->( S => '\d\d' ) }
            elsif ( $d eq 'p' ) { $re .= $num->( p => '[AaPp]\.?[Mm]\.?' ) }
            elsif ( $d eq 'b' || $d eq 'B' ) { $re .= $num->( b => '[A-Za-z]{3,9}' ) }
            elsif ( $d eq 'z' ) { $re .= $num->( z => '[+-]\d\d(?::?\d\d)?|Z' ) }
            elsif ( $d eq 'T' ) { $re .= $num->( H => '\d{1,2}' ) . ':' . $num->( M => '\d\d' ) . ':' . $num->( S => '\d\d' ) }
            elsif ( $d eq '%' ) { $re .= '%' }
            else { _fail( $lf, $arg, "has an unsupported directive '%$d' (supported: %Y %y %m %d %e %H %I %M %S %p %b %B %z %T %%)" ) }
        }
        elsif ( $ch =~ /\s/ ) { $re .= '\s*'; $pos++; $pos++ while $pos < length $fmt && substr( $fmt, $pos, 1 ) =~ /\s/ }
        else { $re .= quotemeta $ch; $pos++ }
    }
    _fail( $lf, $arg, 'needs a year (%Y or %y), a month (%m, %b or %B) and a day (%d or %e) in its format' )
        if !( $seen{Y} || $seen{y} ) || !( $seen{m} || $seen{b} ) || !$seen{d};
    _fail( $lf, $arg, 'has a 12-hour clock (%I) but no %p' ) if $seen{I} && !$seen{p};
    _fail( $lf, $arg, 'has both %H and %I' ) if $seen{H} && $seen{I};
    return ( qr/\A\s*$re\s*\z/i, \@names, $seen{z} ? 1 : 0 );
}

# '+05:30' / '-0800' / '+01' / 'Z' to seconds east of UTC
sub _offset ($s) {
    return 0 if $s eq 'Z';
    my ( $sign, $h, $m ) = $s =~ /\A([+-])(\d\d):?(\d\d)?\z/ or return undef;
    return undef if $h > 23 || ( $m // 0 ) > 59;
    return ( $sign eq '-' ? -1 : 1 ) * ( $h * 3600 + ( $m // 0 ) * 60 );
}

# a zone text to [ kind, value ]: offset seconds or a DateTime::TimeZone; undef when unknown
sub _zone ($text) {
    return undef if !defined $text;
    $text =~ s/\A\s+|\s+\z//g;
    return undef if $text !~ /\A(?:$ZONE_RE)\z/ || $text =~ /\A@/;
    return [ off => 0 ] if $text eq 'UTC' || $text eq 'Z';
    if ( $text =~ /\A[+-]/ ) { my $o = _offset($text); return defined $o ? [ off => $o ] : undef }
    return $TZ{$text} //= do {
        my $tz = eval { DateTime::TimeZone->new( name => $text ) };
        $tz ? [ tz => $tz ] : undef;
    };
}

sub _utc_text ($epoch) { return DateTime->from_epoch( epoch => $epoch, time_zone => 'UTC' )->strftime('%Y-%m-%d %H:%M:%S') }

sub compile ($class, $arg, $lf) {
    my ( $fmt, $zone );
    if ( $arg =~ /\A(.*):($ZONE_RE)\z/s && $1 !~ /\A\s*\z/ ) { ( $fmt, $zone ) = ( $1, $2 ) }
    else { $fmt = $arg }
    # a trailing zone segment is only a zone when the format (without it) still reads as one
    _fail( $lf, $arg, 'needs a format' ) if !length $fmt;
    my ( $re, $names, $has_z ) = _format( $lf, $arg, $fmt );
    _fail( $lf, $arg, 'needs a zone (an IANA name, UTC, an offset such as +05:30, or @column) unless the format has %z' ) if !defined $zone && !$has_z;
    my ( $fixed, $col );
    if ( defined $zone ) {
        if ( $zone =~ /\A@(.+)\z/ ) { $col = $1 }
        else {
            $fixed = _zone($zone) or _fail( $lf, $arg, "names a zone that is not known ('$zone')" );
        }
    }
    my $zname = defined $zone ? $zone : 'the offset in the value';
    return sub ($v, $marks, $rec = {}) {
        return $v if !defined $v || ref $v;
        return undef if $v !~ /\S/;
        my $mark = sub ($why, $z = $zname) { push @$marks, "invalid:datetime '$v' ($why; zone $z)"; return undef };
        my @got = $v =~ $re or return $mark->("does not match the format '$fmt'");
        my %p;
        @p{@$names} = @got;
        my $year = defined $p{Y} ? $p{Y} : ( $p{y} < 69 ? 2000 : 1900 ) + $p{y};
        my $mon;
        if ( defined $p{m} ) { $mon = $p{m} + 0 }
        else { $mon = $MONTH{ lc $p{b} } or return $mark->("'$p{b}' is not a month name") }
        my $day = $p{d} + 0;
        my $hour = defined $p{H} ? $p{H} + 0 : 0;
        if ( defined $p{I} ) {
            return $mark->('the hour on a 12-hour clock is 1 to 12') if $p{I} < 1 || $p{I} > 12;
            my $pm = lc( $p{p} ) =~ /\Ap/ ? 1 : 0;
            $hour = $p{I} % 12 + ( $pm ? 12 : 0 );
        }
        my ( $min, $sec ) = ( $p{M} // 0, $p{S} // 0 );
        return $mark->('not a real time') if $hour > 23 || $min > 59 || $sec > 59;
        return $mark->('not a real date') if $mon < 1 || $mon > 12 || $day < 1 || $day > 31
            || !eval { DateTime->new( year => $year, month => $mon, day => $day, time_zone => 'UTC' ); 1 };
        # the local reading as if it were UTC
        my $local = DateTime->new( year => $year, month => $mon, day => $day, hour => $hour, minute => $min, second => $sec, time_zone => 'UTC' )->epoch;
        if ( defined $p{z} ) { return _utc_text( $local - _offset( $p{z} ) ) }
        my $z = $fixed;
        my $zshow = $zname;
        if ( defined $col ) {
            my $t = $rec->{$col};
            $t = join ' ', @$t if ref $t eq 'ARRAY';
            return $mark->( "the zone column '$col' is " . ( defined $t && $t =~ /\S/ ? 'unreadable' : 'empty' ), "\@$col" ) if !defined $t || ref $t;
            $t =~ s/\A\s+|\s+\z//g;
            $zshow = length $t ? "'$t' from column $col" : "\@$col";
            $z = _zone($t) or return $mark->( length $t ? "'$t' is not a known zone" : "the zone column '$col' is empty", $zshow );
        }
        return _utc_text( $local - $z->[1] ) if $z->[0] eq 'off';
        # a named zone: the offsets in force a day either side say which readings are possible
        my $tz = $z->[1];
        my %cand;
        for my $probe ( $local - 86400, $local + 86400 ) {
            my $o = $tz->offset_for_datetime( DateTime->from_epoch( epoch => $probe, time_zone => 'UTC' ) );
            my $utc = $local - $o;
            $cand{$utc} = 1 if $tz->offset_for_datetime( DateTime->from_epoch( epoch => $utc, time_zone => 'UTC' ) ) == $o;
        }
        my @c = sort { $a <=> $b } keys %cand;
        return _utc_text( $c[0] ) if @c == 1;
        if (@c == 2) {
            return $mark->( 'this local time happens twice that day; it could be ' . _utc_text( $c[0] ) . ' UTC or ' . _utc_text( $c[1] ) . ' UTC, so the row is held for the caller to choose', $zshow );
        }
        my @alt = sort map { _utc_text( $local - $tz->offset_for_datetime( DateTime->from_epoch( epoch => $local + $_, time_zone => 'UTC' ) ) ) } ( -86400, 86400 );
        return $mark->( 'this local time does not exist (the clocks skip it); the readings either side are ' . $alt[0] . ' UTC and ' . $alt[1] . ' UTC, so the row is held for the caller to choose', $zshow );
    };
}

1;
