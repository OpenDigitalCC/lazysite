#!/usr/bin/perl
# SM368: a split has two causes and the probe named one without checking.
#
# When some extensions serve past an ACL and others refuse, there are two
# candidates that look identical from outside:
#
#   SM283  the front end serves a static list BY EXTENSION, straight off the
#          docroot, never consulting the engine. An operator task on a template.
#   SM331  the front end still holds a descriptor for a file fetched while the
#          folder was public. Clears itself. Nobody's task.
#
# The probe reported the first, in the same sentence and the same voice as the
# measurement it had actually taken. It was wrong in the field: a correct
# measurement became a false operator work item, carried up as a fleet condition
# and relayed onward as one, twice, before anyone re-ran the experiment.
#
# THE DISCRIMINATOR IS ONE REQUEST, and the probe already had everything it
# needed to make it. A file written AFTER the gate and never fetched cannot be
# in any cache. If it serves, the split is by extension. If it gates, the
# extensions that served were warmed by the probe's own SM331 pass.
#
# TESTED WITH TWO STUB FRONT ENDS, one exhibiting each behaviour, because the
# whole point is which verdict the probe reaches - and a real front end can only
# be persuaded to do one of them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(setup_test_site);
use NginxHarness qw(free_port);

plan skip_all => 'curl not installed; the probe shells curl'
    unless `sh -c 'command -v curl 2>/dev/null'` =~ /\S/;

my $root  = "$FindBin::Bin/../..";
my $CHECK = "$root/tools/lazysite-check.pl";

# A stub front end. `mode` decides what it does with a request for a file the
# engine would refuse:
#
#   extension  serve anything with a listed extension, ACL or no ACL (SM283)
#   cache      serve only what has been requested BEFORE (SM331) - so a file
#              created after the gate, never fetched, is refused
sub start_front {
    my ( $docroot, $mode ) = @_;
    my $port = free_port();
    my $pid  = fork();
    die 'fork' unless defined $pid;
    if ( !$pid ) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec $^X, '-e', <<'STUB', $docroot, $mode, $port;
use strict; use warnings;
use IO::Socket::INET;
my ( $docroot, $mode, $port ) = @ARGV;

# What each mode models, faithfully enough that the probe's discriminator has
# something real to separate:
#
#   extension  the SM283 shape as the field measured it - the front end serves
#              a LIST of static extensions straight off the docroot and lets
#              anything else fall through to the engine. png/pdf/txt/css/gz
#              served, dat refused, whatever the ACL says.
#   cache      the SM331 shape - the front end answers from a descriptor it
#              already holds. Anything requested before is served; anything
#              outside the gated folder is fetched fresh and served; a file
#              created inside the gated folder AFTER the gate, never requested,
#              is refused.
my %STATIC = map { $_ => 1 } qw(png pdf txt css gz);
my %cached;
my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => $port,
    Listen => 16, ReuseAddr => 1 ) or die "listen: $!";
while ( my $c = $srv->accept ) {
    my $req = <$c> // '';
    my ($path) = $req =~ m{^GET\s+(\S+)};
    while ( my $l = <$c> ) { last if $l !~ /\S/ }
    $path = '/' unless defined $path;
    ( my $rel = $path ) =~ s{^/+}{};
    $rel =~ s{\?.*$}{};
    my $abs = "$docroot/$rel";
    my ($ext) = $rel =~ /\.([A-Za-z0-9]+)$/;

    # Would the ENGINE serve this? Only the probe's own gated folder is
    # protected, and only once its ACL entry exists.
    my $in_gated = $rel =~ m{^[^/]+/} ? 1 : 0;
    my $acls     = -f "$docroot/lazysite/auth/acls.json";
    my $engine_would = ( -f $abs && !( $in_gated && $acls ) ) ? 1 : 0;

    my $serve;
    if ( $mode eq 'extension' ) {
        # Static extensions come off the docroot without asking; everything
        # else falls through to the engine.
        $serve = ( -f $abs && defined $ext && $STATIC{$ext} ) ? 1 : $engine_would;
    }
    else {
        # A proxy with a cache: answer from what it holds, otherwise ask the
        # engine and remember the answer.
        if ( $cached{$rel} ) { $serve = 1 }
        else {
            $serve = $engine_would;
            $cached{$rel} = 1 if $serve;
        }
    }

    if ( $serve && -f $abs ) {
        open my $fh, '<', $abs;
        local $/; my $body = <$fh>; close $fh;
        print {$c} "HTTP/1.0 200 OK\r\nContent-Length: " . length($body)
            . "\r\n\r\n$body";
    }
    else { print {$c} "HTTP/1.0 403 Forbidden\r\n\r\n" }
    close $c;
}
STUB
        exit 1;
    }
    for ( 1 .. 60 ) {
        my $c = `curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:$port/ 2>/dev/null`;
        return ( $pid, $port ) if ( $c // '' ) =~ /^[2345]/;
        select undef, undef, undef, 0.25;
    }
    kill 'TERM', $pid;
    return ( undef, undef );
}

sub probe {
    my ( $doc, $port ) = @_;
    my $cmd = join ' ', map { quotemeta } $^X, $CHECK, '--docroot', $doc,
        '--check-acl', "http://127.0.0.1:$port";
    return scalar `$cmd 2>&1`;
}

# Minimal, the way t/integration/43 builds one: setup_test_site's permissions
# make lazysite-check refuse to write the ACL store, and the probe then SKIPS -
# which t/tools/41 exists to stop anyone reading as a pass, and which is exactly
# what the first version of this test hit.
sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/lazysite/cache" );
    for my $f ( [ "$d/lazysite/lazysite.conf", "site_name: Probe\n" ],
        [ "$d/index.md", "---\ntitle: Home\n---\nHome.\n" ] )
    {
        open my $fh, '>', $f->[0] or die $!;
        print {$fh} $f->[1];
        close $fh;
    }
    return $d;
}

subtest 'a front end serving by EXTENSION is named as that' => sub {
    my $doc = site();
    my ( $pid, $port ) = start_front( $doc, 'extension' );
SKIP: {
        skip 'stub front end did not come up', 3 unless $pid;
        my $out = probe( $doc, $port );
        kill 'TERM', $pid;

        like( $out, qr/served to anonymous visitors/,
            'the leak is reported' ) or diag $out;
        like( $out, qr/never requested is also served/,
            'and the after-the-gate file served too, so it is an extension rule' )
            or diag $out;
        like( $out, qr/FAIL/, 'which is a failure needing an operator' );
    }
};

subtest 'a front end still holding a CACHE is named as that, and is not a FAIL'
    => sub {
    my $doc = site();
    my ( $pid, $port ) = start_front( $doc, 'cache' );
SKIP: {
        skip 'stub front end did not come up', 4 unless $pid;
        my $out = probe( $doc, $port );
        kill 'TERM', $pid;

        like( $out, qr/front-end cache/,
            'the cache is named as the cause' ) or diag $out;
        like( $out, qr/created\s+AFTER the gate and never requested is refused/s,
            'on the evidence that separates it from an extension rule' )
            or diag $out;
        like( $out, qr/no action/,
            'and the operator is told there is nothing to do' );
        unlike( $out, qr/^\[ FAIL \].*anonymous/m,
            'it is not reported as a failure - it clears itself, and telling '
                . 'an operator to change a template sends them after nothing' )
            or diag $out;
    }
    };

done_testing();
