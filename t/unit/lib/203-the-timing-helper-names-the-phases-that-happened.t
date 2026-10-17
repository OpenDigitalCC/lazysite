#!/usr/bin/perl
# SM1144 (SM1082 T0): Lazysite::Timing, the one helper every surface reports
# its time through.
#
# What a surface relies on, stated as behaviour: a phase that did not happen is
# ABSENT (a zero would claim it ran and was quick); time is counted once, to the
# phase in progress; a request carries nothing from the one before it (SM973's
# class, in a pooled worker); the header is shown to an operator or when the site
# asks, and never to an anonymous visitor otherwise; and what the auth wrapper
# hands across an exec is believed only if it is a known phase and a plain number.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Timing ();

sub names { return map { $_->[0] } Lazysite::Timing::phases() }

# --- only phases that happened, in the reported order ---------------------------
Lazysite::Timing::begin();
Lazysite::Timing::to('identity');
Lazysite::Timing::to('render');
Lazysite::Timing::finish();
is_deeply( [ names() ], [qw(config identity load render)],
    'the phases entered are named, in the fixed order; call and write are absent' );
ok( ( grep { $_ eq 'load' } names() ), 'the first request of a process has a load phase' );

Lazysite::Timing::begin();
Lazysite::Timing::to('render');
Lazysite::Timing::finish();
is_deeply( [ names() ], [qw(config render)],
    'the next request in the same process has none, and nothing from the last one' );

# --- a figure measured elsewhere, and a typo costing a figure only ---------------
Lazysite::Timing::add( 'call', 12.5 );
Lazysite::Timing::add( 'bogus', 3 );
Lazysite::Timing::add( 'write', -1 );
Lazysite::Timing::to('nonsense');
is_deeply( [ names() ], [qw(config render call)],
    'an unknown phase and a negative figure are ignored' );
my %p = map { $_->[0] => $_->[1] } Lazysite::Timing::phases();
is( $p{call}, 12.5, 'add() takes the figure as given' );

# --- the stopwatch counts time once ----------------------------------------------
Lazysite::Timing::begin();
select undef, undef, undef, 0.05;
Lazysite::Timing::to('render');
select undef, undef, undef, 0.05;
Lazysite::Timing::finish();
%p = map { $_->[0] => $_->[1] } Lazysite::Timing::phases();
cmp_ok( $p{config}, '>=', 40, 'the wait before to() is the first phase' );
cmp_ok( $p{render}, '>=', 40, '...and the wait after it is the next' );
cmp_ok( $p{config}, '<',  90, '...and the first phase is not also charged the second wait' );

# --- who may see the header -------------------------------------------------------
my $lz = tempdir( CLEANUP => 1 );
Lazysite::Timing::begin();
Lazysite::Timing::configure($lz);
is( Lazysite::Timing::header_line(), '', 'no conf and no operator: no header' );
open my $cf, '>', "$lz/lazysite.conf" or die $!;
print {$cf} "site_name: T\nserver_timing: off\n";
close $cf;
is( Lazysite::Timing::header_line(), '', 'server_timing: off: no header' );
Lazysite::Timing::operator(1);
like( Lazysite::Timing::header_line(), qr/\AServer-Timing: config;dur=\d+\.\d\d\z/,
    'a verified operator is shown it, in Server-Timing syntax' );

Lazysite::Timing::begin();
Lazysite::Timing::configure($lz);
is( Lazysite::Timing::header_line(), '', 'the operator mark does not outlive the request' );
open $cf, '>', "$lz/lazysite.conf" or die $!;
print {$cf} "site_name: T\nserver_timing: on\n";
close $cf;
utime time + 5, time + 5, "$lz/lazysite.conf";    # the memo is keyed on mtime and size
Lazysite::Timing::to('render');
like( Lazysite::Timing::header_line(), qr/\AServer-Timing: config;dur=[\d.]+, render;dur=[\d.]+\z/,
    'server_timing: on shows it to anyone' );

Lazysite::Timing::begin();
is( Lazysite::Timing::header_line(), '', 'a site with no configure() shows nothing without an operator' );

# --- the access log's form is always available -----------------------------------
Lazysite::Timing::begin();
Lazysite::Timing::to('render');
Lazysite::Timing::finish();
like( Lazysite::Timing::log_object(), qr/\A\{"config":[\d.]+,"render":[\d.]+\}\z/,
    'the log object lists the same phases as JSON, without being gated' );

# --- the handover across the wrapper's exec ---------------------------------------
Lazysite::Timing::begin();
Lazysite::Timing::to('identity');
Lazysite::Timing::handover();
like( $ENV{LAZYSITE_TIMING_HANDOVER}, qr/\Aidentity=[\d.]+(?:;load=[\d.]+)?\z/,
    'the wrapper hands over its time as identity (its config work is identity to the surface)' );
my $handed = $ENV{LAZYSITE_TIMING_HANDOVER};
Lazysite::Timing::begin();
ok( !exists $ENV{LAZYSITE_TIMING_HANDOVER}, 'the next begin() takes it out of the environment' );
my %got = map { $_->[0] => $_->[1] } Lazysite::Timing::phases();
ok( exists $got{identity}, 'and the surface reports the wrapper\'s identity phase' );

$ENV{LAZYSITE_TIMING_HANDOVER} = 'identity=abc;render=1;load=2;config=1e9;write=-3;call=5.5';
Lazysite::Timing::begin();
Lazysite::Timing::finish();
%got = map { $_->[0] => $_->[1] } Lazysite::Timing::phases();
is( $got{call}, 5.5, 'a plain number for a known phase is taken' );
ok( !exists $got{write},    'a negative figure is not' );
ok( !defined $got{identity}, 'nor a non-number' );
cmp_ok( $got{config}, '<', 1000, 'nor an exponent' );

done_testing;
