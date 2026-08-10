#!/usr/bin/perl
# SM268 H15: the GENERATED per-domain static rewrites must respect SM223.
#
# SM223 routes a static file through the engine when the site has an ACL store,
# and the ten shipped vhost templates do that for the primary docroot. The
# per-domain rules come from Lazysite::DomainRewrites instead, and were never
# updated - so on a multi-site instance, the shape SM151 exists for, every alias
# domain's own assets (images, PDFs, single-file apps) were served straight off
# disk with no auth decision able to reach them. t/lint/31 pinned the ten
# templates and did not look at the generator.
#
# t/lint/31 now pins the generated text. This runs it through REAL Apache,
# because the finding was reproduced that way and a rewrite block that reads
# correctly can still be dead: the serve rule ends in [L], the exempt list can
# swallow the path, a RewriteCond can be scoped to the wrong request. The engine
# is a stub CGI that announces itself, so "who answered" is unambiguous.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
plan skip_all => 'apache2 not installed' unless $APACHE;

my $MODS = '/usr/lib/apache2/modules';
plan skip_all => 'apache2 modules not found' unless -f "$MODS/mod_rewrite.so";

require Lazysite::DomainRewrites;

my $PORT = 8817;
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/docroot/sites/foo/private", "$d/docroot/lazysite/auth",
    "$d/cgi-bin", "$d/logs" );

sub spit {
    my ( $p, $c, $mode ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}

# The file the alias domain owns, and which the ACL is meant to govern.
spit( "$d/docroot/sites/foo/private/aliasonly.pdf", "ALIAS-ONLY-SECRET\n" );

# The stub engine. Standing in for lazysite-auth.pl, which validates the cookie
# and execs the processor; all this test needs to know is that the request
# reached it rather than being answered off disk.
#
# It sits BESIDE the docroot, not inside it, because that is what the Hestia
# templates produce and it is the layout that exposed the second half of this
# finding: in vhost context mod_rewrite treats a substitution beginning with /
# as a local path and prefixes DocumentRoot before mod_alias ever sees it
# (rewrite:trace2 "prefixed with document_root"), so a rule without the PT flag
# resolves to <docroot>/cgi-bin/lazysite-auth.pl and 404s. Reachable only
# through ScriptAlias is the realistic case, so that is what this asserts.
spit( "$d/cgi-bin/lazysite-auth.pl", <<'CGI', 0755 );
#!/usr/bin/perl
print "Content-Type: text/plain\r\n\r\nROUTED-TO-ENGINE\n";
CGI

my $rewrites = Lazysite::DomainRewrites::apache_snippet(
    [ { host => 'alias.test', root => 'sites/foo' } ] );

spit( "$d/httpd.conf", <<"CONF" );
ServerRoot "$d"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$d/httpd.pid"
ErrorLog "$d/logs/error.log"
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule authz_host_module $MODS/mod_authz_host.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule dir_module $MODS/mod_dir.so
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
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
$rewrites
CONF

sub apache {
    my ($verb) = @_;
    return system( $APACHE, '-f', "$d/httpd.conf", '-k', $verb ) == 0;
}

sub fetch {
    my ($path) = @_;
    my $out = qx{curl -s --max-time 10 --path-as-is -H 'Host: alias.test' http://127.0.0.1:$PORT$path 2>&1};
    return $out // '';
}

unless ( apache('start') ) {
    my $err = '';
    if ( open my $fh, '<', "$d/logs/error.log" ) { local $/; $err = <$fh>; close $fh }
    plan skip_all => "apache2 would not start here: $err";
}
END { apache('stop') if $APACHE && -f "$d/httpd.pid" }

# Give it a moment to bind.
for ( 1 .. 50 ) {
    last if fetch('/private/aliasonly.pdf') =~ /\S/;
    sleep 0.1;
}

subtest 'with no ACL store the domain serves its own file directly' => sub {
    like( fetch('/private/aliasonly.pdf'), qr/ALIAS-ONLY-SECRET/,
        'a site with no ACLs pays nothing and keeps direct static serving - '
            . 'without this the next subtest would pass on a block that simply '
            . 'never serves anything' );
};

subtest 'an ACL store routes the domain statics through the engine' => sub {
    spit( "$d/docroot/lazysite/auth/acls.json",
        '{"sites/foo/private":{"read":["@editors"]}}' );

    my $out = fetch('/private/aliasonly.pdf');
    like( $out, qr/ROUTED-TO-ENGINE/,
        'the engine answered, so an ACL decision can reach the file' );
    unlike( $out, qr/ALIAS-ONLY-SECRET/,
        'and Apache did not hand out the bytes on its way past - this is the '
            . 'finding, reproduced against real Apache' );
};

subtest 'the management surfaces are still exempt' => sub {
    my $out = fetch('/cgi-bin/lazysite-auth.pl');
    like( $out, qr/ROUTED-TO-ENGINE/,
        'the rewrite target cannot match itself into a loop' );
};

done_testing();
