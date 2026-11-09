#!/usr/bin/perl
# SM1233, SM1361: the Docker Compose package (installers/docker/). One container
# serves many sites (rulings 201, 205, 208, 210): nginx, and each site's one-rule
# FastCGI pool and runtime, in one container; the engine and its extensions are
# the image, read-only; the sites are folders in one volume, listed in its
# sites.conf; every process runs as www-data; plain HTTP behind the operator's
# own proxy. Built locally from the release tarball.
#
# None of this needs Docker. The compose file, the Dockerfile and nginx.conf are
# read as text here, and the release's own manifest builder is run on the
# package. What the entrypoint and lazysite-sites DO is t/tools/393, run for real
# against an image stage. The one real build is the container walk, a by-hand
# step (ruling 204), not a test.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);
use JSON::PP   ();

my $root = repo_root();
my $pkg  = "$root/installers/docker";

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }

# --- the package is there -----------------------------------------------------
for my $f (qw(Dockerfile Dockerfile.dockerignore compose.yaml entrypoint.sh lazysite-sites nginx.conf
    front.conf.example README.md)) {
    ok( -f "$pkg/$f", "installers/docker/$f exists" );
}
ok( -x "$pkg/entrypoint.sh",  'the entrypoint is executable' );
ok( -x "$pkg/lazysite-sites", 'and so is lazysite-sites' );

my $compose = slurp("$pkg/compose.yaml");
my $docker  = slurp("$pkg/Dockerfile");
my $entry   = slurp("$pkg/entrypoint.sh");
my $nginx   = slurp("$pkg/nginx.conf");

# --- compose.yaml: one service, one volume, read-only, plain HTTP ----------------
# A minimal reader: this file's shape is fixed, and the repo carries no YAML
# parser a host is guaranteed to have.
my ($top) = $compose =~ /^volumes:\n((?:[ ]+[\w-]+:[^\n]*\n|\s*#[^\n]*\n|\n)+)/m;
my @named = $top ? ( $top =~ /^[ ]+([\w-]+):/mg ) : ();
is_deeply( \@named, ['lazysite-sites'], 'one named volume: the sites (ruling 208, Q-C)' );
my %mount = $compose =~ m{^\s+-\s+([\w-]+):(/\S+)\s*$}mg;
is_deeply( \%mount, { 'lazysite-sites' => '/srv/sites' }, 'mounted where the entrypoint reads the sites' );

my ($svc_block) = $compose =~ /^services:\n(.*?)^volumes:/ms;
my @services = $svc_block =~ /^  ([\w-]+):\s*$/mg;
is_deeply( \@services, ['lazysite'], 'one service serves every site' );

like( $compose, qr/^\s+read_only:\s*true\s*$/m, 'the root filesystem is read-only (ruling 210)' );
my ($tmpfs) = $compose =~ /^\s+tmpfs:\n((?:\s+- .*\n)+)/m;
is_deeply( [ sort( ( $tmpfs // '' ) =~ /- (\S+)/g ) ], [ '/run/lazysite', '/tmp' ],
    'the only writable places besides the volume: /tmp and the sockets' );
unlike( $compose, qr/^\s*(?:secrets|configs):/m, 'no secrets: the recipe handles no certificate (ruling 205)' );
unlike( $compose =~ s/^\s*#[^\n]*\n//mgr, qr/443|ssl|tls/i, 'and serves no TLS' );
unlike( $compose, qr/^\s+user:\s*(?:root|0)\b/m,  'and never runs as root' );

for my $pair ( [ compose => $compose ], [ Dockerfile => $docker ], [ entrypoint => $entry ], [ 'nginx.conf' => $nginx ] ) {
    ( my $code = $pair->[1] ) =~ s/^\s*#[^\n]*\n//mg;
    unlike( $code, qr/odoo|\boom\b|oomd/i, "$pair->[0] names no Odoo, OOM or oomd" );
}

like( $compose, qr{^\s+context:\s*\.\./\.\.\s*$}m, 'the build context is the unpacked tarball' );
like( $compose, qr{^\s+dockerfile:\s*installers/docker/Dockerfile\s*$}m, 'the Dockerfile is named from that context' );
unlike( $compose, qr/^\s+(?:image:\s*\S*\/\S+|platform:)/m, 'no registry-qualified image' );
like( $compose, qr/^\s+image:\s*\$\{LAZYSITE_IMAGE:-lazysite:local\}/m, 'the tag is a variable: the upgrade is a tag' );
like( $compose, qr/^\s+healthcheck:\n(?:\s+.*\n)*?\s+test:.*curl.*127\.0\.0\.1:8080\/lazysite-health/m,
    'a healthcheck on nginx\'s own health location, never a site (ruling 208)' );
like( $compose, qr/^\s+cap_drop:\n\s+- ALL/m,  'all capabilities dropped' );
unlike( $compose, qr/^\s+cap_add:/m,           'none added back' );
like( $compose, qr/no-new-privileges:true/,    'no-new-privileges' );
like( $compose, qr/restart:\s*unless-stopped/, 'restarts unless stopped' );
like( $compose, qr/stop_grace_period:/,        'a stop grace period' );
like( $compose, qr/\$\{LAZYSITE_BIND:-127\.0\.0\.1\}/, 'published on loopback unless the operator says otherwise' );
like( $compose, qr/LAZYSITE_WORKERS:\s*\$\{LAZYSITE_WORKERS:-2\}/, 'each site\'s worker cap (ruling 208, Q-B)' );

# --- the Dockerfile ------------------------------------------------------------
like( $docker, qr/^FROM debian:trixie/m, 'Debian trixie, what the debs target' );
like( $docker, qr{^COPY \. /usr/share/lazysite$}m, 'the release is copied to where the debs put the payload' );
unlike( $docker, qr/^RUN[^\n]*install\.pl/m, 'nothing is installed into the volume at build time' );
like( $docker, qr/^USER www-data$/m, 'every process is www-data (ruling 210)' );
like( $docker, qr/^HEALTHCHECK [^\n]*\n[^\n]*lazysite-health/m, 'the image\'s healthcheck is the same' );
like( $docker, qr/^ENTRYPOINT \["\/usr\/local\/bin\/lazysite-entrypoint"\]/m, 'an entrypoint' );
unlike( $docker, qr/^VOLUME\b/m, 'no VOLUME line, which would add anonymous volumes beside the one' );
for my $p (qw(curl libfcgi-perl libfcgi-procmanager-perl libtemplate-perl libtext-multimarkdown-perl nginx)) {
    like( $docker, qr/\b\Q$p\E\b/, "the image installs $p" );
}

# The shared engine, as Lazysite::Extensions and install.pl read it.
require Lazysite::Extensions;
my $mark = do { no warnings 'once'; $Lazysite::Extensions::SHARED_MARK };
like( $docker, qr{> /usr/share/lazysite/\Q$mark\E }, "the image writes the shared-engine marker ($mark)" );
like( $docker, qr{chmod 0755 /usr/share/lazysite/lazysite-\*\.pl /usr/share/lazysite/extensions/\*\.pl},
    'the CGIs and extension scripts are executable, as a cgi-bin\'s are' );
my ($links) = slurp("$root/install.pl") =~ m{^sub endpoint_links \{ return qw\(([^)]+)\) \}$}m;
my @want = sort split ' ', $links // '';
my @have = sort $docker =~ m{ln -s extensions/([a-z-]+)\.pl /usr/share/lazysite/\1\.pl}g;
ok( @want, 'install.pl names its endpoint links' );
is_deeply( \@have, \@want, 'the image links the same endpoints beside the CGIs' );
like( $docker, qr{mkdir -p /srv/sites[^\n]*\n[^\n]*chown www-data:www-data /srv/sites}, 'the volume\'s mount point is www-data\'s, so a new volume takes that' );

# --- nginx.conf -----------------------------------------------------------------
unlike( $nginx, qr/^\s*user\s/m, 'nginx.conf sets no user: it is started as one' );
like( $nginx, qr{^pid /tmp/}m, 'and keeps its pid where that user can write' );
like( $nginx, qr{^\s*include /tmp/nginx/sites/\*\.conf;}m, 'and reads the server blocks the entrypoint writes at start' );
like( $entry, qr{NGINX_DIR=\$\{LAZYSITE_NGINX_DIR:-/tmp/nginx/sites\}}, 'which is where the entrypoint writes them' );
like( $entry, qr{--engine shared}, 'the entrypoint lays every site on the shared engine' );

# --- the operator's proxy: an example, never read by the recipe ----------------------
my $front = slurp("$pkg/front.conf.example");
like( $front, qr/proxy_set_header Host\s+\$host;/, 'front.conf.example keeps Host, which picks the site' );
like( $front, qr/proxy_set_header X-Forwarded-For\s+\$proxy_add_x_forwarded_for;/, 'and appends the client\'s address' );
unlike( ( $compose . $docker . $entry ) =~ s/^\s*#[^\n]*\n//mgr, qr/front\.conf/, 'and nothing in the recipe reads it' );

# --- shipped with the release --------------------------------------------------
{
    my $t   = site_tempdir() =~ s{/site/public_html\z}{}r;    # a scratch base; no docroot is used
    my $cfg = JSON::PP->new->decode( slurp("$root/dist/config/classification.json") );
    opendir my $dh, $pkg or die; my @files = map { "installers/docker/$_" } sort grep { -f "$pkg/$_" } readdir $dh; closedir $dh;
    ok( scalar(@files) >= 8, 'the package has its files' );
    my @excluded = grep { my $f = $_; grep { $f =~ /$_/ } @{ $cfg->{exclude} } } @files;
    is_deeply( \@excluded, [], 'the release does not exclude the package' );

    # The release's own manifest builder, on a tree holding the package: the
    # build refuses an unclassified path (SM1226 hit that), and lists a
    # tarball-only file with install_to null.
    my $stage = "$t/stage";
    for my $f (@files) {
        ( my $d = "$stage/$f" ) =~ s{/[^/]+\z}{};
        system( 'mkdir', '-p',       $d );
        system( 'cp',    "$root/$f", "$stage/$f" );
    }
    my $out = `perl '$root/tools/build-manifest.pl' --staged '$stage' --config '$root/dist/config/classification.json' --version 0.0.1 --out '$t/manifest.json' 2>&1`;
    is( $?, 0, 'build-manifest accepts the package (no unclassified path)' ) or diag $out;
    my $m = -f "$t/manifest.json" ? JSON::PP->new->decode( slurp("$t/manifest.json") ) : { files => [] };
    my %by = map { $_->{path} => $_ } @{ $m->{files} };
    is_deeply( [ sort keys %by ], [ sort @files ], 'every file of the package is in the manifest' );
    my @installed = grep { defined $by{$_}{install_to} } keys %by;
    is_deeply( \@installed, [], 'and none is installed into a site tree' );
}

# --- the docs ------------------------------------------------------------------
{
    my $readme = slurp("$pkg/README.md");
    like( $readme, qr/docker compose build/,                    'the README documents the local build' );
    like( $readme, qr/add NAME DOMAIN/,          'adding a site' );
    like( $readme, qr/sysop NAME USER/,                         'the first account' );
    like( $readme, qr/lazysite-sites restore NAME BACKUP/,      'the rollback' );
    like( $readme, qr/one-site canary needs a second container/i, 'the canary (ruling 208, Q-D)' );
    like( $readme, qr/plain HTTP/,                              'plain HTTP behind the operator\'s proxy' );
    like( $readme, qr/only\s+the\s+image's\s+own\s+extensions\s+run/,   'only the image\'s extensions (ruling 210)' );
    like( slurp("$root/docs/IMPLEMENTOR.md"), qr/Deploying with Docker Compose/, 'the implementor guide has a section' );
    like( slurp("$root/docs/IMPLEMENTOR.md"), qr/lazysite-sites add/, 'which shows the many-site recipe' );
}

done_testing;
