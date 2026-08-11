#!/usr/bin/perl
# tools/lazysite-hestia-domain.pl - HestiaCP panel-side integrator (SM139
# increment 4). The lazysite-hestia deb installs this as
# /usr/bin/lazysite-hestia-domain.
#
# The hook-shaped provisioning command: it runs AS ROOT by design, because
# it is the panel-side integrator - the piece that does the few things only
# root can do on a Hestia box (lay out the 0551-locked domain root, hand
# the docroot to the web-server group, write the host-side registry and
# pool files, enable the systemd pool unit) and then DROPS to the site
# user for everything that writes into the site tree. The drop is explicit
# and early: after the bounded root layout pass, every site-tree write
# happens under `sudo -n -u <panel-user>`, keeping the SM139 principle
# intact - no root writes into site trees.
#
# Verbs:
#   add USER DOMAIN [--channel edge|beta|stable] [--policy auto|manual] [--fcgi]
#                   [--workers N] [--max-requests N]
#   remove DOMAIN
#   list
#
# It deliberately does NOT apply the Hestia web template
# (v-change-web-domain-tpl) itself: template application forces a vhost
# rebuild and is the operator's panel action - see README.Debian in the
# lazysite-hestia package for the 3-step onboarding.
#
# Core-only Perl; no CPAN deps.

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Find     ();
use Getopt::Long   ();

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

# Host-layout defaults, each overridable by environment for non-standard
# hosts (Hestia's HOMEDIR is configurable) and for the test suite.
my $HOME_BASE = length( $ENV{LAZYSITE_HESTIA_HOME} // '' )
    ? $ENV{LAZYSITE_HESTIA_HOME}
    : '/home';
my $REGISTRY_DIR = length( $ENV{LAZYSITE_REGISTRY_DIR} // '' )
    ? $ENV{LAZYSITE_REGISTRY_DIR}
    : '/etc/lazysite/sites.d';
my $POOLS_DIR = length( $ENV{LAZYSITE_POOLS_DIR} // '' )
    ? $ENV{LAZYSITE_POOLS_DIR}
    : '/etc/lazysite/pools';
my $WEB_GROUP = length( $ENV{LAZYSITE_WEB_GROUP} // '' )
    ? $ENV{LAZYSITE_WEB_GROUP}
    : 'www-data';

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';

if    ( $verb eq '' )                                     { usage(2) }
elsif ( $verb eq 'help' || $verb =~ /^-{0,2}help$|^-h$/ ) { usage(0) }
elsif ( $verb eq 'add' )                                  { exit cmd_add() }
elsif ( $verb eq 'remove' )                               { exit cmd_remove() }
elsif ( $verb eq 'list' )                                 { exit cmd_list() }
else {
    print {*STDERR} "lazysite-hestia-domain: unknown verb '$verb'\n\n";
    usage(2);
}

# ---------- usage / errors ----------

sub usage {
    my ($rc) = @_;
    my $fh = ( $rc // 0 ) == 0 ? *STDOUT : *STDERR;
    print {$fh} <<'USAGE';
Usage: lazysite-hestia-domain VERB [options]

HestiaCP panel-side integrator for lazysite domains. Runs as root (the
panel context) and drops to the site user for every site-tree write.

Verbs:
  add USER DOMAIN [--channel edge|beta|stable] [--policy auto|manual] [--fcgi]
                  [--workers N] [--max-requests N]
        Prepare the Hestia domain layout as root (locked domain root,
        docroot group/setgid), then provision the site AS THE PANEL USER
        (sudo -u USER lazysite provision), register it in
        /etc/lazysite/sites.d/, and with --fcgi write
        /etc/lazysite/pools/DOMAIN.conf and enable lazysite@DOMAIN.
        Afterwards apply BOTH templates yourself - the Apache one that
        carries the access rules, and the nginx proxy in front of it,
        which otherwise answers static requests before Apache sees them:
          v-change-web-domain-tpl       USER DOMAIN lazysite-cgi|lazysite-fcgi yes
          v-change-web-domain-proxy-tpl USER DOMAIN lazysite-proxy
  remove DOMAIN
        Stop and disable the lazysite@DOMAIN pool (if any), remove the
        pool config and the registry entry. NEVER deletes the docroot -
        the site files stay; switch the domain's web template back in
        Hestia to take it off lazysite.
  list
        List registered lazysite sites (alias for `lazysite sites`).
  help
        This help.

Environment (host-layout overrides):
  LAZYSITE_HESTIA_HOME    Hestia home base (default /home)
  LAZYSITE_REGISTRY_DIR   site registry (default /etc/lazysite/sites.d)
  LAZYSITE_POOLS_DIR      pool configs (default /etc/lazysite/pools)
  LAZYSITE_WEB_GROUP      web-server group (default www-data)

Full documentation: man lazysite-hestia-domain.
USAGE
    exit( $rc // 0 );
}

sub fail {
    my ($msg) = @_;
    $msg =~ s/\n?$/\n/;
    print {*STDERR} "lazysite-hestia-domain: $msg";
    exit 1;
}

sub require_root {
    my ($what) = @_;
    return if $> == 0;
    fail( "'$what' must run as root: it is the panel-side integrator (it\n"
            . "prepares the Hestia-owned domain layout and the host registry/pool\n"
            . "files), and it DROPS to the site user for every site-tree write.\n"
            . 'Re-run with sudo.' );
}

sub run_or_fail {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    return if $rc == 0;
    my $why = $rc == -1 ? "cannot run: $!" : 'exit ' . ( $rc >> 8 );
    fail( "command failed ($why): " . join( ' ', @cmd ) );
}

# ---------- shared helpers ----------

# The lazysite CLI lives next to this command in every install shape:
#   /usr/bin/lazysite-hestia-domain      -> /usr/bin/lazysite       (deb)
#   TREE/tools/lazysite-hestia-domain.pl -> TREE/tools/lazysite-cli.pl
sub cli_path {
    my $bin = dirname( abs_path($0) );
    for my $cand ( "$bin/lazysite", "$bin/lazysite-cli.pl" ) {
        return $cand if -f $cand;
    }
    fail( "cannot locate the `lazysite` CLI next to $bin\n"
            . '(is lazysite-common installed?)' );
}

# Domain names become file names (registry, pool conf, unit instance) and
# path components - allow only the safe hostname alphabet.
sub check_domain {
    my ($domain) = @_;
    fail('DOMAIN is required') unless length( $domain // '' );
    fail("invalid domain '$domain' (allowed: [A-Za-z0-9._-], no leading dot/dash)")
        if $domain !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
    return $domain;
}

sub pool_conf_path {
    my ($domain) = @_;
    return "$POOLS_DIR/$domain.conf";
}

# ---------- add ----------

sub cmd_add {
    my %o = ( channel => '', policy => '', fcgi => 0, workers => 2, max_requests => 500 );
    # GetOptions first (it permutes options out of @ARGV), positionals after,
    # so `add --fcgi USER DOMAIN` and `add USER DOMAIN --fcgi` both work.
    Getopt::Long::GetOptions(
        'channel=s'      => \$o{channel},
        'policy=s'       => \$o{policy},
        'fcgi'           => \$o{fcgi},
        'workers=i'      => \$o{workers},
        'max-requests=i' => \$o{max_requests},
    ) or usage(2);
    my ( $user, $domain ) = @ARGV;
    fail('add needs USER and DOMAIN: lazysite-hestia-domain add USER DOMAIN')
        unless length( $user // '' ) && length( $domain // '' );
    check_domain($domain);
    fail("--channel must be 'edge', 'beta' or 'stable'")
        if length $o{channel} && $o{channel} !~ /^(?:edge|beta|stable)$/;
    fail("--policy must be 'auto' or 'manual'")
        if length $o{policy} && $o{policy} !~ /^(?:auto|manual)$/;
    require_root('add');

    my ( $uid, $ugid ) = ( getpwnam $user )[ 2, 3 ];
    fail("panel user '$user' does not exist") unless defined $uid;
    fail("panel user must not be root (SM139: sites are never owned by root)")
        if $uid == 0;
    my $web_gid = getgrnam($WEB_GROUP);
    fail( "web-server group '$WEB_GROUP' does not exist "
            . '(set LAZYSITE_WEB_GROUP for a non-Apache-standard host)' )
        unless defined $web_gid;

    my $domdir  = "$HOME_BASE/$user/web/$domain";
    my $docroot = "$domdir/public_html";
    my $cgibin  = "$domdir/cgi-bin";
    fail( "no Hestia domain at $domdir - create the domain in Hestia first\n"
            . "(v-add-web-domain $user $domain), then re-run this command" )
        unless -d $domdir;
    fail("no docroot at $docroot") unless -d $docroot;

    # --- root layout pass (bounded; the only root actions on the tree) ---
    # The Hestia domain root is mode 0551: the owner cannot create entries
    # in it, so the sibling trees install.pl populates (plugins/, tools/,
    # lib/) must be pre-created by root, owned by the user.
    print "==> preparing domain layout (as root)\n";
    for my $sib (qw(plugins tools lib)) {
        my $d = "$domdir/$sib";
        if ( !-d $d ) {
            mkdir $d or fail("mkdir $d: $!");
        }
        chown $uid, $ugid, $d or fail("chown $d: $!");
    }
    if ( !-d $cgibin ) {
        mkdir $cgibin or fail("mkdir $cgibin: $!");
    }
    # The CGI runs as the web-server user (SuexecUserGroup is off in the
    # shipped templates) and writes rendered .html across the docroot:
    # hand the tree to <user>:<web-group> with setgid dirs so everything
    # the site user provisions below inherits the web group - ownership
    # correct by construction, no chown-after repair pass.
    for my $top ( $docroot, $cgibin ) {
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    my $p = $File::Find::name;
                    return if -l $p;    # never chase symlinks out of the tree
                    chown $uid, $web_gid, $p or fail("chown $p: $!");
                    if ( -d _ ) {
                        chmod 02775, $p or fail("chmod $p: $!");
                    }
                },
            },
            $top
        );
    }

    # --- THE DROP: every site-tree write below runs as the panel user ---
    print "==> provisioning $domain from the host payload (as $user)\n";
    my @prov = ( 'sudo', '-n', '-u', $user, '--', $^X, cli_path(),
        'provision', '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain',  $domain );
    push @prov, '--channel', $o{channel} if length $o{channel};
    push @prov, '--policy',  $o{policy}  if length $o{policy};
    run_or_fail(@prov);

    # Secrets dirs: group-writable, off the world, so the web-server CGI
    # can mint auth/.secret and the rate-limit DBs (login depends on it).
    # Mode-only adjustments, same as the old template rebuild hook.
    for my $sec ( "$docroot/lazysite/auth", "$docroot/lazysite/forms" ) {
        next unless -d $sec;
        chmod 02770, $sec or fail("chmod $sec: $!");
    }

    # --- host-side registration (root territory: /etc/lazysite) ---
    # The unprivileged provision run above cannot write the root-owned
    # registry (it prints the entry instead); this integrator IS the admin,
    # so record the site for fleet tooling (lazysite upgrade --all / sites).
    # Key set matches the CLI's reader: docroot/cgibin/owner/channel/policy.
    # channel/policy are provision-time caches; without --channel the conf
    # seeded by `provision --domain` says update_channel: stable, so cache
    # that, not 'edge'.
    write_kv_file(
        "$REGISTRY_DIR/$domain",
        [
            [ docroot => $docroot ],
            [ cgibin  => $cgibin ],
            [ owner   => $user ],
            [ channel => length $o{channel} ? $o{channel} : 'stable' ],
            [ policy  => length $o{policy}  ? $o{policy}  : 'manual' ],
        ],
        ''
    );
    print "==> registered: $REGISTRY_DIR/$domain\n";

    # --- FastCGI pool (production shape; plain CGI needs none of this) ---
    if ( $o{fcgi} ) {
        my $conf = pool_conf_path($domain);
        write_kv_file(
            $conf,
            [
                [ DOCROOT      => $docroot ],
                [ USER         => $user ],
                [ GROUP        => $WEB_GROUP ],
                [ WORKERS      => $o{workers} ],
                [ MAX_REQUESTS => $o{max_requests} ],
            ],
            "# lazysite FastCGI pool for $domain - consumed by lazysite\@.service\n"
                . "# via tools/lazysite-pool.pl. After editing:\n"
                . "#   systemctl restart lazysite\@$domain\n"
        );
        print "==> pool config: $conf\n";
        enable_pool($domain);
    }

    print "\nDone. Now apply the matching web template in Hestia:\n"
        . '    v-change-web-domain-tpl '
        . "$user $domain "
        . ( $o{fcgi} ? 'lazysite-fcgi' : 'lazysite-cgi' )
        . " yes\n";
    template_hint( $o{fcgi} ? 'lazysite-fcgi' : 'lazysite-cgi' );

    # SM283. Printed as a second step rather than folded into the line above,
    # because it is a second LAYER: the web template is Apache's and carries
    # lazysite's access rules, while nginx sits in front of it and answers
    # static requests by extension. Leave the domain on a stock proxy and a
    # protected section gates its pages while publishing its images and PDFs.
    print "\nAnd the proxy template, so the front end respects the same rules:\n"
        . "    v-change-web-domain-proxy-tpl $user $domain lazysite-proxy\n"
        . "    curl -sI https://$domain/ | grep -i x-lazysite-front"
        . "    # confirms which front end replied\n";
    proxy_template_hint();
    return 0;
}

# Atomic-ish key=value file write (tmp + rename), shared by the registry
# entry and the pool config. $header is prepended verbatim ('' for none).
sub write_kv_file {
    my ( $path, $pairs, $header ) = @_;
    my $dir = dirname($path);
    fail("$dir does not exist (is lazysite-common installed?)") unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or fail("write $tmp: $!");
    print {$fh} $header if length $header;
    print {$fh} "$_->[0]=$_->[1]\n" for @$pairs;
    close $fh or fail("close $tmp: $!");
    rename $tmp, $path or do {
        unlink $tmp;
        fail("rename $tmp -> $path: $!");
    };
    return;
}

# Enable + start the pool unit. On a systemd-less host (containers, test
# rigs) print the command instead of failing the whole onboarding.
sub enable_pool {
    my ($domain) = @_;
    my $systemctl = first_existing( '/usr/bin/systemctl', '/bin/systemctl' );
    if ( !defined $systemctl ) {
        print "==> systemctl not found - enable the pool yourself:\n"
            . "    systemctl enable --now lazysite\@$domain\n";
        return;
    }
    run_or_fail( $systemctl, 'enable', '--now', 'lazysite@' . $domain );
    print "==> pool enabled: lazysite\@$domain "
        . "(socket /run/lazysite/$domain.sock)\n";
    return;
}

sub first_existing {
    my (@paths) = @_;
    for my $p (@paths) {
        return $p if -x $p;
    }
    return undef;
}

# Point the operator at the shipped template copies if Hestia does not have
# them yet (the one-off host step from README.Debian). Advisory only.
sub template_hint {
    my ($tpl) = @_;
    my $hestia_tpl = '/usr/local/hestia/data/templates/web/apache2/php-fpm';
    return unless -d $hestia_tpl;    # no Hestia here (tests) - stay quiet
    return if -f "$hestia_tpl/$tpl.tpl";
    print "NOTE: $tpl is not installed in $hestia_tpl yet; copy it first:\n"
        . "    cp /usr/share/lazysite-hestia/templates/$tpl.* $hestia_tpl/\n";
    return;
}

# The same hint for the nginx proxy layer (SM283), which lives in a DIFFERENT
# Hestia template directory - copying the web templates does not put it there.
sub proxy_template_hint {
    my $hestia_tpl = '/usr/local/hestia/data/templates/web/nginx';
    return unless -d $hestia_tpl;    # no Hestia here (tests) - stay quiet
    return if -f "$hestia_tpl/lazysite-proxy.tpl";
    print "NOTE: lazysite-proxy is not installed in $hestia_tpl yet; copy it\n"
        . "      first, or the front end serves gated static files directly:\n"
        . "    cp /usr/share/lazysite-hestia/templates/lazysite-proxy.* $hestia_tpl/\n";
    return;
}

# ---------- remove ----------

sub cmd_remove {
    Getopt::Long::GetOptions() or usage(2);
    my ($domain) = @ARGV;
    check_domain($domain);
    require_root('remove');

    my $did  = 0;
    my $conf = pool_conf_path($domain);
    if ( -f $conf ) {
        # Best-effort stop: the unit may never have been enabled, or the
        # host may not run systemd - the config removal below is what
        # permanently retires the pool (ConditionPathExists in the unit).
        my $systemctl = first_existing( '/usr/bin/systemctl', '/bin/systemctl' );
        if ( defined $systemctl ) {
            system( $systemctl, 'disable', '--now', 'lazysite@' . $domain ) == 0
                or print "==> (pool unit was not running/enabled)\n";
        }
        unlink $conf or fail("unlink $conf: $!");
        print "==> pool config removed: $conf\n";
        $did++;
    }
    my $entry = "$REGISTRY_DIR/$domain";
    if ( -f $entry ) {
        unlink $entry or fail("unlink $entry: $!");
        print "==> deregistered: $entry\n";
        $did++;
    }
    if ( !$did ) {
        fail( "nothing registered for '$domain' (no $entry, no $conf) - "
                . 'nothing removed' );
    }
    # The docroot is deliberately untouched: removal takes the domain off
    # lazysite's fleet tooling, it does not destroy the operator's site.
    print "\nSite files under the docroot were NOT touched. To take the domain\n"
        . "off lazysite entirely, switch its web template back in Hestia:\n"
        . "    v-change-web-domain-tpl USER $domain default\n";
    return 0;
}

# ---------- list ----------

sub cmd_list {
    # Delegate to the CLI's fleet listing - one source of truth for the
    # registry format. No root needed.
    my $rc = system( $^X, cli_path(), 'sites' );
    exit 127 if $rc == -1;
    return $rc >> 8;
}

__END__

=head1 NAME

lazysite-hestia-domain - HestiaCP panel-side provisioning for lazysite domains

=head1 SYNOPSIS

  lazysite-hestia-domain add USER DOMAIN [--channel edge|beta|stable]
                             [--policy auto|manual] [--fcgi]
                             [--workers N] [--max-requests N]
  lazysite-hestia-domain remove DOMAIN
  lazysite-hestia-domain list

=head1 DESCRIPTION

The Hestia integration command shipped by the C<lazysite-hestia> package
(SM139 increment 4). It is B<root-run by design>: it is the panel-side
integrator, doing the few things only root can do on a Hestia host and
then B<dropping to the site user> (C<sudo -n -u USER>) for everything
that writes into the site tree - the SM139 principle (no root writes
into site trees) holds throughout, so ownership in the site tree is
correct by construction.

It replaces the hand-run C<installers/hestia> deploy scripts of the
tarball era; the runbook (F<installers/hestia/INSTALL-RUNBOOK.md>)
describes the full packaged onboarding.

=head1 VERBS

=over 4

=item B<add> USER DOMAIN [--channel edge|beta|stable] [--policy auto|manual] [--fcgi] [--workers N] [--max-requests N]

Onboard an existing Hestia web domain (create it in Hestia first). As
root it prepares the panel-specific layout: the C<plugins/>, C<tools/>
and C<lib/> siblings inside the 0551-locked domain root, and the docroot
and cgi-bin handed to C<USER:www-data> with setgid dirs so files the
site user creates inherit the web group. It then drops to USER and runs
C<lazysite provision --docroot ... --cgibin ... --domain DOMAIN>
(passing C<--channel>/C<--policy> through), tightens the secrets dirs
(C<lazysite/auth>, C<lazysite/forms>) to 2770, and writes the site
registry entry at F</etc/lazysite/sites.d/DOMAIN>.

With C<--fcgi> it also writes F</etc/lazysite/pools/DOMAIN.conf>
(C<DOCROOT=>, C<USER=>, C<GROUP=>, C<WORKERS=>, C<MAX_REQUESTS=> - the
keys C<lazysite-pool.pl> consumes) and runs
C<systemctl enable --now lazysite@DOMAIN>, giving the domain a
persistent FastCGI pool on F</run/lazysite/DOMAIN.sock>.

It finishes by printing the two template-application commands
(C<v-change-web-domain-tpl USER DOMAIN lazysite-cgi|lazysite-fcgi yes>
and C<v-change-web-domain-proxy-tpl USER DOMAIN lazysite-proxy>);
applying them is deliberately left to the operator because each forces
a Hestia vhost rebuild.

Both are needed, and the second is the one that is easy to skip. On
Hestia the request path is nginx to Apache. lazysite's access rules
live in the Apache template, while Hestia's stock nginx proxy serves a
fixed list of static B<extensions> straight off the docroot - so a
protected section gates its pages and publishes its images, PDFs and
archives, with nothing in the manager or the audit trail to say so
(SM283). C<lazysite-proxy> hands those requests back to Apache
whenever the site has an ACL store, and leaves a site without one
serving statics directly as before.

=item B<remove> DOMAIN

Stop and disable the C<lazysite@DOMAIN> pool if one is configured,
delete its pool config and the registry entry. The docroot is B<never>
deleted - the site's files stay in place and become inert once the
domain's web template is switched back in Hestia.

=item B<list>

List the registered sites; a pass-through to C<lazysite sites>.

=back

=head1 ENVIRONMENT

C<LAZYSITE_HESTIA_HOME> (Hestia home base, default C</home> - match a
custom Hestia C<HOMEDIR>), C<LAZYSITE_REGISTRY_DIR> (default
C</etc/lazysite/sites.d>), C<LAZYSITE_POOLS_DIR> (default
C</etc/lazysite/pools>), C<LAZYSITE_WEB_GROUP> (default C<www-data>).

=head1 EXIT STATUS

0 on success; 1 on refusals and failures; 2 on usage errors.

=head1 SEE ALSO

lazysite(1), and F</usr/share/doc/lazysite-hestia/README.Debian> for the
3-step domain onboarding and the shipped web templates.

=cut
