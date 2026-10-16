#!/usr/bin/perl
# SM1098 (T9): a client that declares `lazysite-agent/<partner-id>` is a bot,
# whatever its 404s.
#
# Field report (0.15.5 test plan): "Anonymous probes of draft-folder 404s put
# this agent in the scanner class (40 visits, 51% of the day's window), not
# bot." The briefing tells agents to send that User-Agent so their hits are
# "recorded as bot traffic rather than dropped". classify() honours it, but the
# visitor-level sweep promotion (SM332) ran on every record and rewrote the
# agent's class to `scanner` once it had asked for five distinct missing paths.
# A declared agent says what it is; the sweep is for clients that do not.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use POSIX      qw(strftime);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $plugin = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $plugin" unless -f $plugin;

my $BASE = int( time() / 86400 ) * 86400 - 86400 + 3600;

sub export_log {
    my (@req) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\n";
    close $cf;
    my $log = "$d/access.log";
    open my $lf, '>', $log or die $!;
    for my $r (@req) {
        my ( $ip, $path, $status, $offset, $ua ) = @$r;
        my $when = strftime( '%d/%b/%Y:%H:%M:%S +0000', gmtime( $BASE + $offset ) );
        print $lf qq{$ip - - [$when] "GET $path HTTP/1.1" $status 100 "-" "$ua"\n};
    }
    close $lf;
    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx($^X \Q$plugin\E --export --window 30 2>/dev/null);
    return decode_json($out);
}

sub classes {
    my ($r) = @_;
    my %c;
    $c{ $_->{class} }++ for @{ $r->{events} || [] };
    return \%c;
}

# Eight different missing draft pages, 30 seconds apart (slow enough that the
# pace rule is not what is being tested).
sub misses {
    my ( $ip, $ua ) = @_;
    return map { [ $ip, "/drafts/page-$_", 404, $_ * 30, $ua ] } 1 .. 8;
}

subtest 'a declared agent sweeping 404s is a bot' => sub {
    my $c = classes( export_log( misses( '203.0.113.20', 'lazysite-agent/partner-7 Mozilla/5.0' ) ) );
    is_deeply( $c, { bot => 8 }, 'all eight are bot' ) or diag( explain $c );
};

subtest 'the control: the same sweep from an undeclared client is a scanner' => sub {
    my $c = classes( export_log( misses( '203.0.113.21', 'Mozilla/5.0 Chrome/120' ) ) );
    is_deeply( $c, { scanner => 8 }, 'all eight are scanner' ) or diag( explain $c );
};

subtest 'a declared agent behind the same address does not shield or taint a browser' => sub {
    my @req = ( misses( '203.0.113.22', 'lazysite-agent/partner-7' ),
        [ '203.0.113.22', '/', 200, 400, 'Mozilla/5.0 Chrome/120' ] );
    my $c = classes( export_log(@req) );
    is( $c->{bot},     8, 'the agent is bot' ) or diag( explain $c );
    ok( !$c->{scanner}, 'nothing is scanner' ) or diag( explain $c );
};

done_testing();
