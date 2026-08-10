#!/usr/bin/perl
# SM139 webserver glue: static checks that keep the lazysite-apache and
# lazysite-nginx packages honest without a live web server. The shipped
# vhost templates parse (balanced sections/braces, one page-routing entry
# point, the trust-header strip, the session carve-out, the pool socket
# matching the lazysite@.service/pool-launcher convention), every template
# placeholder is consumed by its vhost tool, the tools behave at the CLI
# edge (--help, unknown verbs, validation before privilege, refuse
# overwrite, remove) via the LAZYSITE_*_SITES_DIR test overrides, the
# `lazysite demo` verb round-trips an install without serving
# (LAZYSITE_DEMO_NO_SERVE), and debian/ declares the packaging relations.
use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard);

my $ROOT = repo_root();
my $POOL = "$ROOT/tools/lazysite-pool.pl";
my $UNIT = "$ROOT/debian/lazysite\@.service";
my $CLI  = "$ROOT/tools/lazysite-cli.pl";

my %SERVER = (
    apache => {
        tool     => "$ROOT/tools/lazysite-apache-vhost.pl",
        tpl_dir  => "$ROOT/installers/apache",
        env_dir  => 'LAZYSITE_APACHE_SITES_DIR',
        name     => 'lazysite-apache-vhost',
        share    => 'usr/share/lazysite-apache',
    },
    nginx => {
        tool     => "$ROOT/tools/lazysite-nginx-vhost.pl",
        tpl_dir  => "$ROOT/installers/nginx",
        env_dir  => 'LAZYSITE_NGINX_SITES_DIR',
        name     => 'lazysite-nginx-vhost',
        share    => 'usr/share/lazysite-nginx',
    },
);

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

# Run a vhost tool; returns (exit_code, combined_output). The sites-dir
# override is cleared unless the caller sets it, so the default-/etc (and
# with it the root-refusal) path is what untested invocations exercise.
sub run_tool {
    my ( $server, $env, @args ) = @_;
    local %ENV = %ENV;
    delete $ENV{LAZYSITE_APACHE_SITES_DIR};
    delete $ENV{LAZYSITE_NGINX_SITES_DIR};
    $ENV{$_} = $env->{$_} for keys %$env;
    my $cmd = join ' ', map { quotemeta } $^X, $SERVER{$server}{tool}, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# --- the socket-path convention, from the sources that define it -------------
my $pool_src = slurp($POOL);
my ($rundir) = $pool_src =~ /rundir\s*=>\s*'([^']+)'/;
ok( $rundir, "pool launcher declares a default run dir ($rundir)" );
my ($rtd) = slurp($UNIT) =~ /^RuntimeDirectory=(\S+)/m;
is( "/run/$rtd", $rundir, 'unit RuntimeDirectory= matches the launcher run dir' );

# --- templates: placeholders, structure, load-bearing directives -------------
my @placeholders = qw(__DOMAIN__ __DOCROOT__ __CGIBIN__ __PORT__);

for my $server ( sort keys %SERVER ) {
    my $s        = $SERVER{$server};
    my $tool_src = slurp( $s->{tool} );
    for my $pattern (qw(cgi fcgi)) {
        my $path = "$s->{tpl_dir}/vhost-$pattern.conf.example";
        subtest "$server vhost-$pattern" => sub {
            ok( -f $path, 'template shipped' ) or return;
            my $text = slurp($path);

            # Placeholder integrity: the template uses ONLY placeholders
            # the tool fills (the tool carries them literally in its
            # %fill map), and every documented placeholder is present.
            my %used = map { $_ => 1 } $text =~ /(__[A-Z]+__)/g;
            for my $ph ( sort keys %used ) {
                ok( index( $tool_src, "'$ph'" ) >= 0,
                    "$ph is consumed by $s->{name}" );
            }
            for my $ph (@placeholders) {
                ok( $used{$ph}, "template uses $ph" );
            }

            # Client-supplied trust headers are stripped at the door.
            my $strip_re
                = $server eq 'apache'
                ? qr/^\s*RequestHeader unset X-Remote-User/m
                : qr/^\s*fastcgi_param\s+HTTP_X_REMOTE_USER\s+"";/m;
            like( $text, $strip_re, 'strips X-Remote-User' );

            if ( $server eq 'apache' ) {
                # Balanced Apache container sections.
                for my $tag (qw(VirtualHost Directory Location FilesMatch IfModule)) {
                    my $open  = () = $text =~ /^\s*<\Q$tag\E[\s>"]/mg;
                    my $close = () = $text =~ m{^\s*</\Q$tag\E>}mg;
                    is( $open, $close, "balanced <$tag> sections ($open)" );
                }
                # Exactly one FallbackResource: the single page-routing
                # entry point.
                my @fb = $text =~ /^\s*FallbackResource\s+(\S+)/mg;
                is( scalar @fb, 1, 'exactly one FallbackResource' );
                like( $text, qr{RewriteRule \^/cgi-bin/.*lazysite-auth\.pl}m,
                    'cgi-bin scripts fronted by the auth wrapper' );
                if ( $pattern eq 'cgi' ) {
                    is( $fb[0], '/cgi-bin/lazysite-auth.pl',
                        'CGI pattern: FallbackResource -> the auth wrapper' );
                    unlike( $text, qr/proxy:unix:/, 'no pool proxying' );
                }
                else {
                    is( $fb[0], '/lazysite-pool',
                        'FCGI pattern: FallbackResource -> the pool location' );
                    like( $text,
                        qr{SetHandler\s+"proxy:unix:\Q$rundir\E/__DOMAIN__\.sock\|fcgi://localhost/"},
                        "pool socket is $rundir/__DOMAIN__.sock via mod_proxy_fcgi" );
                    like( $text, qr/^\s*RewriteCond %\{HTTP_COOKIE\} lazysite_auth=/m,
                        'session cookie carve-out to the CGI auth wrapper' );
                }
            }
            else {
                # Balanced nginx braces, comments stripped first.
                ( my $code = $text ) =~ s/^\s*#.*$//mg;
                my $open  = () = $code =~ /\{/g;
                my $close = () = $code =~ /\}/g;
                is( $open, $close, "balanced braces ($open)" );
                like( $text, qr/^\s*server\s*\{/m,   'has a server block' );
                like( $text, qr/^\s*try_files \$uri \@lazysite;/m,
                    'try_files falls through to @lazysite (FallbackResource equivalent)' );
                like( $text, qr/^\s*location \@lazysite \{/m, 'has the @lazysite location' );
                # The auth wrapper fronts the real CGI endpoints.
                like( $text, qr{^\s*location = /cgi-bin/lazysite-processor\.pl \{}m,
                    'processor fronted by the auth wrapper' );
                like( $text, qr{^\s*location = /cgi-bin/lazysite-manager-api\.pl \{}m,
                    'manager-api fronted by the auth wrapper' );
                like( $text, qr{SCRIPT_FILENAME\s+__CGIBIN__/lazysite-auth\.pl;}m,
                    'auth wrapper is a SCRIPT_FILENAME target' );
                # index.html must NOT be an index (homepage cache bypass).
                unlike( $text, qr/^\s*index[^;]*index\.html/m,
                    'index.html is not an nginx index' );
                if ( $pattern eq 'cgi' ) {
                    unlike( $text, qr{fastcgi_pass unix:\Q$rundir\E/}m,
                        'CGI pattern has no pool socket' );
                }
                else {
                    like( $text, qr{fastcgi_pass unix:\Q$rundir\E/__DOMAIN__\.sock;}m,
                        "pool socket is $rundir/__DOMAIN__.sock via fastcgi_pass" );
                    like( $text, qr/if \(\$cookie_lazysite_auth\)/,
                        'session cookie carve-out to the CGI auth wrapper' );
                    like( $text, qr/^\s*internal;/m,
                        'carve-out location is internal-only' );
                }
            }
        };
    }
}

# --- vhost tools: CLI edge behaviour ------------------------------------------
for my $server ( sort keys %SERVER ) {
    my $s = $SERVER{$server};
    subtest "$s->{name} dispatch and validation" => sub {
        my ( $rc, $out ) = run_tool( $server, {}, '--help' );
        is( $rc, 0, '--help: exit 0' );
        like( $out, qr/Usage: \Q$s->{name}\E VERB/, 'usage shown' );
        like( $out, qr/^\s{2}$_( |$)/m, "usage lists '$_'" ) for qw(add remove);

        ( $rc, $out ) = run_tool( $server, {}, 'frobnicate' );
        is( $rc, 2, 'unknown verb: exit 2' );
        like( $out, qr/unknown verb 'frobnicate'/, 'unknown verb named' );

        ( $rc, $out ) = run_tool( $server, {} );
        is( $rc, 2, 'no verb: exit 2' );

        # Input validation fires BEFORE the root gate.
        ( $rc, $out ) = run_tool( $server, {}, 'add', 'bad domain!', '--docroot', '/tmp' );
        is( $rc, 1, 'add with a bad domain: refused' );
        like( $out, qr/invalid domain/, 'names the domain problem' );

        ( $rc, $out ) = run_tool( $server, {}, 'add', 'ok.example' );
        is( $rc, 1, 'add without --docroot: refused' );
        like( $out, qr/--docroot/, 'names the missing option' );

      SKIP: {
            skip 'running as root: cannot test the non-root refusal', 4 if $> == 0;
            my $site = tempdir( CLEANUP => 1 );
            make_path("$site/public_html", "$site/cgi-bin");
            ( $rc, $out ) = run_tool( $server, {},
                'add', 'ok.example', '--docroot', "$site/public_html" );
            is( $rc, 1, 'add as non-root (no override): refused' );
            like( $out, qr/must run as root/, 'refusal explains the root design' );
            ( $rc, $out ) = run_tool( $server, {}, 'remove', 'ok.example' );
            is( $rc, 1, 'remove as non-root (no override): refused' );
            like( $out, qr/must run as root/, 'refusal explains the root design' );
        }
    };

    subtest "$s->{name} render round-trip (sites-dir override)" => sub {
        my $sites = tempdir( CLEANUP => 1 );
        my $site  = tempdir( CLEANUP => 1 );
        make_path( "$site/public_html", "$site/cgi-bin" );
        my $env = { $s->{env_dir} => $sites };

        for my $mode ( [], ['--fcgi'] ) {
            my $label = @$mode ? 'fcgi' : 'cgi';
            my ( $rc, $out ) = run_tool( $server, $env, 'add', 'demo.example',
                '--docroot', "$site/public_html", '--port', '8081', @$mode,
                ( @$mode ? '--force' : () ) );
            is( $rc, 0, "add ($label): exit 0" ) or diag($out);
            my $conf = "$sites/demo.example.conf";
            ok( -f $conf, 'vhost file rendered' );
            my $text = slurp($conf);
            unlike( $text, qr/__[A-Z]+__/, 'no placeholder left unrendered' );
            like( $text, qr/demo\.example/,          'domain substituted' );
            like( $text, qr{\Q$site\E/public_html},  'docroot substituted' );
            like( $text, qr{\Q$site\E/cgi-bin},      'default cgibin derived from the docroot' );
            like( $text, qr/8081/,                   'port substituted' );
            like( $out,  qr/never runs|printed|Next steps/i, 'next steps printed' );
            if ($label eq 'fcgi') {
                like( $text, qr{\Q$rundir\E/demo\.example\.sock},
                    'rendered pool socket follows the convention' );
                like( $out, qr/lazysite\@demo\.example/, 'pool enablement reminder printed' );
            }
        }

        # Refuse-overwrite without --force.
        my ( $rc, $out ) = run_tool( $server, $env, 'add', 'demo.example',
            '--docroot', "$site/public_html" );
        is( $rc, 1, 'second add without --force: refused' );
        like( $out, qr/--force/, 'refusal points at --force' );

        # remove deletes the vhost file only.
        ( $rc, $out ) = run_tool( $server, $env, 'remove', 'demo.example' );
        is( $rc, 0, 'remove: exit 0' );
        ok( !-e "$sites/demo.example.conf", 'vhost file gone' );
        like( $out, qr/NOT touched/, 'remove states content is untouched' );
        ok( -d "$site/public_html", 'site content untouched' );

        ( $rc, $out ) = run_tool( $server, $env, 'remove', 'demo.example' );
        is( $rc, 1, 'remove again: nothing to remove' );
    };
}

# --- lazysite demo -------------------------------------------------------------
subtest 'demo verb' => sub {
    # install.pl needs a release manifest beside it (same on-demand build
    # as t/tools/28-cli.t).
    #
    # SM269 phase 1: the guard is taken HERE rather than at file scope, because
    # only this subtest touches the shared repo-root manifest - holding it for
    # the whole file would serialise the rest of a slow test for nothing. It
    # releases when the subtest's scope ends.
    my $mf_guard = repo_manifest_guard();
    my $manifest    = "$ROOT/release-manifest.json";
    my $we_built_it = 0;
    if ( !-f $manifest ) {
        system( $^X, "$ROOT/tools/build-manifest.pl" ) == 0
            or return fail('cannot build release-manifest.json');
        $we_built_it = 1;
    }

    my $run = sub {
        my ( $env, @args ) = @_;
        local %ENV = %ENV;
        delete $ENV{LAZYSITE_CLI_FAKE_ROOT};
        delete $ENV{LAZYSITE_DEMO_NO_SERVE};
        $ENV{$_} = $env->{$_} for keys %$env;
        my $cmd = join ' ', map { quotemeta } $^X, $CLI, 'demo', @args;
        my $out = `$cmd 2>&1`;
        return ( $? >> 8, $out );
    };

    # Root refusal (the TEST-ONLY fake-root override).
    my ( $rc, $out ) = $run->( { LAZYSITE_CLI_FAKE_ROOT => 1 } );
    is( $rc, 1, 'demo as (fake) root: refused' );
    like( $out, qr/refusing to run 'demo' as root/, 'refusal names the verb' );

    ( $rc, $out ) = $run->( {}, '--port', 'nonsense' );
    isnt( $rc, 0, 'demo with a non-numeric port: refused' );

    # Round-trip: install happens, the server exec is stopped by the
    # TEST-ONLY LAZYSITE_DEMO_NO_SERVE seam.
    my $dir = tempdir( CLEANUP => 1 );
    ( $rc, $out ) = $run->( { LAZYSITE_DEMO_NO_SERVE => 1 },
        '--dir', "$dir/demo", '--port', '8099' );
    is( $rc, 0, 'demo --dir: exit 0' ) or diag($out);
    ok( -f "$dir/demo/public_html/lazysite/.install-state.json",
        'fresh install landed in the demo docroot' );
    ok( -f "$dir/demo/cgi-bin/lazysite-processor.pl", 'cgi-bin populated' );
    like( $out, qr{http://localhost:8099/},   'URL printed' );
    like( $out, qr{rm -rf \Q$dir\E/demo},     'removal hint printed' );
    like( $out, qr/would exec: .*lazysite-server\.pl/, 'no-serve seam reports the exec' );

    # Re-run reuses the site instead of reinstalling.
    ( $rc, $out ) = $run->( { LAZYSITE_DEMO_NO_SERVE => 1 }, '--dir', "$dir/demo" );
    is( $rc, 0, 'demo re-run: exit 0' );
    like( $out, qr/reusing/, 'existing demo site reused' );

    unlink $manifest if $we_built_it;
};

# --- debian packaging declares the relations ----------------------------------
subtest 'debian/ metadata' => sub {
    my $control = slurp("$ROOT/debian/control");
    for my $server ( sort keys %SERVER ) {
        my $s   = $SERVER{$server};
        my $pkg = "lazysite-$server";
        my ($stanza) = $control =~ /(^Package: \Q$pkg\E\n.*?)(?:\n\n|\z)/ms;
        ok( $stanza, "control has a $pkg stanza" ) or next;
        like( $stanza, qr/^Architecture: all$/m, "$pkg: Architecture: all" );
        like( $stanza, qr/^ lazysite-common \(= \$\{source:Version\}\),$/m,
            "$pkg: strict same-version dependency on lazysite-common" );

        my $install = slurp("$ROOT/debian/$pkg.install");
        for my $pattern (qw(cgi fcgi)) {
            like( $install,
                qr{^installers/\Q$server\E/vhost-$pattern\.conf\.example\s+\Q$s->{share}\E$}m,
                "$pkg ships vhost-$pattern.conf.example" );
        }
        like( slurp("$ROOT/debian/rules"),
            qr{install -D -m 0755 tools/\Q$s->{name}\E\.pl debian/\Q$pkg\E/usr/bin/\Q$s->{name}\E},
            "rules installs /usr/bin/$s->{name}" );
        like( slurp("$ROOT/debian/$pkg.manpages"),
            qr{^debian/man1/\Q$s->{name}\E\.1$}m, "$pkg lists the man page" );
        like( slurp("$ROOT/tools/gen-manpages.pl"),
            qr{'\Q$s->{name}\E'}, "gen-manpages.pl renders $s->{name} POD" );
        ok( -f "$ROOT/debian/$pkg.README.Debian", "$pkg README.Debian shipped" );
        like( slurp("$ROOT/debian/$pkg.docs"), qr{^docs/reference/webserver-wiring\.md$}m,
            "$pkg ships the wiring reference" );

        my $pod = `podchecker \Q$s->{tool}\E 2>&1`;
        like( $pod, qr/pod syntax OK/, "$s->{name} POD valid" );
    }
    like( $control, qr/^Recommends:\n apache2,$/m,
        'lazysite-apache recommends apache2' );
    like( $control, qr/^Recommends:\n nginx,\n fcgiwrap,$/m,
        'lazysite-nginx recommends nginx + fcgiwrap' );

    # The wiring reference exists and covers every promised server.
    my $wiring = slurp("$ROOT/docs/reference/webserver-wiring.md");
    ok( length $wiring, 'docs/reference/webserver-wiring.md present' );
    like( $wiring, qr/^## \Q$_\E/m, "wiring doc has a $_ section" )
        for ( 'Apache', 'nginx', 'Caddy', 'lighttpd' );
};

done_testing();
