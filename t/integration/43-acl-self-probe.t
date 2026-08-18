#!/usr/bin/perl
# SM285: `lazysite check --check-acl URL` against two REAL front ends - one that
# respects the ACL and one that does not.
#
# The probe's whole job is to answer, from outside, the question that three
# incidents turned on: when the engine refuses a file, does the visitor actually
# get refused? So testing it against a mock would miss the point. Here:
#
#   * the dev server, which implements the full contract including the static
#     ACL decision - the probe must report OK;
#   * nginx configured to serve a list of static EXTENSIONS straight off the
#     docroot and proxy the rest - which is SM283 exactly - and the probe must
#     FAIL, and must recognise the extension split for what it is.
#
# The second fixture is why the probe uses several extensions. A one-extension
# probe that happened to pick .dat would report OK on a site that is serving
# .png, .pdf, .txt, .css and .gz to anyone.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(repo_root);
use NginxHarness qw(nginx_bin write_conf free_port start_nginx stop_nginx);

my $root  = repo_root();
my $NGINX = nginx_bin();

plan skip_all => 'curl not installed; the probe shells curl'
    unless `sh -c 'command -v curl 2>/dev/null'` =~ /\S/;

my $doc = tempdir( CLEANUP => 1 );
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache" );

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
spit( "$doc/lazysite/lazysite.conf", "site_name: Probe\n" );
spit( "$doc/index.md",               "---\ntitle: Home\n---\nHome.\n" );

my $CHECK = "$root/tools/lazysite-check.pl";

sub run_check {
    my ($url) = @_;
    my $cmd   = join ' ', map { quotemeta } $^X, $CHECK, '--docroot', $doc,
        '--check-acl', $url;
    return scalar `$cmd 2>&1`;
}

# --- the dev server: a front end that gets it right ---------------------------
my $dev_port = free_port();
my $dev_pid  = fork();
die 'fork' unless defined $dev_pid;
if ( !$dev_pid ) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    exec $^X, "$root/tools/lazysite-server.pl", '--docroot', $doc,
        '--port', $dev_port;
    exit 1;
}
END { kill 'TERM', $dev_pid if $dev_pid }

# Wait for it to answer rather than sleeping a guess.
my $up = 0;
for ( 1 .. 60 ) {
    my $c = `curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:$dev_port/ 2>/dev/null`;
    if ( ( $c // '' ) =~ /^[2345]/ ) { $up = 1; last }
    select undef, undef, undef, 0.25;
}

SKIP: {
    skip 'the dev server did not come up', 4 unless $up;

    my $out = run_check("http://127.0.0.1:$dev_port");
    like( $out, qr/protected content is not reachable anonymously/,
        'dev server: the probe reports the ACL is respected' );

    # Scoped to the ACL line on purpose: a bare tempdir docroot fails several
    # unrelated permission checks, and asserting "no FAIL anywhere" would pass
    # or fail for reasons that have nothing to do with this probe.
    my ($acl_fail) = grep { /FAIL.*(?:ACL|front end|anonymous)/ } split /\n/, $out;
    ok( !$acl_fail, 'dev server: no ACL-related FAIL' ) or diag $acl_fail;

    like( $out, qr/served when public and refused after protection/,
        'and the OK states its evidence - a public control WAS served, so the '
            . 'refusal is the ACL working rather than nothing working' );

    # The probe must leave nothing behind - it briefly gates a real folder in a
    # real docroot, and a probe that becomes the exposure is its own finding.
    opendir my $dh, $doc or die $!;
    my @left = grep { /\Alazysite-acl-probe-/ } readdir $dh;
    closedir $dh;
    is( scalar @left, 0, 'dev server: the probe removed its own files' );
}

# --- nginx serving statics by extension: SM283, reproduced -------------------
SKIP: {
    skip 'nginx not installed (apt install nginx-light)', 4 unless $NGINX;
    skip 'the dev server did not come up',                4 unless $up;

    my $prefix = tempdir( CLEANUP => 1 );
    make_path("$prefix/logs");
    my $port = free_port();
    my $conf = <<"SITE";
server {
    listen $port;
    server_name probe.test;
    root $doc;
    access_log $prefix/logs/a.log;

    location ~* ^.+\\.(png|pdf|txt|css|gz)\$ {
        root $doc;
        expires max;
    }
    location / {
        proxy_pass http://127.0.0.1:$dev_port;
    }
}
SITE
    write_conf( $prefix, $conf );
    my ( $rc, $err ) = start_nginx( $NGINX, $prefix );
    skip "nginx would not start: $err", 4 unless $rc == 0;
    END { stop_nginx( $NGINX, $prefix ) if $NGINX && $prefix }

    my $out = run_check("http://127.0.0.1:$port");

    # SM377 CHANGED WHAT THIS SCENARIO PROVES, and the change is the point.
    #
    # This fixture is a genuinely bypassing front end: nginx serves five
    # extensions straight off the document root and never consults the engine
    # for them. Before SM377 the probe gated by writing acls.json, so the bytes
    # stayed in the docroot and nginx served them - a real leak, correctly
    # found.
    #
    # The probe now protects the way the engine does, which MOVES the bytes out
    # of the document root. nginx then has nothing to serve, so the content is
    # genuinely not reachable - and that is the true answer, confirmed in the
    # field on edge, where a file written through the engine after gating was
    # refused on a stock template.
    #
    # So this asserts what is now true, and separately that the tool does NOT
    # claim the front end respects anything. It passes here by having nothing
    # left to serve, which is a different fact and a weaker one.
    like( $out, qr/protected content is not reachable anonymously/,
        'the content is genuinely gated, because protection moved it' );
    like( $out, qr/statement about the CONTENT, not about the front end/,
        'and the tool says so, rather than crediting a front end that never '
            . 'consulted the engine' )
        or diag( 'This fixture bypasses the engine for five extensions. A pass '
            . 'worded as "the front end respects the ACL" would be false about '
            . 'the one thing this scenario exists to demonstrate.' );

    # The old assertion here was `like($out, qr/\[ FAIL \]/)`, which passed on
    # ANY failing check in a long report - including unrelated permission
    # findings from the fixture's own tempdir. It was passing for the wrong
    # reason before this change and would have gone on passing after it.
    unlike( $out, qr/served to anonymous visitors/,
        'and no exposure is reported, because there is no longer one' );

    # The assertion that justifies probing more than one extension: .dat is off
    # the front end's static list and is correctly refused, so a probe that
    # tested only .dat would have reported this site healthy.
    like( $out, qr/\.dat/,
        '.dat is reported as refused while others leaked - which is exactly '
            . 'why one extension is not a probe' );

    stop_nginx( $NGINX, $prefix );
}

# --- the false pass, which this probe actually shipped with briefly ----------
# The first version declared its extension list as a file-scoped `my` BELOW the
# code that runs the checks, so the list was empty when the probe ran: zero
# fetches, and an "every probed file type was refused" verdict produced by
# comparing 0 with 0. It reported the front end healthy against a port with
# nothing listening on it.
#
# A security check that passes by testing nothing is the failure mode this whole
# programme exists to remove, so it gets its own regression test rather than
# relying on the two fixtures above to notice.
subtest 'a probe that reaches nothing must never report a pass' => sub {
    my $out = run_check('http://127.0.0.1:1');
    unlike( $out, qr/protected content is not reachable anonymously/,
        'nothing listening: the probe does NOT report the ACL respected' );
    like( $out, qr/no usable answer/,
        'it says it could not tell, which is the honest answer' );
    like( $out, qr/nothing was served, gated or public/,
        'and names the reason: the public control failed too, so a refusal '
            . 'proves nothing' );
};

subtest 'the probe leaves nothing behind, in either outcome' => sub {
    opendir my $dh, $doc or die $!;
    my @left = grep { /\Alazysite-acl-probe-/ } readdir $dh;
    closedir $dh;
    is( scalar @left, 0, 'no probe folders or public controls remain' )
        or diag "left behind: @left";

    # The gating entry must be gone from the store too - a probe that leaves a
    # live ACL behind has changed the site it was only supposed to measure.
    my $acls = "$doc/lazysite/auth/acls.json";
    if ( -f $acls ) {
        open my $fh, '<', $acls or die $!;
        my $raw = do { local $/; <$fh> };
        close $fh;
        unlike( $raw, qr/lazysite-acl-probe-/,
            'no probe entry left in the ACL store' );
    }
    else { pass('no ACL store was left behind at all') }
};

kill 'TERM', $dev_pid if $dev_pid;
waitpid $dev_pid, 0 if $dev_pid;
undef $dev_pid;

done_testing();
