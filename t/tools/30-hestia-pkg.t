#!/usr/bin/perl
# SM139 increment 4: static checks that keep the lazysite-hestia package
# honest without a Hestia host. The shipped Apache templates parse (balanced
# sections, the FallbackResource contract, the fcgi socket path matching the
# lazysite@.service/pool-launcher convention), lazysite-hestia-domain
# behaves at the CLI edge (--help, unknown verbs, input validation before
# privilege), the pool-conf writer emits only keys the pool launcher
# actually consumes, and debian/ declares the packaging relations.
use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT   = repo_root();
my $HESTIA = "$ROOT/installers/hestia";
my $TOOL   = "$ROOT/tools/lazysite-hestia-domain.pl";
my $POOL   = "$ROOT/tools/lazysite-pool.pl";
my $UNIT   = "$ROOT/debian/lazysite\@.service";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

# Run the domain tool; returns (exit_code, combined_output).
sub run_tool {
    my ( $env, @args ) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for qw(
        LAZYSITE_HESTIA_HOME LAZYSITE_REGISTRY_DIR
        LAZYSITE_POOLS_DIR   LAZYSITE_WEB_GROUP
    );
    $ENV{$_} = $env->{$_} for keys %$env;
    my $cmd = join ' ', map { quotemeta } $^X, $TOOL, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# --- the socket-path convention, from the sources that define it -------------
# The pool launcher's default run dir and the unit's RuntimeDirectory= are
# the convention the fcgi vhost templates must encode; read them rather
# than hard-coding, so a relocation fails here loudly.
my $pool_src = slurp($POOL);
my ($rundir) = $pool_src =~ /rundir\s*=>\s*'([^']+)'/;
ok( $rundir, "pool launcher declares a default run dir ($rundir)" );
my $unit_src = slurp($UNIT);
my ($rtd) = $unit_src =~ /^RuntimeDirectory=(\S+)/m;
is( "/run/$rtd", $rundir, 'unit RuntimeDirectory= matches the launcher run dir' );

# --- templates parse and carry the load-bearing directives -------------------
for my $pattern (qw(cgi fcgi)) {
    for my $ext (qw(tpl stpl)) {
        my $path = "$HESTIA/lazysite-$pattern.$ext";
        subtest basename($path) => sub {
            ok( -f $path, 'template shipped' ) or return;
            my $text = slurp($path);

            # Balanced Apache container sections.
            for my $tag (qw(VirtualHost Directory Location FilesMatch IfModule)) {
                my $open  = () = $text =~ /^\s*<\Q$tag\E[\s>"]/mg;
                my $close = () = $text =~ m{^\s*</\Q$tag\E>}mg;
                is( $open, $close, "balanced <$tag> sections ($open)" );
            }

            # Exactly one FallbackResource: the single page-routing entry point.
            my @fb = $text =~ /^\s*FallbackResource\s+(\S+)/mg;
            is( scalar @fb, 1, 'exactly one FallbackResource' );

            # Client-supplied trust headers are stripped at the door.
            like( $text, qr/^\s*RequestHeader unset X-Remote-User/m,
                'strips X-Remote-User' );

            # The auth wrapper fronts the real cgi-bin scripts in both patterns.
            like( $text,
                qr{RewriteRule \^/cgi-bin/.*lazysite-auth\.pl}m,
                'cgi-bin scripts fronted by the auth wrapper' );

            if ( $pattern eq 'cgi' ) {
                # The runbook CRITICAL: pages route through auth, never the
                # processor directly (or logins silently never take effect).
                is( $fb[0], '/cgi-bin/lazysite-auth.pl',
                    'CGI pattern: FallbackResource -> the auth wrapper' );
                unlike( $text, qr/proxy:unix:/,
                    'CGI pattern has no pool proxying' );
            }
            else {
                is( $fb[0], '/lazysite-pool',
                    'FCGI pattern: FallbackResource -> the pool location' );
                # Socket path follows the unit/launcher convention:
                # RUNDIR/<instance>.sock with instance = the Hestia %domain%.
                like( $text,
                    qr{SetHandler\s+"proxy:unix:\Q$rundir\E/%domain%\.sock\|fcgi://localhost/"},
                    "pool socket is $rundir/%domain%.sock via mod_proxy_fcgi" );
                # Session-bearing requests must stay on the CGI auth path -
                # the pool is anonymous by design (performance.md).
                like( $text, qr/^\s*RewriteCond %\{HTTP_COOKIE\} lazysite_auth=/m,
                    'session cookie carve-out to the CGI auth wrapper' );
            }

            # tpl/stpl pairing: SSL directives only in the .stpl.
            if ( $ext eq 'stpl' ) {
                like( $text, qr/^\s*SSLEngine on/m, 'stpl enables SSL' );
            }
            else {
                unlike( $text, qr/^\s*SSLEngine on/m, 'tpl carries no SSL engine' );
            }
        };
    }
}

# --- lazysite-hestia-domain: CLI edge behaviour ------------------------------
subtest 'domain tool dispatch and validation' => sub {
    my ( $rc, $out ) = run_tool( {}, '--help' );
    is( $rc, 0, '--help: exit 0' );
    like( $out, qr/Usage: lazysite-hestia-domain VERB/, 'usage shown' );
    like( $out, qr/^\s{2}$_( |$)/m, "usage lists '$_'" ) for qw(add remove list);

    ( $rc, $out ) = run_tool( {}, 'frobnicate' );
    is( $rc, 2, 'unknown verb: exit 2' );
    like( $out, qr/unknown verb 'frobnicate'/, 'unknown verb named' );

    ( $rc, $out ) = run_tool( {} );
    is( $rc, 2, 'no verb: exit 2' );

    # Input validation fires BEFORE the root gate (usable error messages
    # for the operator regardless of privilege).
    ( $rc, $out ) = run_tool( {}, 'add', 'user', 'bad domain!' );
    is( $rc, 1, 'add with a bad domain: refused' );
    like( $out, qr/invalid domain/, 'names the domain problem' );

    ( $rc, $out ) = run_tool( {}, 'add', 'user', 'ok.example', '--channel', 'nightly' );
    is( $rc, 1, 'add with a bad channel: refused' );
    like( $out, qr/--channel must be/, 'names the channel problem' );

  SKIP: {
        skip 'running as root: cannot test the non-root refusal', 4 if $> == 0;
        for my $args ( [ 'add', 'user', 'ok.example' ], [ 'remove', 'ok.example' ] ) {
            ( $rc, $out ) = run_tool( {}, @$args );
            is( $rc, 1, "$args->[0] as non-root: refused" );
            like( $out, qr/must run as root/, 'refusal explains the root design' );
        }
    }

    # list needs no root and delegates to the CLI's fleet listing.
    my $reg = tempdir( CLEANUP => 1 );
    ( $rc, $out ) = run_tool( { LAZYSITE_REGISTRY_DIR => $reg }, 'list' );
    is( $rc, 0, 'list: exit 0' );
    like( $out, qr/no sites registered/, 'list delegates to lazysite sites' );
};

# --- pool-conf writer emits only keys the pool launcher consumes -------------
subtest 'pool conf keys match the launcher' => sub {
    my $tool_src = slurp($TOOL);
    # The writer builds the pool conf from [ KEY => value ] pairs; the
    # registry entry uses lowercase keys, so uppercase pairs ARE the pool
    # conf schema.
    my %emitted = map { $_ => 1 } $tool_src =~ /\[\s*([A-Z][A-Z_]+)\s*=>/g;
    ok( %emitted, 'found the pool-conf key pairs in the writer' );
    ok( $emitted{DOCROOT}, 'DOCROOT= emitted (launcher requires it)' );
    ok( $emitted{USER},    'USER= emitted (launcher requires it)' );

    my %consumed = map { $_ => 1 } $pool_src =~ /\$ENV\{([A-Z][A-Z_]+)\}/g;
    for my $k ( sort keys %emitted ) {
        ok( $consumed{$k}, "emitted key $k= is consumed by lazysite-pool.pl" );
    }
};

# --- debian packaging declares the relations ---------------------------------
subtest 'debian/ metadata' => sub {
    my $control = slurp("$ROOT/debian/control");
    my ($stanza) = $control =~ /(^Package: lazysite-hestia\n.*?)(?:\n\n|\z)/ms;
    ok( $stanza, 'control has a lazysite-hestia stanza' ) or return;
    like( $stanza, qr/^Architecture: all$/m, 'Architecture: all' );
    like( $stanza, qr/^ lazysite-common \(= \$\{source:Version\}\),$/m,
        'strict same-version dependency on lazysite-common' );
    like( $stanza, qr/^ sudo,$/m, 'depends on sudo (the drop mechanism)' );

    my $install = slurp("$ROOT/debian/lazysite-hestia.install");
    # SM283: 'proxy' is in this list because the package shipping only the
    # Apache half is the whole defect. The nginx proxy answers static requests
    # before Apache is involved, so a template set that covers one layer covers
    # none of the deployment.
    for my $pattern (qw(cgi fcgi proxy)) {
        for my $ext (qw(tpl stpl)) {
            like( $install,
                qr{^installers/hestia/lazysite-$pattern\.$ext\s+usr/share/lazysite-hestia/templates$}m,
                "ships lazysite-$pattern.$ext to the templates dir" );
        }
    }

    # The operator has to put the proxy template in Hestia's OTHER template
    # directory and apply it with a different command; a README that describes
    # only the Apache half is how the layer goes missing on a live host.
    my $readme = slurp("$ROOT/debian/lazysite-hestia.README.Debian");
    like( $readme, qr{templates/web/nginx},
        'README.Debian names the nginx proxy template directory' );
    like( $readme, qr{v-change-web-domain-proxy-tpl},
        'README.Debian gives the proxy apply command' );
    like( $readme, qr{x-lazysite-front}i,
        'README.Debian gives the probe that says which front end replied' );

    like( slurp("$ROOT/debian/rules"),
        qr{install -D -m 0755 tools/lazysite-hestia-domain\.pl debian/lazysite-hestia/usr/bin/lazysite-hestia-domain},
        'rules installs /usr/bin/lazysite-hestia-domain' );

    like( slurp("$ROOT/debian/lazysite-hestia.manpages"),
        qr{^debian/man1/lazysite-hestia-domain\.1$}m,
        'man page listed for the domain tool' );
    like( slurp("$ROOT/tools/gen-manpages.pl"),
        qr{'lazysite-hestia-domain'}, 'gen-manpages.pl renders its POD' );

    ok( -f "$ROOT/debian/lazysite-hestia.README.Debian",
        'README.Debian shipped for the hestia package' );

    # POD is valid so the man page actually builds.
    my $pod = `podchecker \Q$TOOL\E 2>&1`;
    like( $pod, qr/pod syntax OK/, 'lazysite-hestia-domain POD valid' );
};

done_testing();
