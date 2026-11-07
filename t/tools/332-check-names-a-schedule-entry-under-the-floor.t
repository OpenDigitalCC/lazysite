#!/usr/bin/perl
# SM1391 (ruling 148): `lazysite check` names a schedule entry whose interval
# is under the 300-second floor. The scheduler never runs such an entry and
# (since SM1391) records the refusal once; this is the answer for an operator
# who has the file and not the daemon's record.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

sub site {
    my ($schedule) = @_;
    my $doc = site_tempdir();
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager forms);
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    if ( defined $schedule ) {
        open my $fh, '>', "$doc/lazysite/forms/schedule.conf" or die $!;
        print {$fh} $schedule;
        close $fh;
    }
    return $doc;
}
sub run_check { my ($doc) = @_; return qx($^X \Q$script\E --docroot \Q$doc\E 2>&1) }
sub line { my ( $out, $re ) = @_; my ($l) = grep { /$re/ } split /\n/, $out; return $l // '' }

my $out = run_check( site( "schedule:\n"
        . "  - id: fine\n    handler: store\n    every: 3600\n    enabled: true\n    payload: {}\n"
        . "  - id: hand\n    handler: store\n    every: 60\n    enabled: true\n    payload: {}\n"
        . "  - id: words\n    handler: store\n    every: soon\n    payload: {}\n"
        . "  - id: off\n    handler: store\n    every: 10\n    enabled: false\n    payload: {}\n" ) );
my $l = line( $out, qr/under the 300-second floor/ );
ok( length $l, 'the check names entries under the floor' ) or diag $out;
like( $l, qr/2 schedule entries/, 'two of them' );
like( $l, qr/'hand' \(every: 60\)/,    'the hand-written every: 60, with its value' );
like( $l, qr/'words' \(every: soon\)/, 'and an interval that is not a number' );
unlike( $l, qr/'fine'/, 'not the entry at the floor' );
unlike( $l, qr/'off'/,  'nor a disabled one, which is off on purpose' );
like( $out, qr/set every: to 300 or more/, 'with the remedy' );

my $quiet = run_check( site("schedule:\n  - id: fine\n    handler: store\n    every: 300\n    payload: {}\n") );
like( $quiet, qr/every schedule entry is at or above the 300-second floor/, 'a site at the floor is told so' );
unlike( $quiet, qr/under the 300-second floor/, 'and nothing is named' );

my $none = run_check( site(undef) );
unlike( $none, qr/under the 300-second floor/, 'a site with no schedule names nothing' );

done_testing();
