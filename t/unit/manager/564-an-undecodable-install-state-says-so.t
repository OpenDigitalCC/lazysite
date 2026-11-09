#!/usr/bin/perl
# Ruling 206 (item 20 of the 0.16.9 fault survey): AN UNDECODABLE INSTALL STATE
# SAYS SO.
#
# Manager::Services::action_version answered version: null with no WARN for a
# lazysite/.install-state.json that does not decode - the same answer as a site
# installed before the file existed. Now the log names the store and the
# remedy, and the answer carries the cannot-tell sentence beside the null. An
# absent file and a good one answer as before.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Services ();

my $d = tempdir( CLEANUP => 1 );
mkdir "$d/lazysite";
$Lazysite::Manager::Services::DOCROOT      = $d;
$Lazysite::Manager::Services::LAZYSITE_DIR = "$d/lazysite";
my $f = "$d/lazysite/.install-state.json";

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh; return }

sub version {
    my $err = '';
    my $r;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $r = Lazysite::Manager::Services::action_version();
        close STDERR;
    }
    return ( $r, $err );
}

subtest 'absent: null, quietly' => sub {
    my ( $r, $err ) = version();
    is( $r->{version}, undef, 'no version' );
    ok( !defined $r->{error}, 'and no fault' );
    is( $err, '', 'nothing logged' );
};

subtest 'good: the version' => sub {
    spit( $f, '{"version":"0.16.8","installed_at":"2026-11-08"}' );
    my ($r) = version();
    is( $r->{version}, '0.16.8', 'the installed version' );
};

subtest 'undecodable: null, and it says why' => sub {
    spit( $f, '{"version":"0.16' );
    my ( $r, $err ) = version();
    is( $r->{version}, undef, 'still null' );
    like( $r->{error} // '', qr/lazysite\/\.install-state\.json does not decode as a JSON object/,
        'the answer names the store' );
    like( $r->{error} // '', qr/`lazysite check --docroot <docroot>` names the fault/, 'and the check' );
    like( $err, qr/cannot tell - lazysite\/\.install-state\.json does not decode/, 'the log names it' );
};

done_testing();
