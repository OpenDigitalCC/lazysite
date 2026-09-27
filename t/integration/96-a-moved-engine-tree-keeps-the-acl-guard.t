#!/usr/bin/perl
# SM850 / N13-44: a site whose engine tree moved out of the docroot keeps the
# front end's ACL guard.
#
# Every shipped front end routes an existing static file through the engine
# when the site has an ACL store, and tests for the store at
# <docroot>/lazysite/auth/acls.json. A site migrated with migrate-engine-tree
# keeps it at <docroot>-lazysite/auth/acls.json, so the test never matched and
# the front end served every static file straight off disk, with no ACL decision
# able to reach it (SM223's whole condition). Protected CONTENT is safe - it is
# moved into the private store - but anything left in the served tree under a
# rule was handed out, and the guard said nothing about having gone inert.
#
# Proved here on the real servers, against the guard block as each shipped file
# carries it: real Apache for the eight Apache front ends, real nginx for the
# Hestia proxy template. Reproduced before the fix: every migrated case served
# the bytes.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path  qw(make_path remove_tree);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(repo_root site_tempdir);
use NginxHarness  qw(nginx_bin render write_conf free_port http_get start_nginx stop_nginx);
use ApacheHarness qw(start_apache_conf stop_apache_conf);

my $root = repo_root();

sub spit {
    my ( $p, $c, $mode ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

my $SECRET = 'LEFT-IN-THE-SERVED-TREE';
my $ACLS   = '{"private":{"read":["@editors"]}}';

# --- Apache: each shipped file's own guard block -----------------------------
subtest 'Apache' => sub {
    my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
    my $MODS   = '/usr/lib/apache2/modules';
    plan skip_all => 'apache2 not installed' unless $APACHE && -f "$MODS/mod_rewrite.so";

    my @files = qw(
        installers/hestia/lazysite-app.tpl   installers/hestia/lazysite-app.stpl
        installers/hestia/lazysite-cgi.tpl   installers/hestia/lazysite-cgi.stpl
        installers/hestia/lazysite-fcgi.tpl  installers/hestia/lazysite-fcgi.stpl
        installers/apache/vhost-cgi.conf.example installers/apache/vhost-fcgi.conf.example
    );
    # SM908: A PORT PER ITERATION. One port was taken here and then started and
    # stopped on eight times, so every iteration depended on the previous
    # apache's listening socket being gone - which the wait below does not
    # establish, because it waits for the PID FILE. Measured on an idle host the
    # port came back within 0.1s four times out of four, so this is not the cause
    # of the 27 September failure and no claim is made that it was; it is one
    # fewer thing the next iteration depends on, at the cost of one syscall.
    for my $rel (@files) {
        my $PORT = free_port();
        my ($block) = slurp("$root/$rel")
            =~ m{^([ \t]*RewriteCond %\{DOCUMENT_ROOT\}/lazysite/auth/acls\.json.*?^[ \t]*RewriteRule \^/\$ /cgi-bin/lazysite-auth\.pl \[PT,L\][ \t]*$)}ms;
        ok( $block, "$rel: the ACL guard block was found" ) or next;

        # The docroot one level down, so the moved tree beside it is inside
        # what CLEANUP removes.
        my $d = dirname( site_tempdir( leaf => 'docroot' ) );
        make_path( "$d/docroot/private", "$d/cgi-bin", "$d/logs" );
        spit( "$d/docroot/private/brief.pdf", $SECRET );
        spit( "$d/cgi-bin/lazysite-auth.pl", "#!/usr/bin/perl\nprint \"Content-Type: text/plain\\r\\n\\r\\nROUTED-TO-ENGINE\\n\";\n", 0755 );
        spit( "$d/httpd.conf", <<"CONF" );
ServerRoot "$d"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$d/httpd.pid"
ErrorLog "$d/logs/error.log"
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule cgi_module $MODS/mod_cgi.so
LoadModule rewrite_module $MODS/mod_rewrite.so
TypesConfig /etc/mime.types
DocumentRoot "$d/docroot"
ScriptAlias /cgi-bin/ "$d/cgi-bin/"
<Directory "$d/cgi-bin">
    Options +ExecCGI
    Require all granted
</Directory>
<Directory "$d/docroot">
    Require all granted
</Directory>
RewriteEngine On
$block
CONF
        # SM908: apache's OWN words on a failure to start. This ran a bare
        # system() and reported the ErrorLog, and apache writes neither when it
        # refuses a configuration - it says so on STDERR and never opens the log.
        # So the 27 September gate run reported "apache would not start with its
        # guard block: " and nothing after the colon, and the cause of the only
        # failure in 14,833 tests could not be determined from the artefact. The
        # shared helper captures it; the ErrorLog is still shown when there is one,
        # because a start that fails AFTER opening the log puts its reason there.
        my ( $rc, $said ) = start_apache_conf("$d/httpd.conf");
        if ( $rc != 0 ) {
            my $log = -f "$d/logs/error.log" ? slurp("$d/logs/error.log") : '(no error log written)';
            fail("$rel: apache would not start with its guard block");
            diag("apache said: $said");
            diag("error log: $log");
            next;
        }
        my $get = sub { return scalar qx{curl -s --max-time 10 http://127.0.0.1:$PORT/private/brief.pdf 2>&1} };
        my $out = '';
        for ( 1 .. 50 ) { $out = $get->(); last if $out =~ /\S/; sleep 0.1 }

        like( $out, qr/\Q$SECRET\E/, "$rel: with no ACL store the file is served directly (the canary)" );

        make_path("$d/docroot-lazysite/auth");
        spit( "$d/docroot-lazysite/auth/acls.json", $ACLS );
        $out = $get->();
        like( $out, qr/ROUTED-TO-ENGINE/, "$rel: a MOVED engine tree's ACL store routes the file through the engine" );
        unlike( $out, qr/\Q$SECRET\E/, "$rel: and the bytes are not handed out on the way past" );

        remove_tree("$d/docroot-lazysite");
        make_path("$d/docroot/lazysite/auth");
        spit( "$d/docroot/lazysite/auth/acls.json", $ACLS );
        my $in = $get->();
        like( $in, qr/ROUTED-TO-ENGINE/, "$rel: and a tree inside the docroot still does" ) or diag $in, eval { slurp("$d/logs/error.log") };

        stop_apache_conf("$d/httpd.conf");
        for ( 1 .. 50 ) { last unless -f "$d/httpd.pid"; sleep 0.1 }
    }
};

# --- nginx: the Hestia proxy template ----------------------------------------
subtest 'nginx, the Hestia proxy template' => sub {
    my $NGINX = nginx_bin();
    plan skip_all => 'nginx not installed' unless $NGINX;

    my $doc    = site_tempdir( leaf => 'docroot' );
    my $prefix = dirname($doc);
    make_path( "$doc/private", "$prefix/logs", "$prefix/home/siteuser/conf/web/lazysite.test" );
    spit( "$doc/private/brief.pdf", $SECRET );
    my $PORT = free_port();
    write_conf(
        $prefix,
        render(
            "$root/installers/hestia/lazysite-proxy.tpl",
            '%ip%'               => '127.0.0.1',
            '%proxy_port%'       => $PORT,
            '%web_port%'         => free_port(),         # nothing listens: proxied => 502
            '%domain_idn%'       => 'lazysite.test',
            '%alias_idn%'        => 'www.lazysite.test',
            '%domain%'           => 'lazysite.test',
            '%docroot%'          => $doc,
            '%home%'             => "$prefix/home",
            '%user%'             => 'siteuser',
            '%web_system%'       => 'apache2',
            '%proxy_extensions%' => 'jpg|jpeg|png|pdf|txt|gz|xml|md',
            '%%LOGDIR%%'         => "$prefix/logs/",
        ),
        hestia => 1
    );
    my ( $rc, $out ) = start_nginx( $NGINX, $prefix );
    is( $rc, 0, 'nginx starts with the shipped proxy template' ) or return diag $out;

    my ( $code, $body ) = http_get( $PORT, '/private/brief.pdf' );
    is( $code, 200, 'with no ACL store the file is served by nginx (the canary)' );

    make_path("$doc-lazysite/auth");
    spit( "$doc-lazysite/auth/acls.json", $ACLS );
    ( $code, $body ) = http_get( $PORT, '/private/brief.pdf' );
    is( $code, 502, 'a MOVED engine tree\'s ACL store sends the file to the origin' );
    unlike( $body // '', qr/\Q$SECRET\E/, 'and nginx does not hand out the bytes' );

    stop_nginx( $NGINX, $prefix );
};

done_testing();
