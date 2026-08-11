#!/usr/bin/perl
# SM283, against a RUNNING nginx: the field measurement, reproduced.
#
# The original: one folder ACL on a live site, and the same 11829 bytes uploaded
# under five extensions so nothing varied but the name. Four were served to an
# anonymous client, byte-identical to the source; only .dat gated, because .dat
# was the one extension absent from the front end's static list. The section's
# pages bounced to login throughout, so every surface the operator could consult
# agreed it was protected.
#
# This drives the shipped Hestia proxy template with the real nginx binary. The
# Apache backend deliberately does NOT exist, which turns the question into a
# clean one: a 502 means nginx handed the request on (the engine would then
# apply the ACL), and a 200 means nginx answered it itself and no ACL can ever
# reach it. That is precisely the distinction the defect was about, and it needs
# no backend to observe.
#
# Why this is worth a running server rather than another text match: t/lint/33
# can see that a deny for /lazysite/ is in the file. It cannot see whether
# `error_page 418` fires where intended, whether an exact `location =` outranks
# a real file on disk, or which of two locations nginx selects. Those are
# nginx's matching rules, and SM283 happened because we had been reasoning about
# them instead of checking them.
#
# Which is not a rhetorical point. The first draft of this file asserted that
# `^~` was what refused the pre-install backup; running the server showed that
# claim was false, and the assertion below is the one that survived contact.
# See the note in the engine-directory subtest.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use NginxHarness
    qw(nginx_bin render write_conf free_port http_get start_nginx stop_nginx);

my $NGINX = nginx_bin();
plan skip_all => 'nginx not installed (apt install nginx-light to run this)'
    unless $NGINX;

my $root   = repo_root();
my $prefix = tempdir( CLEANUP => 1 );
my $doc    = "$prefix/docroot";
make_path( "$doc/upcoming", "$doc/lazysite/auth", "$doc/lazysite/backups",
    "$prefix/logs", "$prefix/home/siteuser/conf/web/lazysite.test" );

# Stop nginx however this exits, or a stray master process outlives the run.
END { stop_nginx( $NGINX, $prefix ) if $NGINX && $prefix }

my $BYTES = 'IDENTICAL-BYTES-UNDER-EVERY-NAME';
my @EXTS  = qw(png pdf txt bin dat);

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$doc/upcoming/probe.$_",                                   $BYTES ) for @EXTS;
spit( "$doc/lazysite/backups/preinstall-20260811T000000Z.tar.gz", 'SNAPSHOT' );
spit( "$doc/upcoming/notes.md.brief", 'authoring intent, never public' );
spit( "$doc/sitemap.xml",             'PRIMARY SITE SITEMAP' );

# The extension list includes gz and xml on purpose: those are the two that make
# the /lazysite/ deny and the SM248 registry routes load-bearing rather than
# decorative. It excludes .bin and .dat, so the fixture reproduces the original
# split - some extensions on the list, some off it.
my $PORT = free_port();
my $conf = render(
    "$root/installers/hestia/lazysite-proxy.tpl",
    '%ip%'               => '127.0.0.1',
    '%proxy_port%'       => $PORT,
    '%web_port%'         => free_port(),           # nothing listens: proxied => 502
    '%domain_idn%'       => 'lazysite.test',
    '%alias_idn%'        => 'www.lazysite.test',
    '%domain%'           => 'lazysite.test',
    '%docroot%'          => $doc,
    '%home%'             => "$prefix/home",
    '%user%'             => 'siteuser',
    '%web_system%'       => 'apache2',
    '%proxy_extensions%' => 'jpg|jpeg|png|pdf|txt|gz|xml',
    '%%LOGDIR%%'         => "$prefix/logs/",
);
write_conf( $prefix, $conf, hestia => 1 );

my ( $rc, $out ) = start_nginx( $NGINX, $prefix );
is( $rc, 0, 'nginx starts with the shipped proxy template' ) or do {
    diag($out);
    done_testing();
    exit;
};

sub get { return http_get( $PORT, $_[0] ) }

# --- 1. no ACL store: the fast path is exactly as before ---------------------
# This half matters as much as the other. A proxy template that sent every
# static request to the engine would "fix" SM283 by making every site pay for a
# feature it never asked for, and nobody would notice until the load did.
subtest 'with NO ACL store, statics are served by nginx as before' => sub {
    for my $e (qw(png pdf txt)) {
        my ( $code, $body, $h ) = get("/upcoming/probe.$e");
        is( $code, 200,    ".$e is served directly by the front end" );
        is( $body, $BYTES, "and it is the file's bytes" );
        like( $h->{expires} // '', qr/\S/,
            '.. with a far-future Expires, which is the point of serving it here' );
    }
    # Off the extension list, so the proxy hands it on even with no ACL store.
    for my $e (qw(bin dat)) {
        my ($code) = get("/upcoming/probe.$e");
        is( $code, 502, ".$e is off the list and goes to the origin" );
    }
};

# --- 2. the protections that only exist at this layer ------------------------
subtest 'the engine directory is never served, whatever its extension' => sub {
    my ( $code, $body )
        = get('/lazysite/backups/preinstall-20260811T000000Z.tar.gz');
    is( $code, 403, 'a pre-install snapshot is refused' );
    unlike( $body, qr/SNAPSHOT/, 'and its bytes never appear' );

    # The control that makes the refusal mean something. Same extension, same
    # bytes, ordinary path: served. So the refusal above is about the PATH and
    # not about .tar.gz being unserveable, and the deny is doing the work.
    #
    # This replaced a bare pass() asserting that the `^~` modifier was what
    # refused it. Running the server showed that claim was false - the
    # static-extension regex is nested inside `location /`, so a URI matching
    # the longer `/lazysite/` prefix never reaches it, with or without `^~`.
    # A text match would have agreed with the wrong explanation indefinitely.
    spit( "$doc/public-archive.tar.gz", 'ORDINARY' );
    my ( $ok_code, $ok_body ) = get('/public-archive.tar.gz');
    is( $ok_code, 200,        'the same extension elsewhere is served normally' );
    is( $ok_body, 'ORDINARY', 'so gz is genuinely on the static list' );
};

subtest 'a .brief sidecar is refused' => sub {
    my ( $code, $body ) = get('/upcoming/notes.md.brief');
    is( $code, 403, 'refused at the proxy' );
    unlike( $body, qr/authoring intent/, 'and the body never appears' );
};

subtest 'the per-domain registries reach the engine even as real files' => sub {
    # SM248. sitemap.xml EXISTS on disk and xml is on the extension list, so
    # both the file test and the regex would serve it - it is the PRIMARY
    # site's, which on a multi-domain instance is the wrong site's. Only the
    # exact-match location outranks both.
    my ( $code, $body ) = get('/sitemap.xml');
    is( $code, 502, 'routed to the origin, not answered from disk' );
    unlike( $body, qr/PRIMARY SITE SITEMAP/,
        'the primary site\'s sitemap is not served to whoever asked' );
};

# --- 3. the measurement --------------------------------------------------
subtest 'with an ACL store, ALL FIVE extensions leave nginx' => sub {
    spit( "$doc/lazysite/auth/acls.json", '{"upcoming":{"read":["alice"]}}' );

    for my $e (@EXTS) {
        my ( $code, $body ) = get("/upcoming/probe.$e");
        is( $code, 502, ".$e goes to the engine, which holds the ACL" );
        unlike( $body, qr/\Q$BYTES\E/, ".$e serves no bytes from the docroot" );
    }

    # Stated as its own assertion because it is the filing's headline: the
    # answer must not depend on the extension. Four-of-five was the defect.
    my %codes;
    $codes{ ( get("/upcoming/probe.$_") )[0] }++ for @EXTS;
    is( scalar keys %codes, 1,
        'all five extensions get the SAME answer - a front end that decides '
            . 'this by file type cannot be made safe' );
};

# --- 4. and removing the store restores the fast path ------------------------
# The branch is a live file test, which is what makes protecting a path a pure
# content action: no vhost regeneration and no reload, ever. If that were not
# true the feature would be a deployment step in disguise.
subtest 'removing the ACL store restores direct serving with no reload' => sub {
    unlink "$doc/lazysite/auth/acls.json";
    my ( $code, $body ) = get('/upcoming/probe.png');
    is( $code, 200,    'served directly again' );
    is( $body, $BYTES, 'and it is the file' );
};

stop_nginx( $NGINX, $prefix );

done_testing();
