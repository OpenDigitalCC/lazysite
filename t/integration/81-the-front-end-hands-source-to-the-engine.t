#!/usr/bin/perl
# SM797, against real servers: the SHIPPED front-end configs hand the engine's
# source types to the engine, and nothing else.
#
# t/lint/131 pins the list in every template. What a text match cannot see is
# whether the rule is live: whether mod_rewrite reaches it before a [L] rule or
# FallbackResource answers, whether the /cgi-bin/ and /dav exemptions hold (a
# CGI endpoint is a .pl, a DAV write names a .md), whether [NC] is there for
# README.MD, whether nginx picks this location over the script ones. SM268 H15
# was a rewrite block that read correctly and was dead. So each config is
# rendered whole and driven, with stub surfaces that name themselves.
#
# The site under test has NO ACL store, on purpose: that is the case where the
# web server serves every existing file itself, and so the case this closes.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(repo_root site_tempdir);
use NginxHarness qw(nginx_bin render write_conf free_port http_get start_nginx stop_nginx);

my $root = repo_root();

sub spit {
    my ( $p, $t, $mode ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}

# The same docroot shape for both servers: things that are source, things that
# are assets, and the one exception the list makes.
sub fill_docroot {
    my ($doc) = @_;
    spit( "$doc/about.md",       "---\ntitle: About\n---\nPAGE-SOURCE\n" );
    spit( "$doc/README.MD",      "UPPERCASE-SOURCE\n" );
    spit( "$doc/config.bak",     "BACKUP-SECRET\n" );
    spit( "$doc/notes.md.brief", "BRIEF-SECRET\n" );
    spit( "$doc/site.key",       "KEY-SECRET\n" );
    spit( "$doc/logo.png",       "PNGBYTES\n" );
    spit( "$doc/data.json",      "{\"JSON\":\"PUBLIC\"}\n" );
    spit( "$doc/old.shtml",      "<p>SSI:<!--#echo var=\"DOCUMENT_NAME\" --></p>\n" );
    spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
    return;
}

my @SOURCE = (
    [ '/about.md',       'PAGE-SOURCE',      'a page by its source name' ],
    [ '/README.MD',      'UPPERCASE-SOURCE', 'the same type in upper case' ],
    [ '/config.bak',     'BACKUP-SECRET',    'a backup' ],
    [ '/notes.md.brief', 'BRIEF-SECRET',     'an authoring sidecar' ],
    [ '/site.key',       'KEY-SECRET',       'a key' ],
);

# --- Apache: installers/apache/vhost-cgi.conf.example, whole ------------------

subtest 'Apache, the shipped CGI vhost' => sub {
    my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
    my $MODS   = '/usr/lib/apache2/modules';
    plan skip_all => 'apache2 not installed' unless $APACHE && -f "$MODS/mod_rewrite.so";

    my $d = site_tempdir( leaf => 'docroot' ) =~ s{/docroot\z}{}r; # the docroot is $d/docroot
    make_path( "$d/cgi-bin", "$d/logs" );
    fill_docroot("$d/docroot");

    # The engine entry names itself and what it was asked for. The other script
    # surfaces name themselves, so a rerouted CGI call cannot pass as the engine.
    spit( "$d/cgi-bin/lazysite-auth.pl", <<'CGI', 0755 );
#!/usr/bin/perl
print "Content-Type: text/plain\r\n\r\nENGINE uri=$ENV{REQUEST_URI}\n";
CGI
    for my $s (qw(dav oauth)) {
        spit( "$d/cgi-bin/lazysite-$s.pl", <<"CGI", 0755 );
#!/usr/bin/perl
print "Content-Type: text/plain\\r\\n\\r\\nSURFACE=$s\\n";
CGI
    }

    my $PORT = free_port();
    my $vhost = do { open my $fh, '<', "$root/installers/apache/vhost-cgi.conf.example" or die $!; local $/; <$fh> };
    $vhost =~ s/__DOMAIN__/front.test/g;
    $vhost =~ s/__DOCROOT__/$d\/docroot/g;
    $vhost =~ s/__CGIBIN__/$d\/cgi-bin/g;
    $vhost =~ s/__PORT__/$PORT/g;
    $vhost =~ s/\$\{APACHE_LOG_DIR\}/$d\/logs/g;

    my @mods = qw(mpm_prefork authz_core authz_host alias mime dir cgi env rewrite
        headers setenvif include log_config filter);
    my $load = join '', map { "LoadModule ${_}_module $MODS/mod_$_.so\n" } grep { -f "$MODS/mod_$_.so" } @mods;
    spit( "$d/httpd.conf", <<"CONF" );
ServerRoot "$d"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$d/httpd.pid"
ErrorLog "$d/logs/error.log"
$load
TypesConfig /etc/mime.types
LogFormat "%h %r %>s" combined
$vhost
CONF

    my $apache = sub { return system( $APACHE, '-f', "$d/httpd.conf", '-k', $_[0] ) == 0 };
    unless ( $apache->('start') ) {
        my $err = do { open my $fh, '<', "$d/logs/error.log" or return ''; local $/; <$fh> } // '';
        fail("apache2 is installed and would not start with the shipped vhost: $err");
        return;
    }
    my $get = sub { my ( undef, $body ) = http_get( $PORT, $_[0], host => 'front.test' ); return $body };
    for ( 1 .. 50 ) { last if $get->('/logo.png') =~ /\S/; sleep 0.1 }

    # THE CANARY: the rig must be seen serving a static itself, or every
    # "went to the engine" below passes against a server that routes everything.
    like( $get->('/logo.png'), qr/PNGBYTES/, 'an asset is served by Apache itself' );
    like( $get->('/data.json'), qr/"JSON":"PUBLIC"/, 'and so is JSON, which the engine also serves' );

    for my $c (@SOURCE) {
        my ( $url, $secret, $what ) = @$c;
        my $out = $get->($url);
        like( $out, qr/ENGINE uri=\Q$url\E/, "$what goes to the engine ($url)" );
        unlike( $out, qr/\Q$secret\E/, '... and Apache did not hand out the file' );
    }

    # The exception: a legacy SSI page is Apache's, and it EXPANDS it - which is
    # why the engine's refusal of .shtml is not carried here.
    my $ssi = $get->('/old.shtml');
    like( $ssi, qr/SSI:old\.shtml/, 'a legacy .shtml page is served and expanded by Apache' );

    # The exemptions: a CGI endpoint is a .pl and a DAV write names a .md.
    like( $get->('/cgi-bin/lazysite-oauth.pl'), qr/SURFACE=oauth/, 'a /cgi-bin/ script still reaches itself' );
    like( $get->('/dav/content/about.md'), qr/SURFACE=dav/, 'a /dav request still reaches DAV' );
    unlike( $get->('/lazysite/lazysite.conf'), qr/site_name|ENGINE/, 'and /lazysite/ keeps its own deny' );

    $apache->('stop');
};

# --- nginx: installers/nginx/vhost-cgi.conf.example, whole --------------------
#
# No backend listens, so 502 means "nginx handed it on" and 200 means "nginx
# answered it itself" - t/integration/42's trick. But a 502 does not say WHICH
# location handed it on, and a /cgi-bin/ script swallowed by the hand-off would
# 502 exactly as it does at its own location. So each location gets its own
# dead socket, and nginx's error log names the one it tried.

subtest 'nginx, the shipped CGI vhost' => sub {
    my $NGINX = nginx_bin();
    plan skip_all => 'nginx not installed' unless $NGINX;

    my $prefix = site_tempdir( leaf => 'docroot' ) =~ s{/docroot\z}{}r;
    fill_docroot("$prefix/docroot");
    my $PORT = free_port();
    my $conf = render(
        "$root/installers/nginx/vhost-cgi.conf.example",
        '__DOMAIN__'  => 'front.test',
        '__DOCROOT__' => "$prefix/docroot",
        '__CGIBIN__'  => "$prefix/cgi-bin",
        '__PORT__'    => $PORT,
        '%%LOGDIR%%'  => "$prefix/logs/",
    );
    my %sock = ( cgi => qr{location ~ \^/cgi-bin/}, dav => qr{location ~ \^/dav}, engine => qr{location \@lazysite} );
    for my $name ( sort keys %sock ) {
        my $re = $sock{$name};
        my $n = $conf =~ s#((?:$re)[^\n]*[{].*?)unix:/run/fcgiwrap[.]socket#$1unix:$prefix/$name.sock#s;
        ok( $n, "the $name location has its own socket" );
    }
    $conf =~ s{unix:/run/fcgiwrap\.socket}{unix:$prefix/other.sock}g;
    write_conf( $prefix, $conf );
    my ( $rc, $out ) = start_nginx( $NGINX, $prefix );
    is( $rc, 0, 'nginx starts with the shipped vhost' ) or do { diag($out); return };

    # The server block's own error_log, which render() moved into the prefix.
    my $log = "$prefix/logs/front.test.error.log";
    ok( -f $log, 'the vhost\'s error log is where the socket names will be read' );
    my $get = sub {
        my $from = -s $log // 0;
        my ( $code, $body ) = http_get( $PORT, $_[0], host => 'front.test' );
        my $tail = '';
        if ( open my $fh, '<', $log ) { seek $fh, $from, 0; local $/; $tail = <$fh> // ''; close $fh }
        my ($via) = $tail =~ m{unix:\Q$prefix\E/(\w+)\.sock};
        return ( $code, $body, $via // '' );
    };

    my ( $code, $body ) = $get->('/logo.png');
    is( $code, 200, 'the canary: an asset is served by nginx itself' );
    like( $body, qr/PNGBYTES/, '... its bytes' );

    my $via;
    for my $c (@SOURCE) {
        my ( $url, $secret, $what ) = @$c;
        ( $code, $body, $via ) = $get->($url);
        is( $code, 502,      "$what is handed on, not served ($url)" );
        is( $via,  'engine', '... to the engine' );
        unlike( $body, qr/\Q$secret\E/, '... and nginx did not hand out the file' );
    }

    ( $code, $body, $via ) = $get->('/cgi-bin/lazysite-oauth.pl');
    is( $via, 'cgi', 'a /cgi-bin/ script reaches its own location, not the engine' );
    ( $code, $body, $via ) = $get->('/dav/content/about.md');
    is( $via, 'dav', 'a /dav request reaches DAV, not the engine' );

    stop_nginx( $NGINX, $prefix );
};

done_testing();
