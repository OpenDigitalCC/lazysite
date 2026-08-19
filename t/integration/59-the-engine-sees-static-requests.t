#!/usr/bin/perl
# SM377 follow-up: detect a bypassing front end WITHOUT any protected content.
#
# Fixing SM377 cost the ACL probe this. It now protects the way the engine does,
# which MOVES content out of the document root - so a front end answering
# statics on its own has nothing left to serve, and looks identical to one
# routing correctly. The detection was lost precisely because the probe became
# honest.
#
# The engine's own headers answer it directly: since SM352 every response the
# engine writes carries the security header set, so their ABSENCE on a static is
# the signature of something else having answered it.
#
# TWO REAL SERVERS, because the whole question is which process answered - and
# nothing short of driving both can tell. One case is the engine answering
# everything; the other is nginx serving statics off the docroot and proxying
# the rest, which is the stock proxy template's shape and what edge was measured
# doing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use NginxHarness qw(nginx_bin free_port write_conf start_nginx stop_nginx);
use TestHelper   qw(repo_root);

my $root = repo_root();
plan skip_all => 'no curl' unless system('sh -c "command -v curl >/dev/null 2>&1"') == 0;

my $dev = "$root/tools/lazysite-server.pl";
plan skip_all => "no $dev" unless -f $dev;

# A real installed site, because the check reads the docroot to choose an asset.
my $docroot = tempdir( 'lazysite-routing-XXXXXX',     TMPDIR => 1, CLEANUP => 1 );
my $cgibin  = tempdir( 'lazysite-routing-cgi-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $mf      = "$root/release-manifest.json";
my $had_mf  = -f $mf;
system( $^X, "$root/tools/build-manifest.pl", '--out', $mf ) == 0
    or plan skip_all => 'could not build a manifest';
my $rc = system( $^X, "$root/install.pl", '--docroot', $docroot, '--cgibin', $cgibin );
unlink $mf unless $had_mf;
plan skip_all => 'install did not complete' unless $rc == 0;

make_path("$docroot/lazysite-assets/probe");
open my $css, '>', "$docroot/lazysite-assets/probe/site.css" or die $!;
print {$css} "body{color:red}\n";
close $css;

my $dev_port = free_port();
my $pid      = fork();
die 'fork failed' unless defined $pid;
if ( !$pid ) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    exec $^X, $dev, '--docroot', $docroot, '--port', $dev_port;
    exit 1;
}
END { kill 'TERM', $pid if $pid }

my $up = 0;
for ( 1 .. 60 ) {
    my $c = `curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:$dev_port/ 2>/dev/null`;
    if ( ( $c // '' ) =~ /^[23]/ ) { $up = 1; last }
    select undef, undef, undef, 0.25;
}
plan skip_all => 'the dev server did not come up' unless $up;

sub check_against {
    my ($url) = @_;
    return `cd \Q$root\E && $^X tools/lazysite-check.pl --docroot \Q$docroot\E --check-acl \Q$url\E 2>/dev/null`;
}

subtest 'the engine answering everything is reported as such' => sub {
    my $out = check_against("http://127.0.0.1:$dev_port");
    like( $out, qr/the engine answers static requests/,
        'a page and a static both carry the engine headers' )
        or diag($out);
    unlike( $out, qr/answered WITHOUT the engine/,
        'and no bypass is claimed' );
};

SKIP: {
    my $nginx = nginx_bin();
    skip 'nginx not installed', 1 unless $nginx;

    # The stock proxy template's shape: static extensions straight off the
    # docroot, everything else proxied. This is what edge was measured doing.
    my $prefix = tempdir( 'lazysite-routing-ngx-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $port   = free_port();
    my $conf   = <<"SITE";
server {
    listen $port;
    server_name probe.test;
    root $docroot;
    location ~* \\.(css|js|png|jpg|gif|svg)\$ { root $docroot; }
    location / { proxy_pass http://127.0.0.1:$dev_port; }
}
SITE
    write_conf( $prefix, $conf );
    my ( $nrc, $err ) = start_nginx( $nginx, $prefix );
    skip "nginx would not start: $err", 1 unless $nrc == 0;

    subtest 'a front end serving statics directly is detected' => sub {
        my $out = check_against("http://127.0.0.1:$port");
        stop_nginx( $nginx, $prefix );

        like( $out, qr/static requests are answered WITHOUT the engine/,
            'the bypass is named' )
            or diag( 'This front end genuinely answers statics off the '
                . "docroot, and the engine never sees those requests.\n$out" );

        # THE CLAIM IS ABOUT ROUTING, NOT ACCESS. Protected content has left
        # the served tree, so what this front end serves is public and served
        # correctly. Saying otherwise is the inference that made the ACL probe
        # wrong, and it must not reappear here.
        unlike( $out, qr/served to anonymous visitors/,
            'and no exposure is claimed on the strength of it' )
            or diag( 'This detects the PRECONDITION for the SM283 family, not '
                . 'an exposure. Overstating it is exactly how the previous '
                . 'probe misled an operator.' );
        like( $out, qr/not an exposure on its own/,
            'the hint says so explicitly' );
    };
}

SKIP: {
    my $nginx = nginx_bin();
    skip 'nginx not installed', 1 unless $nginx;

    # THE CASE THE PAGE CONTROL EXISTS FOR, and the reason it must not be
    # deleted as a redundant request. Here NOTHING reaches the engine - a plain
    # static server, no proxy at all - so the static carries no engine headers
    # for a reason that has nothing to do with a front end intercepting them.
    #
    # Without the page request first, "no headers on a static" is ambiguous
    # between a bypassing front end and an engine setting no headers anywhere,
    # and the check would report a bypass here. The page establishes that this
    # instance sets them; the static's silence only means something against
    # that.
    my $prefix = tempdir( 'lazysite-routing-none-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $port   = free_port();
    my $conf   = <<"SITE";
server {
    listen $port;
    server_name probe.test;
    root $docroot;
    location / { try_files \$uri \$uri/index.html =404; }
}
SITE
    # The root must ANSWER, or the check bails earlier for an unrelated reason
    # and this subtest passes without exercising the control at all - which is
    # what the first version of it did.
    open my $idx, '>', "$docroot/index.html" or die $!;
    print {$idx} "<html><body>static</body></html>\n";
    close $idx;

    write_conf( $prefix, $conf );
    my ( $nrc, $err ) = start_nginx( $nginx, $prefix );
    skip "nginx would not start: $err", 1 unless $nrc == 0;

    subtest 'an engine that answers nothing is not reported as a bypass' => sub {
        my $out = check_against("http://127.0.0.1:$port");
        stop_nginx( $nginx, $prefix );

        unlike( $out, qr/static requests are answered WITHOUT the engine/,
            'no bypass is claimed when the page carries no headers either' )
            or diag( 'The page control is what separates these two. Without '
                . "it this is indistinguishable from a bypass.\n$out" );
        like( $out, qr/ROUTING CHECK SKIPPED/,
            'the check declines and says so, rather than guessing' )
            or diag($out);
    };
}

done_testing();
