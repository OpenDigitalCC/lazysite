#!/usr/bin/perl
# SM802: Lazysite::Remap - what a rule may be, and the count read back from the
# visitor log rather than kept beside it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Remap qw(parse_rules write_rules report);

# --- what a rule may be -----------------------------------------------------
{
    my ( $r, $e ) = parse_rules("www.example.com /web https://b.example.com\n");
    is( scalar @$r, 1, 'a plain rule parses' );
    is( $r->[0]{code}, 302, '...302 unless it says otherwise' );
}
for my $bad (
    [ "www.example.com web https://b.example.com",       'a prefix without a leading slash' ],
    [ "www.example.com /web //evil.example",             'a protocol-relative destination - another host in a path\'s clothes' ],
    [ "www.example.com /web javascript:alert(1)",        'a non-http destination' ],
    [ "www.example.com /web https://b.example.com 307",  'a status other than 301 or 302' ],
    [ "not a host! /web https://b.example.com",          'a host that is not a host' ],
    [ "www.example.com /../x https://b.example.com",     'a prefix that climbs' ],
    )
{
    my ( $r, $e ) = parse_rules( $bad->[0] );
    ok( !@$r && @$e, "refused: $bad->[1]" );
}
{
    my ( $r, $e ) = parse_rules("a.example /web https://x.example\na.example /web/ https://y.example\n");
    ok( @$e, 'the same prefix twice for one host is refused - /web/ and /web are one prefix' );
}

# --- a save writes only what parses ----------------------------------------
my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path("$lz/logs");
{
    my $w = write_rules( $lz, "a.example /web https://x.example\nbroken line\n" );
    ok( !$w->{ok}, 'a file that would be half-applied is not written' );
    ok( !-e "$lz/remap/rules.conf", '...and nothing was written' );
}
ok( write_rules( $lz, "a.example /web https://x.example\na.example /old https://x.example 301\n" )->{ok},
    'a clean file is written' );

# --- THE REPORT, AND ITS FOUR STATES ---------------------------------------
{
    my $r = report($lz);
    ok( !$r->{recorded}, 'with no visitor log, the report says nothing was recorded' );
    like( $r->{note} // '', qr/not the same as nobody following them/,
        '...and says that is not the same as zero - only one of them means a rule can go' );
}
{
    open my $lf, '>', "$lz/logs/access-20260911.jsonl" or die $!;
    print {$lf} qq({"t":1000,"p":"/web/a","s":302,"h":"a.example","rr":"/web"}\n);
    print {$lf} qq({"t":2000,"p":"/web/b","s":302,"h":"a.example","rr":"/web"}\n);
    print {$lf} qq({"t":3000,"p":"/web/c","s":302,"h":"b.example","rr":"/web"}\n);    # another host
    print {$lf} qq({"t":4000,"p":"/other","s":200,"h":"a.example"}\n);
    close $lf;
    my $r = report($lz);
    my %by = map { ( $_->{prefix} => $_ ) } @{ $r->{rules} };
    ok( $r->{recorded}, 'with a log, the report is recorded' );
    is( $by{'/web'}{hits}, 2, 'hits counts this host\'s redirects for the rule, not another host\'s' );
    is( $by{'/web'}{last_used}, 2000, 'last_used is the latest - the date that says when a rule can go' );
    is( $by{'/old'}{hits}, 0, 'a rule nobody followed reports zero, with a log to prove it' );
}

done_testing();
