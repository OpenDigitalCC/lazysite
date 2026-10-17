package Lazysite::Timing;

# SM1144 (SM1082 track T0): WHERE A REQUEST'S TIME WENT, one helper for every
# surface the engine answers.
#
# The processor, the manager API, MCP, the data endpoint, the Odoo endpoint,
# WebDAV and the auth wrapper each start a program, load modules, check who is
# asking, do the work and answer. SM693 measured "the floor" once; the sites
# agent's 2026-10-17 measurement of an Odoo read (about 550 ms, of which about
# 200 ms is lazysite starting two programs) is the first figure for a surface
# no earlier filing had timed. SM1082 asked for the before figures, and for a
# regression gate, before any of the persistent-runtime work is built. This is
# the instrument; tools/bench-surfaces.sh reads it.
#
# THE PHASES, named once, in the order they are reported:
#
#   config     reading lazysite.conf and the request
#   identity   the auth wrapper, or the session / token / basic-auth check
#   load       loading modules: from this file being loaded to begin() - the
#              compile and `use` of everything else the program loads up front.
#              Only the request that started the process has one; a pooled
#              worker's later requests did not load anything.
#   render     producing the answer (a page, a listing, a rendered JSON body)
#   call       an Odoo or connector call, made on this request's behalf
#   write      persisting: a cache file, a row, a file written over DAV
#
# ONLY PHASES THAT HAPPENED. A phase nothing entered is absent, not zero, so a
# zero in a report means "too quick to show" and an absence means "not this
# request".
#
# A STOPWATCH, NOT A SET OF TIMERS. to($phase) closes the phase in progress
# (adding the time since the last call to it) and opens the next, so a surface
# marks where a phase STARTS and nothing is counted twice or dropped. add()
# takes a figure measured elsewhere - the auth wrapper's, handed across the exec.
#
# NO LAZYSITE DEPENDENCY, deliberately: Time::HiRes only. The processor's render
# path loads no Lazysite:: module (ADR 0001), and this file is the one it loads
# by absolute path, when it can find it and not otherwise (a site whose lib is
# missing serves exactly as before, without timing). Keep it that way.
#
# WHO MAY SEE IT. A Server-Timing header is readable by anyone who can read the
# response, and a phase duration leaks a little (that a page was a cache hit, how
# long an account check took). So the header is OFF for anonymous visitors by
# default: header_line() answers only when the caller has been marked an operator
# (operator(1), set by a surface from a VERIFIED identity) or the site says
# `server_timing: on` in lazysite.conf. The access log field is the operator's
# own file and is always recorded.
use strict;
use warnings;
use Time::HiRes ();

our @PHASES = qw(config identity load render call write);
my %KNOWN = map { $_ => 1 } @PHASES;

# When this file was loaded: the start of the `load` phase. A `my` with an
# initialiser, so it runs once when the file is required, not per request.
my $LOADED = Time::HiRes::time();

# Per-request state. begin() resets every one; none outlives a request (SM973's
# class: a pooled worker must carry nothing from one request to the next).
my ( %PH, $CURRENT, $LAST, $OPERATOR, $LZDIR );
my $BEGUN = 0;    # process-lifetime, on purpose: only the first begin() has a load phase
my %CONF;         # process-lifetime memo of the conf flag, keyed on (mtime, size)

sub _now { return Time::HiRes::time() }

# A pool worker has just been forked from the parent (SM1169). The `load` phase
# is "this file loaded to the first request begun", and a worker's first request
# came AFTER a fork, not after the parent's start: without this, a worker the
# pool respawns hours after the parent started reported its first request's
# `load` as the parent's age - a figure of seconds that is nobody's load.
sub worker_started {
    $LOADED = _now();
    $BEGUN  = 0;
    return;
}

# Start a request. Resets everything, opens `config`, and picks up what an
# earlier program in this request (the auth wrapper) handed across the exec.
sub begin {
    %PH       = ();
    $OPERATOR = 0;
    $LZDIR    = undef;
    $LAST     = _now();
    $CURRENT  = 'config';
    add( 'load', ( $LAST - $LOADED ) * 1000 ) unless $BEGUN++;
    my $h = delete $ENV{LAZYSITE_TIMING_HANDOVER};
    if ( defined $h ) {
        for my $pair ( split /;/, $h ) {
            my ( $k, $v ) = split /=/, $pair, 2;
            next unless defined $v && $KNOWN{$k} && $v =~ /\A\d{1,7}(?:\.\d{1,3})?\z/;
            add( $k, $v );
        }
    }
    return;
}

# Close the phase in progress and open $phase. Unknown names are ignored, so a
# typo costs a figure and never a request.
sub to {
    my ($phase) = @_;
    return unless defined $LAST;
    my $now = _now();
    $PH{$CURRENT} += ( $now - $LAST ) * 1000;
    $LAST    = $now;
    $CURRENT = $phase if defined $phase && $KNOWN{$phase};
    return;
}

# Close the phase in progress and stay in it: the figures are complete up to now.
sub finish { return to( $CURRENT // 'config' ) }

# A figure measured elsewhere, in milliseconds.
sub add {
    my ( $phase, $ms ) = @_;
    return unless $KNOWN{ $phase // '' } && defined $ms && $ms >= 0;
    $PH{$phase} += $ms;
    return;
}

# The caller is a verified operator: the header may be shown to them.
sub operator { $OPERATOR = $_[0] ? 1 : 0; return }

# Where lazysite.conf is, for the site's own `server_timing:` switch.
sub configure { $LZDIR = $_[0]; return }

sub _conf_on {
    return 0 unless defined $LZDIR && length $LZDIR;
    my $f  = "$LZDIR/lazysite.conf";
    my @st = stat $f or return 0;
    my $k  = "$st[9]:$st[7]";
    my $m  = $CONF{$f};
    return $m->{on} if $m && $m->{k} eq $k;
    my $on = 0;
    if ( open my $fh, '<', $f ) {
        while ( my $l = <$fh> ) {
            next unless $l =~ /\Aserver_timing\s*:\s*(\S+)/;
            $on = ( lc $1 =~ /\A(?:on|true|yes|1|enabled)\z/ ) ? 1 : 0;
            last;
        }
        close $fh;
    }
    $CONF{$f} = { k => $k, on => $on };
    return $on;
}

# May the header be shown on this response?
sub enabled { return ( $OPERATOR || _conf_on() ) ? 1 : 0 }

# The phases so far, in the reported order, as ( name, ms ) pairs.
sub phases {
    return map { [ $_, $PH{$_} ] } grep { defined $PH{$_} } @PHASES;
}

# "Server-Timing: config;dur=1.20, render;dur=3.40", without a line ending; empty
# when the header is not to be shown or nothing happened. Closes the phase in
# progress first, so the figures run up to the moment the headers are written.
sub header_line {
    return '' unless defined $LAST && enabled();
    finish();
    my @p = phases() or return '';
    return 'Server-Timing: ' . join( ', ', map { sprintf '%s;dur=%.2f', @$_ } @p );
}

# The same figures for the access log: a JSON object body, "config":1.2,...
# Empty when nothing happened. Not gated: the log is the operator's own file.
sub log_object {
    return '' unless defined $LAST;
    my @p = phases() or return '';
    return '{' . join( ',', map { sprintf '"%s":%.2f', @$_ } @p ) . '}';
}

# The auth wrapper is about to exec the surface: leave its figures where the
# next program's begin() reads them. The surface adds them to its own, so
# `identity` is the wrapper's time and `load` is both programs' loading.
sub handover {
    return unless defined $LAST;
    finish();
    my @p = grep { $_->[0] =~ /\A(?:config|identity|load)\z/ } phases();
    # The wrapper's own config and identity work is all "identity" to the surface.
    my %out;
    $out{ $_->[0] eq 'load' ? 'load' : 'identity' } += $_->[1] for @p;
    $ENV{LAZYSITE_TIMING_HANDOVER} = join ';', map { sprintf '%s=%.2f', $_, $out{$_} } sort keys %out;
    return;
}

1;
