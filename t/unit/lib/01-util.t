#!/usr/bin/perl
# SM079 step 1: Lazysite::Util - the first shared module. Unit-tested IN-PROCESS
# (no subprocess), so Devel::Cover measures it directly - the point of the
# modular refactor for coverage.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Util qw(const_eq log_event);

# --- const_eq (timing-safe compare) ---
ok( const_eq( 'abc', 'abc' ), 'equal strings compare true' );
ok( const_eq( '', '' ),       'empty strings compare true' );
ok( !const_eq( 'abc', 'abd' ), 'differing strings compare false' );
ok( !const_eq( 'abc', 'abcd' ), 'different lengths compare false' );
ok( !const_eq( undef, 'x' ),   'undef left compares false' );
ok( !const_eq( 'x', undef ),   'undef right compares false' );

# --- log_event (level filter + format) ---
sub capture_stderr {
    my ($code) = @_;
    my $buf = '';
    local *STDERR;
    open STDERR, '>', \$buf or die "capture: $!";
    $code->();
    close STDERR;
    return $buf;
}

{
    local $Lazysite::Util::COMPONENT = 'test';
    local $ENV{LAZYSITE_LOG_LEVEL}   = 'INFO';
    local $ENV{LAZYSITE_LOG_FORMAT}  = 'text';

    my $txt = capture_stderr( sub { log_event( 'INFO', 'ctx', 'hello', k => 'v' ) } );
    like( $txt, qr/\[INFO\] \[test\] \[ctx\] hello k=v/, 'text format renders component/context/extras' );

    my $dbg = capture_stderr( sub { log_event( 'DEBUG', 'ctx', 'quiet' ) } );
    is( $dbg, '', 'DEBUG suppressed below the INFO threshold' );

    local $ENV{LAZYSITE_LOG_FORMAT} = 'json';
    my $j = capture_stderr( sub { log_event( 'WARN', 'ctx', 'msg', k => 'v' ) } );
    like( $j, qr/"level":"WARN"/,       'json: level' );
    like( $j, qr/"component":"test"/,   'json: component from $COMPONENT' );
    like( $j, qr/"message":"msg"/,      'json: message' );
}

# The module lives where it installs (DOCROOT/../lib, beside tools/ + plugins/).
ok( -f "$FindBin::Bin/../../../lib/Lazysite/Util.pm", 'Util.pm present in lib/Lazysite' );

done_testing();
