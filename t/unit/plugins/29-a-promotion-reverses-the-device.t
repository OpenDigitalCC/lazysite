#!/usr/bin/perl
# SM541: when a visitor is promoted to scanner in a LATER batch, the reach-back
# reverses their earlier human events through the event ring. The ring stored
# no device and no search term, so the reversal decremented devices{unknown}
# while the original hit went to devices{desktop} - and a term they had pushed
# over the floor stayed counted. Devices and terms drifted on every promotion.
#
# Driven through the plugin as it runs (t/unit/plugins/25's rig): a first
# export counts the visit, a second export sees the sweep and promotes.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $NOW = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );
my $DAY = strftime( '%Y-%m-%d',                localtime );
my $UA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120';

sub line {
    my ( $ip, $target, $status ) = @_;
    return qq{$ip - - [$NOW] "GET $target HTTP/1.1" $status 100 "-" "$UA"\n};
}

sub site {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://demo.example.io\n";
    close $cf;
    if ( defined $conf ) {
        open my $sf, '>', "$d/lazysite/stats.conf" or die $!;
        print {$sf} $conf;
        close $sf;
    }
    return ( $d, "$d/access.log" );
}

sub append {
    my ( $log, @lines ) = @_;
    open my $lf, '>>', $log or die $!;
    print {$lf} @lines;
    close $lf;
    return;
}

sub day_rollup {
    my ( $d, $log ) = @_;
    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx($^X \Q$PLUGIN\E --export --day \Q$DAY\E 2>/dev/null);
    return decode_json( $out || '{}' )->{day} || {};
}

subtest 'a late promotion takes the device with it' => sub {
    my ( $d, $log ) = site(undef);
    append( $log, line( '10.0.0.1', '/', 200 ) );
    my $first = day_rollup( $d, $log );
    is( $first->{classes}{human} // 0, 1, 'batch 1: one human visit' );
    is( $first->{devices}{desktop} // 0, 1, 'batch 1: on a desktop' );

    # The same visitor, same client, now sweeps: promoted, reached back.
    append( $log, line( '10.0.0.1', '/wp-login.php', 404 ) );
    my $second = day_rollup( $d, $log );
    is( $second->{classes}{human} // 0, 0, 'batch 2: the human visit is reversed' );
    ok( $second->{classes}{scanner}, 'batch 2: and counted as scanner' );
    is( $second->{devices}{desktop} // 0, 0,
        'batch 2: the desktop count is reversed with it' )
        or diag explain $second->{devices};
    ok( !exists $second->{devices}{unknown},
        'and no phantom unknown device was created by the reversal' )
        or diag explain $second->{devices};
};

subtest 'a late promotion takes the search term with it' => sub {
    my ( $d, $log ) = site("search_terms: on\n");
    # Three visitors clear the floor (3); one of them is later promoted.
    append( $log, map { line( "10.0.0.$_", '/search-results?q=common', 200 ) } 1 .. 3 );
    my $first = day_rollup( $d, $log );
    is_deeply( $first->{search_terms}, [ { key => 'common', count => 3 } ],
        'batch 1: the term cleared the floor' )
        or diag explain $first->{search_terms};

    append( $log, line( '10.0.0.3', '/wp-login.php', 404 ) );
    my $second = day_rollup( $d, $log );
    my @terms  = map { $_->{key} } @{ $second->{search_terms} || [] };
    is_deeply( \@terms, [], 'batch 2: the promoted visitor\'s search is reversed, back below the floor' )
        or diag explain $second->{search_terms};
};

done_testing();
