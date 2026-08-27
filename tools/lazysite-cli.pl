#!/usr/bin/perl
# tools/lazysite-cli.pl - the `lazysite` host CLI (SM139 increments 1+2).
#
# A thin dispatcher over the existing tools: provision/upgrade wrap
# install.pl, check/users/dev pass through to the tools/ scripts. The deb
# (lazysite-common) installs this as /usr/bin/lazysite next to the engine
# payload at /usr/share/lazysite; run from a git checkout or an unpacked
# tarball it finds the payload relative to $0 instead, so both worlds get
# the same front door.
#
# The one load-bearing principle (SM139): no root writes into site trees.
# provision and single-site upgrade REFUSE to run as root. The verbs that may
# run as root are the ones that DROP to each site's owner (sudo -u) before
# touching a site tree: `upgrade --all`, `migrate-engine-tree --all` and
# `probe`. Ownership is correct by construction - no chown-after pass, no
# lazysite-check --fix as a routine step.
#
# Site registry: provision records each site as one INI-ish file at
# /etc/lazysite/sites.d/<domain> (docroot=, cgibin=, owner=, channel=) so
# `upgrade --all` and fleet tooling can enumerate sites without guessing
# paths. Registration is best-effort: when the registry directory is
# missing or not writable (deb installs create it root-owned), provisioning
# still succeeds and the file for the admin to drop in is printed.
#
# Core-only Perl; no CPAN deps.

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(basename dirname);
use Getopt::Long   ();
use JSON::PP       ();

my $DEFAULT_REGISTRY_DIR = '/etc/lazysite/sites.d';

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';

if    ( $verb eq '' )                                     { usage(2) }
elsif ( $verb eq 'help' || $verb =~ /^-{0,2}help$|^-h$/ ) { usage(0) }
elsif ( $verb eq 'provision' )                            { exit cmd_provision() }
elsif ( $verb eq 'upgrade' )                              { exit cmd_upgrade() }
elsif ( $verb eq 'sites' )                                { exit cmd_sites() }
elsif ( $verb eq 'check' ) {
    my $targets = extract_site_targets( \@ARGV );
    $targets
        ? run_tool_per_site( 'tools/lazysite-check.pl', $targets, \@ARGV )
        : run_tool( 'tools/lazysite-check.pl', @ARGV );
}
elsif ( $verb eq 'repair' ) { cmd_repair() }
elsif ( $verb eq 'probe' )  { cmd_probe() }
elsif ( $verb eq 'users' ) {

    # SM625: `users` was the last verb with no fleet addressing. SM321 gave
    # --domain/--all to `check` and `acl` because a sysop holds a site's
    # NAME, not its docroot; `repair`, `probe` and `migrate-engine-tree` have it
    # too. This one was left a pure pass-through - and it is the verb that
    # settles a capability decision, which is exactly the thing that arrives
    # across a whole fleet at once when a release adds capabilities to a group
    # that was seeded before them. Twenty-six sites, one decision, and the only
    # way to apply it was a shell loop.
    my $targets = extract_site_targets( \@ARGV );
    $targets
        ? run_tool_per_site( 'tools/lazysite-users.pl', $targets, \@ARGV )
        : run_tool( 'tools/lazysite-users.pl', @ARGV );
}
elsif ( $verb eq 'acl' ) {
    my $targets = extract_site_targets( \@ARGV );
    $targets
        ? run_tool_per_site( 'tools/lazysite-acl.pl', $targets, \@ARGV )
        : run_tool( 'tools/lazysite-acl.pl', @ARGV );
}
elsif ( $verb eq 'migrate-engine-tree' ) { exit cmd_migrate_engine_tree() }
elsif ( $verb eq 'dev' )                 { run_tool( 'tools/lazysite-server.pl', @ARGV ) }
elsif ( $verb eq 'demo' )                { exit cmd_demo() }
elsif ( $verb eq 'version' )             { exit cmd_version() }
else {
    print {*STDERR} "lazysite: unknown verb '$verb'\n\n";
    usage(2);
}

# ---------- usage / errors ----------

sub usage {
    my ($rc) = @_;
    my $fh = ( $rc // 0 ) == 0 ? *STDOUT : *STDERR;
    print {$fh} <<'USAGE';
Usage: lazysite VERB [options]

Host-side lazysite management. The engine payload is located relative
to this executable: /usr/share/lazysite for the deb install, the
checkout/tarball root when run from a source tree.

Verbs:
  provision --docroot D --cgibin C [--domain NAME] [--channel edge|beta|stable|certified]
            [--policy auto|manual]
        Fresh-install a site from the host payload. Runs as the SITE
        USER, never root (ownership correct by construction), and
        records the site in the registry at /etc/lazysite/sites.d/.
  upgrade --docroot D [--cgibin C] [--force]
        Upgrade one site from the host payload, as the site user.
        --cgibin defaults to the site's registry entry.
  upgrade --all [--force | --force-security]
        Upgrade every registered site. As root, drops to each site's
        owner via sudo -u; as a normal user, refuses unless every
        registered site belongs to you. Sites with update_policy
        'manual' (the default) are skipped unless --force is given;
        each site's update_channel is then enforced by the installer.
        --force-security overrides BOTH channel and policy, and is
        accepted only when the payload's release manifest declares
        "security_critical": true.
  sites
        List registered sites: owner, channel, policy, installed
        version, docroot.
  check [args...]        Health/permissions doctor (lazysite-check.pl).
                         Takes --domain NAME or --all instead of --docroot:
                         the registry holds each site's docroot and cgibin, so
                         name the site rather than reconstructing its paths.
  users [args...]        Auth user management (lazysite-users.pl). Also takes
                         --domain NAME or --all, so one decision can be applied
                         across the fleet:
                           sudo lazysite users --all group-set \\
                             lazysite-admins housekeeping on
                         Every site gets the SAME command - which is what you
                         want for a capability decision, and is not what you
                         want for `add`. Preview with --all on a read-only
                         subcommand (`groups`, `list`) first.
  repair --docroot D | --domain NAME | --all [--dry-run]
        Run the doctor, apply its safe fixes, then CHECK AGAIN and
        report the state AFTER the repair, per site.
  probe --docroot D | --domain NAME | --all
        Ask each site's live front door whether a protected path is
        actually refused. As root, drops to the site's owner.
  migrate-engine-tree --docroot D | --all [--apply] [--min-version V]
        Move a site's lazysite/ tree OUT of the document root, to
        <docroot>-lazysite. Reports what it would do unless --apply is
        given. --all walks the registry; as root it drops to each
        site's owner. --min-version skips sites below that version, so
        a fleet can be migrated as the release rolls through its
        channels. Reversible with --back.
  acl [args...]          Per-path access (also --domain NAME | --all):
                         who may read or write a file,
        a folder, or the whole site (lazysite-acl.pl). Same rules and
        same store as the manager, the control API and MCP.
  dev [args...]          Local dev server (lazysite-server.pl).
  demo [--port N] [--dir PATH]
        Instant try-it: fresh-install a scratch site (default
        ~/lazysite-demo) as the current user and serve it on the dev
        server (default port 8080). Never runs as root. Re-running
        reuses the site; remove it with rm -rf when done.
  version                Payload version, channel and location.
  help                   This help.

Examples:
  sudo -u siteuser lazysite provision \
      --docroot /home/siteuser/web/example.com/public_html \
      --cgibin  /home/siteuser/web/example.com/cgi-bin \
      --domain  example.com
  lazysite check --docroot /var/www/html --fix
  sudo lazysite upgrade --all

Full documentation: perldoc lazysite (or man lazysite).
USAGE
    exit( $rc // 0 );
}

sub fail {
    my ($msg) = @_;
    $msg =~ s/\n?$/\n/;
    print {*STDERR} "lazysite: $msg";
    exit 1;
}

# A mistake in the INVOCATION, as opposed to something that went wrong while
# working. Exit 2, the same as an unknown verb, because it is the same class of
# mistake made at the same moment by the same person - and the same code every
# other lazysite tool uses for it.
sub usage_error {
    my ($msg) = @_;
    $msg =~ s/\n?$/\n/;
    print {*STDERR} "lazysite: $msg";
    exit 2;
}

# ---------- payload / identity helpers ----------

# Locate the engine payload relative to $0 (no configuration, works from
# every install shape):
#   /usr/bin/lazysite                 -> ../share/lazysite  (deb)
#   CHECKOUT/tools/lazysite-cli.pl    -> ..                 (git / tarball)
#   PAYLOAD/tools/lazysite-cli.pl     -> ..                 (payload direct)
my $PAYLOAD_ROOT;

sub payload_root {
    return $PAYLOAD_ROOT if defined $PAYLOAD_ROOT;
    my $bin = dirname( abs_path($0) );
    for my $cand ( "$bin/..", $bin, "$bin/../share/lazysite" ) {
        my $abs = abs_path($cand);
        next unless defined $abs && -d $abs;
        if ( -f "$abs/install.pl" && -f "$abs/VERSION" ) {
            $PAYLOAD_ROOT = $abs;
            return $abs;
        }
    }
    fail( 'cannot locate the engine payload (install.pl + VERSION) near '
            . "$bin - expected /usr/share/lazysite or a source checkout" );
}

# The payload's release manifest, decoded; undef for a bare checkout (no
# manifest built). Shared by version, --force-security and the sites verb.
sub payload_manifest {
    my $path = payload_root() . '/release-manifest.json';
    open my $fh, '<:raw', $path or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    my $m = eval { JSON::PP::decode_json($text) };
    return ref $m eq 'HASH' ? $m : undef;
}

sub current_user {
    my $name = getpwuid($>);
    return defined $name ? $name : "uid$>";
}

sub running_as_root {
    # LAZYSITE_CLI_FAKE_ROOT is a TEST-ONLY override so the suite can
    # exercise the root-refusal paths without uid 0. Never set it in
    # production; it only ever makes the CLI MORE restrictive.
    return 1 if $ENV{LAZYSITE_CLI_FAKE_ROOT};
    return $> == 0 ? 1 : 0;
}

sub refuse_root {
    my ($what) = @_;
    return unless running_as_root();
    fail( "refusing to run '$what' as root.\n"
            . "lazysite never writes into a site tree as root: root-owned files in a\n"
            . "site tree are exactly the breakage this CLI exists to prevent (SM139).\n"
            . "Run it as the site user instead:\n"
            . "  sudo -u SITEUSER lazysite $what ...\n"
            . "(The verbs that may run as root are the ones that drop to each\n"
            . "site's owner first: 'upgrade --all', 'migrate-engine-tree --all'\n"
            . "and 'probe'.)" );
}

sub run_or_fail {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    return if $rc == 0;
    my $why = $rc == -1 ? "cannot run: $!" : 'exit ' . ( $rc >> 8 );
    fail( "command failed ($why): " . join( ' ', @cmd ) );
}

# Pass-through verbs: exec-style dispatch to a payload tool, exit status
# forwarded verbatim.
sub run_tool {
    my ( $rel, @args ) = @_;
    my $tool = payload_root() . "/$rel";
    fail("payload tool missing: $tool") unless -f $tool;
    my $rc = system( $^X, _lib_arg(), $tool, @args );
    exit 127 if $rc == -1;
    exit( $rc >> 8 );
}

# SM321: tell the child where the engine's modules are.
#
# The tools `require Lazysite::Paths` and friends without a `use lib` of their
# own, so they depend on @INC - and neither the payload's lib/ nor an unpacked
# tarball's is in it. Running one produced
#
#   Can't locate Lazysite/Paths.pm in @INC
#
# which is what an operator met when told to run `lazysite check --fix` after a
# rollout, and what they had to work around by hand with -I and a full path.
# payload_root() has always known where lib/ is; run_tool simply never passed it
# on. One argument, and the documented command becomes the one that works.
sub _lib_arg {
    my $lib = payload_root() . '/lib';
    return -d $lib ? ( '-I', $lib ) : ();
}

# The installer invocation. Four callers assembled the same interpreter, the
# same payload path and the same pair of path options; --force is the only
# flag any of them added.
sub _install_argv {
    my ( $docroot, $cgibin, %o ) = @_;
    my @cmd = ( $^X, payload_root() . '/install.pl',
        '--docroot', $docroot, '--cgibin', $cgibin );
    push @cmd, '--force' if $o{force};
    return @cmd;
}

# As root, drop to the site's owner before a command touches a site tree.
# sudo -n never prompts, so a host without the sudoers entry fails loudly
# rather than hanging.
sub _as_owner {
    my ( $owner, @cmd ) = @_;
    return ( 'sudo', '-n', '-u', $owner, '--', @cmd );
}

# Three verbs walk the registry, and each said this when it was empty.
sub _no_sites_registered {
    print 'lazysite: no sites registered in ' . registry_dir() . "\n";
    return 0;
}

# SM321: address a site by the one token the sysop holds - its NAME.
#
# `lazysite check` and `lazysite acl` were pure pass-throughs, so they never saw
# the registry and the sysop had to supply a docroot and a cgibin. On the
# Hestia layout that means knowing the site user too, and reconstructing
# /home/<user>/web/<domain>/public_html by hand - four things the system already
# knows, to name one thing the sysop does.
#
# The registry has held docroot and cgibin per site all along; `upgrade --all`
# and `migrate-engine-tree --all` already read it. This is those verbs'
# addressing, applied to the two that were left out - not a new mechanism.
#
# Resolution happens HERE rather than in each tool, so the tools stay per-site
# and unchanged. A tool that grew its own discovery would be a second copy of the
# registry reader, which is the shape SM318 and SM304 were both filed about.
# SM329: fall back to the host's OWN idea of its sites.
#
# The registry at /etc/lazysite/sites.d is written by `provision`, which the deb
# path runs and the HESTIA TARBALL PATH NEVER DOES - install.pl says so outright:
# "lazysite has no central site registry - the host knows the sites". So SM321's
# --domain addressing worked on a deb install and was useless on the deployment
# shape this project actually uses, which is the one the complaint came from.
#
# lazysite-hestia-list.sh already discovers every site authoritatively, from the
# Hestia web template rather than a marker file, and prints user/domain/docroot.
# Two discovery mechanisms existed and the CLI consulted the one that was empty.
#
# It reads /usr/local/hestia/data/users, so it needs ROOT. A non-root caller gets
# told that rather than "no registered site named X", which would send them
# looking for a registry entry that was never going to exist.
sub _discover_hestia_sites {
    my $lister = payload_root() . '/installers/hestia/lazysite-hestia-list.sh';
    return [] unless -f $lister;

    my @out = qx(bash \Q$lister\E --plain --template-only 2>/dev/null);
    if ( $? != 0 || !@out ) {
        if ( !running_as_root() ) {
            fail( 'the Hestia site list needs root (it reads '
                    . "/usr/local/hestia/data/users).\n"
                    . '  Re-run with sudo, or pass --docroot explicitly.' );
        }
        return [];
    }

    my @sites;
    for my $line (@out) {
        chomp $line;
        my ( $user, $domain, $docroot ) = split /\t/, $line;
        next unless defined $docroot && length $docroot && -d $docroot;
        ( my $siteroot = $docroot ) =~ s{/public_html/?\z}{};
        push @sites, {
            name    => $domain,
            docroot => $docroot,
            cgibin  => "$siteroot/cgi-bin",
            owner   => $user,
        };
    }
    return \@sites;
}

sub extract_site_targets {
    my ($argv) = @_;
    my ( @rest, $all, $name );
    while ( defined( my $a = shift @$argv ) ) {
        if    ( $a eq '--all' )             { $all = 1 }
        elsif ( $a eq '--domain' )          { $name = shift @$argv }
        elsif ( $a =~ /\A--domain=(.+)\z/ ) { $name = $1 }
        else                                { push @rest, $a }
    }
    @$argv = @rest;
    return undef unless $all || defined $name;

    fail('--all and --domain are mutually exclusive') if $all && defined $name;

    my $sites = read_registry();
    $sites = _discover_hestia_sites() unless @$sites;
    unless (@$sites) {
        fail( 'no sites registered in ' . registry_dir()
                . ", and no Hestia site list available - give --docroot instead" );
    }

    return $sites if $all;

    my ($hit) = grep { $_->{name} eq $name } @$sites;
    unless ($hit) {
        fail( "no registered site named '$name'. Known: "
                . join( ', ', map { $_->{name} } @$sites ) );
    }
    return [$hit];
}

# Run a per-site tool once per target, and report per site.
#
# The exit status is the WORST outcome, not the last one - a fleet command that
# returned the final site's status would report success whenever the last site
# happened to be healthy, which is the class of defect this project keeps
# filing. Sites are not stopped on failure: one broken site should not hide the
# state of the rest.
sub run_tool_per_site {
    my ( $rel, $targets, $args ) = @_;
    my $tool = payload_root() . "/$rel";
    fail("payload tool missing: $tool") unless -f $tool;

    my $worst = 0;
    my ( @ok, @bad, @unchecked );
    for my $s (@$targets) {
        my @a = ( '--docroot', $s->{docroot} );
        push @a, '--cgibin', $s->{cgibin} if length( $s->{cgibin} // '' );
        print "\n== $s->{name}\n" if @$targets > 1;
        my $rc = system( $^X, _lib_arg(), $tool, @a, @$args );
        $rc    = $rc == -1 ? 127 : ( $rc >> 8 );
        $worst = $rc if $rc > $worst;
        # SM562: exit 2 is "could not check at all" (lazysite-check's contract;
        # a usage refusal elsewhere) - a refusal, not a finding. Labelling it
        # "with findings" sent operators hunting for a content problem on a
        # site the tool had never looked at.
        if    ( $rc == 2 ) { push @unchecked, $s->{name} }
        elsif ($rc)        { push @bad,       $s->{name} }
        else               { push @ok,        $s->{name} }
    }

    if ( @$targets > 1 ) {
        printf "\n== %d ok, %d with findings, %d could not check.\n",
            scalar @ok, scalar @bad, scalar @unchecked;
        printf "   findings on: %s\n",     join( ', ', @bad )       if @bad;
        printf "   could not check: %s\n", join( ', ', @unchecked ) if @unchecked;
    }
    exit $worst;
}

# ---------- registry ----------

sub registry_dir {
    # LAZYSITE_REGISTRY_DIR relocates the registry (tests, non-FHS hosts);
    # default is the deb-shipped /etc/lazysite/sites.d.
    my $dir = $ENV{LAZYSITE_REGISTRY_DIR};
    return defined $dir && length $dir ? $dir : $DEFAULT_REGISTRY_DIR;
}

# Registry file name: --domain when given, else derived from the docroot
# (skipping generic web-root basenames), sanitised to [A-Za-z0-9._-].
sub site_name_for {
    my ( $domain, $docroot ) = @_;
    my $name = defined $domain ? $domain : '';
    if ( !length $name ) {
        $name = basename($docroot);
        $name = basename( dirname($docroot) )
            if $name =~ /^(?:public_html|htdocs|html|www)$/
            && length( dirname($docroot) ) > 1;
    }
    $name =~ s/[^A-Za-z0-9._-]+/-/g;
    $name =~ s/^[.-]+//;
    return length $name ? $name : 'site';
}

# Best-effort registration: write when the directory exists AND is
# writable; otherwise print the file the admin should drop there. Never
# fails provisioning.
sub registry_record {
    my (%e)  = @_;
    my $dir  = registry_dir();
    my $path = "$dir/$e{name}";
    my $body = join '', map { "$_=" . ( $e{$_} // '' ) . "\n" }
        qw(docroot cgibin owner channel policy);

    if ( -d $dir && -w $dir ) {
        my $tmp = "$path.tmp.$$";
        my $ok  = open my $fh, '>', $tmp;
        if ($ok) {
            print {$fh} $body;
            close $fh;
            $ok = rename $tmp, $path;
            unlink $tmp unless $ok;
        }
        if ($ok) {
            print "lazysite: site registered: $path\n";
            return;
        }
    }
    print "lazysite: registry not writable ($dir); the site is provisioned but not\n"
        . "registered for fleet upgrades. Ask the admin to create $path containing:\n";
    print $body =~ s/^/    /mgr;
    return;
}

# All registry entries, tolerating missing/garbled files: an entry without
# a usable docroot is skipped with a warning, never fatal.
sub read_registry {
    my $dir = registry_dir();
    my @sites;
    opendir my $dh, $dir or return \@sites;
    my @names = sort grep { !/^\./ && !/\.tmp\.\d+$/ && lc $_ ne 'readme' } readdir $dh;
    closedir $dh;
    for my $name (@names) {
        my $path = "$dir/$name";
        next unless -f $path;
        my %e  = ( name => $name );
        my $ok = open my $fh, '<', $path;
        if ( !$ok ) {
            warn "lazysite: registry entry '$name' unreadable, skipped: $!\n";
            next;
        }
        while ( my $line = <$fh> ) {
            chomp $line;
            next if $line =~ /^\s*#/ || $line !~ /=/;
            my ( $k, $v ) = split /=/, $line, 2;
            $k =~ s/^\s+|\s+$//g;
            $v =~ s/^\s+|\s+$//g;
            $e{$k} = $v if $k =~ /^(?:docroot|cgibin|owner|channel|policy)$/;
        }
        close $fh;
        if ( !length( $e{docroot} // '' ) || !-d $e{docroot} ) {
            warn "lazysite: registry entry '$name' has no usable docroot=, skipped\n";
            next;
        }
        push @sites, \%e;
    }
    return \@sites;
}

sub site_owner {
    my ($s) = @_;
    return $s->{owner} if length( $s->{owner} // '' );
    my $uid  = ( stat $s->{docroot} )[4];
    my $name = defined $uid ? getpwuid($uid) : undef;
    return defined $name ? $name : '';
}

# One "key: value" scalar out of a site's lazysite.conf; undef when the conf
# (or the key) is missing/unreadable.
sub site_conf_value {
    my ( $docroot, $key ) = @_;
    my $conf = "$docroot/lazysite/lazysite.conf";
    open my $fh, '<', $conf or return undef;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\s*\Q$key\E\s*:\s*(\S+)/;
        close $fh;
        return $1;
    }
    close $fh;
    return undef;
}

# The site's effective update policy: 'auto' opts in to fleet upgrades,
# anything else is 'manual' (the default). The conf key (update_policy, set
# by install.pl --policy) is authoritative; the registry's cached policy= is
# the fallback when the conf has no key.
sub site_update_policy {
    my ($s) = @_;
    my $v = site_conf_value( $s->{docroot}, 'update_policy' );
    $v = $s->{policy} unless defined $v && length $v;
    return lc( $v // '' ) eq 'auto' ? 'auto' : 'manual';
}

# The site's installed engine version, from .install-state.json; '' when not
# discoverable (never fatal - the sites listing shows '-').
sub site_version {
    my ($docroot) = @_;
    my $path = "$docroot/lazysite/.install-state.json";
    open my $fh, '<:raw', $path or return '';
    my $text = do { local $/; <$fh> };
    close $fh;
    my $s = eval { JSON::PP::decode_json($text) };
    return ref $s eq 'HASH' ? ( $s->{version} // '' ) : '';
}

# ---------- verbs ----------

sub cmd_provision {
    my %o = ( docroot => '', cgibin => '', domain => '', channel => '', policy => '' );
    Getopt::Long::GetOptions(
        'docroot=s' => \$o{docroot},
        'cgibin=s'  => \$o{cgibin},
        'domain=s'  => \$o{domain},
        'channel=s' => \$o{channel},
        'policy=s'  => \$o{policy},
    ) or usage(2);
    refuse_root('provision');
    usage_error('provision needs --docroot and --cgibin')
        unless length $o{docroot} && length $o{cgibin};
    fail("--channel must be 'edge', 'beta', 'stable' or 'certified'")
        if length $o{channel} && $o{channel} !~ /^(?:edge|beta|stable|certified)$/;
    fail("--policy must be 'auto' or 'manual'")
        if length $o{policy} && $o{policy} !~ /^(?:auto|manual)$/;

    my $root = payload_root();
    my @cmd  = _install_argv( $o{docroot}, $o{cgibin} );
    push @cmd, '--domain', $o{domain} if length $o{domain};
    run_or_fail(@cmd);

    # install.pl --channel / --policy are standalone maintenance ops (set
    # the conf key, no install), so they run as second passes.
    run_or_fail( $^X, "$root/install.pl",
        '--channel', $o{channel}, '--docroot', $o{docroot} )
        if length $o{channel};
    run_or_fail( $^X, "$root/install.pl",
        '--policy', $o{policy}, '--docroot', $o{docroot} )
        if length $o{policy};

    my $docroot = abs_path( $o{docroot} ) // $o{docroot};
    my $cgibin  = abs_path( $o{cgibin} )  // $o{cgibin};
    registry_record(
        name    => site_name_for( $o{domain}, $docroot ),
        docroot => $docroot,
        cgibin  => $cgibin,
        owner   => current_user(),
        channel => length $o{channel} ? $o{channel} : 'edge',
        policy  => length $o{policy}  ? $o{policy}  : 'manual',
    );
    return 0;
}

sub cmd_upgrade {
    my %o = ( docroot => '', cgibin => '', all => 0, force => 0, force_security => 0 );
    Getopt::Long::GetOptions(
        'docroot=s'      => \$o{docroot},
        'cgibin=s'       => \$o{cgibin},
        'all'            => \$o{all},
        'force'          => \$o{force},
        'force-security' => \$o{force_security},
    ) or usage(2);
    # --force-security is only as strong as the release's own declaration: it
    # is honoured (as a full channel+policy override, i.e. --force) ONLY when
    # the payload manifest carries "security_critical": true. Verified up
    # front, before any site is touched.
    if ( $o{force_security} ) {
        my $m = payload_manifest();
        fail( "--force-security refused: the payload has no release manifest at\n"
                . payload_root()
                . "/release-manifest.json, so it cannot declare itself\n"
                . 'security-critical. Build/install a packaged release, or use --force.' )
            unless $m;
        fail( "--force-security refused: payload "
                . ( $m->{version} // 'unknown' )
                . ' (channel: '
                . ( $m->{channel} // 'edge' )
                . ") does not declare\n"
                . '"security_critical": true in its release manifest. The override is only as'
                . "\nstrong as the release's own declaration; for a routine out-of-channel\n"
                . 'upgrade use --force.' )
            unless $m->{security_critical};
        print "lazysite: payload " . ( $m->{version} // 'unknown' )
            . " declares security_critical: overriding channel and policy\n";
        $o{force} = 1;
    }
    return cmd_upgrade_all( \%o ) if $o{all};

    refuse_root('upgrade');
    usage_error('upgrade needs --docroot (or --all)') unless length $o{docroot};
    my $docroot = abs_path( $o{docroot} ) // $o{docroot};
    my $cgibin  = $o{cgibin};
    if ( !length $cgibin ) {
        for my $s ( @{ read_registry() } ) {
            my $sd = abs_path( $s->{docroot} ) // $s->{docroot};
            next unless $sd eq $docroot;
            $cgibin = $s->{cgibin} // '';
            last;
        }
    }
    fail( "cannot determine the cgi-bin for $docroot (no registry entry in "
            . registry_dir()
            . ') - pass --cgibin' )
        unless length $cgibin;

    run_or_fail( _install_argv( $docroot, $cgibin, force => $o{force} ) );
    return 0;
}

sub cmd_upgrade_all {
    my ($o) = @_;
    my $sites = read_registry();
    return _no_sites_registered() if !@$sites;
    my $me      = current_user();
    my $is_root = running_as_root();
    if ( !$is_root ) {
        my @foreign = grep { site_owner($_) ne $me } @$sites;
        fail( "upgrade --all as '$me' refused: "
                . join( ', ', map { $_->{name} } @foreign )
                . " belong(s) to other users.\n"
                . 'Run as root (drops to each owner per site) or upgrade your own '
                . 'sites individually.' )
            if @foreign;
    }

    my ( @done, @skipped, @failed );
    for my $s (@$sites) {
        my $owner = site_owner($s);
        if ( !length $owner || $owner eq 'root' ) {
            warn "lazysite: $s->{name}: unusable owner '"
                . ( $owner || '?' )
                . "' (never upgrades as root), skipped\n";
            push @failed, $s->{name};
            next;
        }
        if ( !length( $s->{cgibin} // '' ) ) {
            warn "lazysite: $s->{name}: registry entry has no cgibin=, skipped\n";
            push @failed, $s->{name};
            next;
        }
        # Per-site update policy (SM139): 'manual' (the default) keeps the
        # fleet run off this site; --force / --force-security override.
        # 'auto' sites still pass through the installer's channel gate below.
        if ( !$o->{force} && site_update_policy($s) ne 'auto' ) {
            print "== $s->{name}: update_policy is 'manual' - skipped "
                . "(use --force, or upgrade it individually)\n";
            push @skipped, $s->{name};
            next;
        }
        my @cmd = _install_argv( $s->{docroot}, $s->{cgibin}, force => $o->{force} );
        # The only place root is allowed: drop to the site's owner per site.
        @cmd = _as_owner( $owner, @cmd ) if $is_root && $owner ne $me;
        print "== $s->{name}: $s->{docroot} (as $owner)\n";
        my $rc = system(@cmd);
        if    ( $rc == 0 ) { push @done, $s->{name} }
        elsif ( $rc != -1 && ( $rc >> 8 ) == 3 ) {
            # install.pl exit 3 = clean channel skip (the site's
            # update_channel refused this payload; already explained and
            # audited by the installer). Not a failure.
            print "== $s->{name}: skipped by its update_channel (see above)\n";
            push @skipped, $s->{name};
        }
        else { push @failed, $s->{name} }
    }
    print 'lazysite: upgraded ' . @done . ' site(s)'
        . ( @skipped ? ', skipped ' . @skipped . ' (' . join( ', ', @skipped ) . ')' : '' )
        . ( @failed  ? ', FAILED: ' . join( ', ', @failed ) : '' ) . "\n";
    return @failed ? 1 : 0;
}

# List the registered sites: name, owner, channel, policy, installed version,
# docroot. Channel and policy show the LIVE conf value when the site's
# lazysite.conf is readable, falling back to the registry's cached value; the
# version comes from the site's .install-state.json ('-' when undiscoverable).

# SM293 step 2b: move a site's engine tree out of the document root.
#
# `lazysite/` holds config, credentials, the audit log, session state, form
# submissions and pre-install snapshots, and inside the docroot it is kept
# unreachable only by a `deny /lazysite/` in every shipped front-end template -
# configuration lazysite ships, cannot test where it is installed, and mostly
# cannot see. SM283's proxy would have served
# lazysite/backups/preinstall-*.tar.gz on any host whose static list includes
# `gz`: the whole site, including the account store.
#
# The engine ASKS where its tree is (SM293 step 2a), so this command is the whole
# migration: one rename, atomic within a filesystem, reversible with --back, and
# idempotent so a fleet run is safe to repeat and safe on a mixed fleet.
#
# DRY RUN BY DEFAULT. This moves live credentials; --apply is the deliberate act,
# matching lazysite-fix-perms. --min-version is how a fleet follows a release
# through its channels: migrate what is new enough, leave the rest, run it again
# after the next roll-out.
# SM321: repair and probe as VERBS, not as blocks inside a Hestia script.
#
# Both were added to installers/hestia/lazysite-hestia-update-all.sh, because
# that is where the per-site loop already lived. The consequence is that they
# exist ONLY there: an operator on any other layout cannot run them at all, and
# one on Hestia cannot run them for a single site without running the whole
# rollout. Neither operation is Hestia-specific.
#
# Now that the CLI addresses sites (--domain / --all, with the Hestia fallback
# described at extract_site_targets), they belong here and the rollout script
# calls them.

# What each site's public URL is. The registry and the Hestia lister both key a
# site by its domain, so the name IS the host.
sub _site_url {
    my ($s) = @_;
    return "https://$s->{name}/";
}

# Run the doctor, repair what it finds, then CHECK AGAIN.
#
# The re-check is the point. This project's recurring defect is a control
# reporting success without doing the work, and "we ran --fix" is a claim about
# an action while "the site is clean afterwards" is a claim about the outcome.
# Only the second is printed.
sub cmd_repair {
    # Addressing first: --domain and --all are consumed here, so the verb's own
    # option parser never sees them. The other order makes GetOptions reject the
    # addressing it was given.
    my $targets = extract_site_targets( \@ARGV );
    $targets ||= _targets_or_fail();

    my %o;
    Getopt::Long::GetOptionsFromArray( \@ARGV, 'dry-run' => \$o{dry_run} )
        or fail('bad options for repair');

    my $tool = payload_root() . '/tools/lazysite-check.pl';

    # SM626: a pending DECISION is not an unfixed DEFECT, and counting them
    # together made the tally useless. A fleet of 26 healthy sites - 43 ok, zero
    # failures each - reported as "0 clean, 0 repaired, 26 need a human",
    # because every one carried the same warning: a group seeded before this
    # release has not been told what to do about the capabilities the release
    # added. That warning CANNOT be repaired. It clears when a human decides,
    # and until then it pins every site into the worst bucket, where a genuine
    # unfixable failure would be indistinguishable from it.
    my ( @clean, @repaired, @stuck, @decide );

    for my $s (@$targets) {
        my @base = ( '--docroot', $s->{docroot} );
        push @base, '--cgibin', $s->{cgibin} if length( $s->{cgibin} // '' );

        my $before = qx($^X @{[ join ' ', _lib_arg() ]} \Q$tool\E @{[ join ' ', @base ]} 2>&1);
        my @issues = grep { /\[ (?:warn|FAIL) \]/ } split /\n/, $before;
        unless (@issues) { push @clean, $s->{name}; next }

        print "== $s->{name}\n";
        print "  $_\n" for @issues;

        if ( $o{dry_run} ) {
            print "  -> would repair (--dry-run)\n";
            push @stuck, $s->{name};
            next;
        }

        print "  -> repairing\n";
        system( $^X, _lib_arg(), $tool, @base, '--fix' ) >= 0
            or warn "  could not run the repair\n";

        my $after = qx($^X @{[ join ' ', _lib_arg() ]} \Q$tool\E @{[ join ' ', @base ]} 2>&1);
        my @left = grep { /\[ (?:warn|FAIL) \]/ } split /\n/, $after;

        # Split by SEVERITY, from the doctor's own marker. A FAIL after a repair
        # is something the repair could not do; a warn is, by the doctor's
        # contract, a thing it was never going to do. Reading the marker rather
        # than matching the capability sentence keeps this from rotting the next
        # time that wording changes.
        my @fails = grep { /\[ FAIL \]/ } @left;
        if (@fails) {
            push @stuck, $s->{name};
            print "  -> STILL FAILING:\n";
            print "     $_\n" for @left;
        }
        elsif (@left) {
            push @decide, $s->{name};
            print "  -> repaired. Left for you to decide, not a fault:\n";
            print "     $_\n" for @left;
        }
        else {
            push @repaired, $s->{name};
            print "  -> repaired; the site is clean.\n";
        }
    }

    printf "\n%d clean, %d repaired, %d awaiting your decision, %d need a human.\n",
        scalar @clean, scalar @repaired, scalar @decide, scalar @stuck;
    printf "AWAITING YOUR DECISION: %s\n", join( ', ', @decide ) if @decide;
    printf "NEEDS A HUMAN: %s\n",          join( ', ', @stuck )  if @stuck;

    # SM626: exit non-zero for a FAILURE, not for a pending decision. A fleet
    # run in a script should not go red because nobody has ruled on a capability
    # yet - that is a standing state, not an incident, and a check that cries
    # wolf every run is one nobody reads.
    exit( @stuck ? 1 : 0 );
}

# Ask the FRONT END whether it honours an ACL, from outside.
#
# THREE outcomes, and the pass is a POSITIVE signal. Deriving it from the absence
# of failure is what SM319 corrected: run_acl_probe has five outcomes and four of
# them are not a pass, so anything that has not said it confirmed something falls
# to "not confirmed" - the safe direction, and one that needs no maintenance as
# the probe grows.
sub cmd_probe {
    my $targets = extract_site_targets( \@ARGV );
    $targets ||= _targets_or_fail();

    my $tool = payload_root() . '/tools/lazysite-check.pl';
    my ( @verified, @exposed, @unconfirmed, @skip_reasons );

    my $me      = current_user();
    my $is_root = running_as_root();

    for my $s (@$targets) {
        my @base = ( '--docroot', $s->{docroot}, '--check-acl', _site_url($s) );

        # SM426: DROP TO THE SITE'S OWNER, exactly as `upgrade --all` does.
        #
        # The probe refuses as root, and the refusal is right: protecting
        # content there would leave root-owned files in the site tree (SM377).
        # But the refusal ended a routine root deploy with "run the probe as
        # the site user" - so the one check that measures gating from OUTSIDE,
        # anonymously, the way a visitor meets it, is the one an automated
        # deploy never gets. An instruction printed at the end of a deploy is a
        # step that does not happen: SM366 records that the probe has never
        # been run from the field at all.
        #
        # Nothing new is invented here. The registry already records owner= per
        # site and `upgrade --all` already drops to it with sudo -n; this is
        # the same drop on the one command that declined to use it.
        #
        # sudo -n never prompts, so a host without the sudoers entry FAILS
        # rather than hanging - and the probe's own skip and stated cause come
        # through unchanged, which is what SM385 requires of a summary.
        my $owner = site_owner($s);
        my @cmd   = ( $^X, _lib_arg(), $tool, @base );
        @cmd = _as_owner( $owner, @cmd )
            if $is_root && defined $owner && length $owner && $owner ne $me;

        my $shell = join ' ', map { quotemeta } @cmd;
        my $out   = qx($shell 2>&1);

        # MATCH THE PROBE'S OWN VERDICT, not any [ FAIL ] in the report.
        #
        # lazysite-check reports on much more than the ACL probe, so a site with
        # an unrelated failure - missing system pages, a stale registry - was
        # being announced as SERVING PROTECTED CONTENT ANONYMOUSLY. Found by
        # running it: a fixture with no web server at all, whose probe had
        # actually been SKIPPED, was classified as exposed on the strength of an
        # unrelated finding.
        #
        # That is SM319's defect in the other direction. There the pass was an
        # absence; here the failure was a level rather than a statement. Both
        # ends must be positive signals from the probe itself.
        if ( $out =~ /a file the engine refuses is served to anonymous visitors/ ) {
            push @exposed, $s->{name};
            print "  $s->{name}: SERVED ANONYMOUSLY\n";
            print "    $_\n" for grep { /\[ (?:warn|FAIL) \]/ } split /\n/, $out;
        }
        # SM377: the confirmation line changed wording when the probe stopped
        # claiming to have tested the FRONT END. It is a designated marker and
        # the pass is derived from matching it, so the two move together or
        # every pass silently becomes 'not confirmed'. t/tools/41 pins both.
        elsif ( $out =~ /protected content is not reachable anonymously/ ) {
            push @verified, $s->{name};
            print "  $s->{name}: front end honours the rule\n";
        }
        else {
            push @unconfirmed, $s->{name};
            push @skip_reasons, $1
                if $out =~ /ACL PROBE SKIPPED:\s*(.+?)\s*$/m;
            print "  $s->{name}: NOT CONFIRMED\n";
            print "    $_\n" for grep { /\[ warn \]/ } split /\n/, $out;
        }
    }

    printf "\n%d verified, %d exposed, %d not confirmed.\n",
        scalar @verified, scalar @exposed, scalar @unconfirmed;

    if (@exposed) {
        printf "SERVED ANONYMOUSLY DESPITE AN ACL: %s\n", join ', ', @exposed;
        print "Protected content on these is reachable without signing in.\n";
    }
    if (@unconfirmed) {
        printf "NOT CONFIRMED: %s\n", join ', ', @unconfirmed;
        print "Nothing was established either way.\n";

        # SM385: THE PROBE SAID WHY. Use it.
        #
        # This printed one guess - "usual cause is a docroot or ACL store the
        # probe could not write: run lazysite repair" - whatever the reason
        # actually was. SM377 added a new skip (running as root, where
        # protecting content would leave root-owned files in the site tree) and
        # this summary went on recommending a repair that fixes nothing,
        # directly under a line stating the real cause.
        #
        # Sending a sysop after the wrong thing is the defect SM368 is
        # about, and it is worse in a summary than in a detail line, because the
        # summary is what a deploy log reader sees.
        if (@skip_reasons) {
            my %seen;
            for my $r ( grep { !$seen{$_}++ } @skip_reasons ) {
                print "  - $r\n";
            }
        }
        else {
            print "No reason was given, which usually means a docroot or ACL\n";
            print "store the probe could not write: run `lazysite repair`.\n";
        }
    }

    # Absence of evidence is not evidence of exposure, so a site that could not
    # be measured does not fail the command. The exposure case does.
    exit( @exposed ? 1 : 0 );
}

sub _targets_or_fail {
    my $sites = read_registry();
    $sites = _discover_hestia_sites() unless @$sites;
    fail('give --domain NAME, --all, or run where sites are discoverable')
        unless @$sites;
    return $sites;
}

sub cmd_migrate_engine_tree {
    my %o = ( apply => 0, back => 0, all => 0 );
    Getopt::Long::GetOptions(
        'docroot=s'     => \$o{docroot},
        'all'           => \$o{all},
        'apply'         => \$o{apply},
        'back'          => \$o{back},
        'min-version=s' => \$o{min_version},
    ) or usage(2);

    usage_error('give --docroot D or --all') unless $o{all} || $o{docroot};
    fail('--docroot and --all are mutually exclusive') if $o{all} && $o{docroot};

    # SM366: locate the Lazysite module tree relative to this script
    # (run-in-place, tarball and Hestia installs), falling back to the system
    # @INC (package installs). The same bootstrap lazysite-users.pl has always
    # carried; without it this tool cannot start anywhere the modules are not
    # already on @INC, which is every install that is not a package.
    #
    # This is the ONLY verb that loads a Lazysite module, and it loads it at
    # runtime one statement below - so the locator runs here, beside the load it
    # exists for, rather than in a BEGIN that fired on `lazysite version`.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }

    require Lazysite::Paths;

    my @targets;
    if ( $o{all} ) {
        my $sites = read_registry();
        return _no_sites_registered() if !@$sites;
        @targets = @$sites;
    }
    else {
        @targets = ( { name => $o{docroot}, docroot => $o{docroot} } );
    }

    my $me      = current_user();
    my $is_root = running_as_root();
    my ( @done, @skipped, @failed );

    for my $s (@targets) {
        my $doc = $s->{docroot};
        my $ver = site_version($doc);

        # The version gate. A site the release has not reached yet is running
        # code that computes "<docroot>/lazysite" and would not find a moved
        # tree - migrating it would take it offline.
        if ( defined $o{min_version} && length $o{min_version} ) {
            if ( !defined $ver || !length $ver ) {
                print "== $s->{name}: version unknown - skipped "
                    . "(cannot prove it can find a moved tree)\n";
                push @skipped, $s->{name};
                next;
            }
            if ( version_lt( $ver, $o{min_version} ) ) {
                print "== $s->{name}: $ver is below $o{min_version} - skipped\n";
                push @skipped, $s->{name};
                next;
            }
        }

        my $what = $o{back} ? 'move back into' : 'move out of';
        if ( !$o{apply} ) {
            my $note = $o{back}
                ? 'would move back into the document root'
                : 'would move out of the document root';
            my $state =
                Lazysite::Paths::stray_lazysite($doc) ? 'IN BOTH PLACES - refuses'
                : -d Lazysite::Paths::external_lazysite_dir($doc) ? 'already outside'
                : -d "$doc/lazysite"                              ? $note
                :   'no engine tree found';
            printf "== %-28s %s  [%s]\n", $s->{name}, $state,
                ( defined $ver && length $ver ? $ver : 'version unknown' );
            push @skipped, $s->{name};
            next;
        }

        # SM139: never as root into a site tree. As root, drop to the owner.
        my $owner = $o{all} ? site_owner($s) : $me;
        if ( $is_root && $o{all} && ( !length $owner || $owner eq 'root' ) ) {
            warn "lazysite: $s->{name}: unusable owner - skipped\n";
            push @failed, $s->{name};
            next;
        }
        if ( $is_root && $owner ne $me ) {
            my $root = payload_root();
            my @cmd  = _as_owner( $owner,
                $^X,         "$root/tools/lazysite-cli.pl", 'migrate-engine-tree',
                '--docroot', $doc, '--apply', ( $o{back} ? ('--back') : () ) );
            print "== $s->{name}: $what the document root (as $owner)\n";
            my $rc = system(@cmd);
            if   ( $rc == 0 ) { push @done,   $s->{name} }
            else              { push @failed, $s->{name} }
            next;
        }
        if ( $is_root && !$o{all} ) {
            fail( "refusing to migrate as root.\n"
                    . "  This moves the site's own credentials; root-owned files in a\n"
                    . "  site tree are what break the manager afterwards (SM139).\n"
                    . "    sudo -u SITEUSER lazysite migrate-engine-tree --docroot $doc --apply" );
        }

        my ( $ok, $note ) = $o{back}
            ? Lazysite::Paths::migrate_back($doc)
            : Lazysite::Paths::migrate_out($doc);
        if ($ok) {
            print "== $s->{name}: $note\n";
            push @done, $s->{name};
        }
        else {
            warn "lazysite: $s->{name}: $note\n";
            push @failed, $s->{name};
        }
    }

    print 'lazysite: '
        . ( $o{apply} ? 'migrated ' . @done . ' site(s)'     : 'dry run - nothing moved' )
        . ( @skipped  ? ', ' . @skipped . ' skipped'         : '' )
        . ( @failed   ? ', FAILED: ' . join( ', ', @failed ) : '' ) . "\n";
    print "Re-run with --apply to make the change.\n" if !$o{apply};
    return @failed ? 1 : 0;
}

# Numeric-segment version compare: is $a strictly older than $b?
sub version_lt {
    my ( $a, $b ) = @_;
    my @a = ( $a =~ /(\d+)/g );
    my @b = ( $b =~ /(\d+)/g );
    for my $i ( 0 .. 2 ) {
        my ( $x, $y ) = ( $a[$i] // 0, $b[$i] // 0 );
        return 1 if $x < $y;
        return 0 if $x > $y;
    }
    return 0;
}

sub cmd_sites {
    my $sites = read_registry();
    return _no_sites_registered() if !@$sites;
    my @rows;
    for my $s (@$sites) {
        my $channel = site_conf_value( $s->{docroot}, 'update_channel' );
        $channel = $s->{channel} unless defined $channel && length $channel;
        push @rows,
            [
            $s->{name},
            site_owner($s) || '-',
            $channel || '-',
            site_update_policy($s),
            site_version( $s->{docroot} ) || '-',
            $s->{docroot},
            ];
    }
    my @head = qw(SITE OWNER CHANNEL POLICY VERSION DOCROOT);
    my @w    = map { length } @head;
    for my $r (@rows) {
        for my $i ( 0 .. 4 ) {
            $w[$i] = length $r->[$i] if length $r->[$i] > $w[$i];
        }
    }
    my $fmt = join( '  ', map { "%-${_}s" } @w[ 0 .. 4 ] ) . "  %s\n";
    printf $fmt, @head;
    printf $fmt, @$_ for @rows;
    return 0;
}

# The zero-argument try-it path: fresh-install a scratch site from the
# payload (install.pl, exactly what provision wraps) and exec the dev
# server on it. No new server or installer logic lives here - the verb is
# defaults + the existing code paths. The site is deliberately NOT
# registered in the fleet registry: it is a throwaway.
sub cmd_demo {
    my %o = ( port => 8080, dir => '' );
    Getopt::Long::GetOptions(
        'port=i' => \$o{port},
        'dir=s'  => \$o{dir},
    ) or usage(2);
    refuse_root('demo');
    fail("--port must be 1-65535, not '$o{port}'")
        if $o{port} !~ /^\d+$/ || $o{port} < 1 || $o{port} > 65535;

    my $dir = $o{dir};
    if ( !length $dir ) {
        my $base
            = length( $ENV{HOME}   // '' ) ? $ENV{HOME}
            : length( $ENV{TMPDIR} // '' ) ? $ENV{TMPDIR}
            :                                '/tmp';
        $dir = "$base/lazysite-demo";
    }
    my $docroot = "$dir/public_html";
    my $cgibin  = "$dir/cgi-bin";
    my $root    = payload_root();

    if ( -f "$docroot/lazysite/.install-state.json" ) {
        print "lazysite: reusing the demo site at $dir\n";
    }
    else {
        require File::Path;
        File::Path::make_path( $docroot, $cgibin );
        fail("cannot create the demo site directories under $dir")
            unless -d $docroot && -d $cgibin;
        print "lazysite: fresh-installing a demo site at $dir\n";
        run_or_fail( _install_argv( $docroot, $cgibin ) );
    }

    my @serve = ( $^X, "$root/tools/lazysite-server.pl",
        '--port', $o{port}, '--docroot', $docroot );
    print "\nDemo site:  $dir\n"
        . "Serving on: http://localhost:$o{port}/\n"
        . "Remove it:  rm -rf $dir\n"
        . "(Ctrl-C stops the server; the site stays for next time.)\n\n";
    # LAZYSITE_DEMO_NO_SERVE is a TEST-ONLY seam: the suite verifies the
    # install round-trip without inheriting a listening server process.
    if ( $ENV{LAZYSITE_DEMO_NO_SERVE} ) {
        print 'lazysite: LAZYSITE_DEMO_NO_SERVE set - would exec: '
            . join( ' ', @serve ) . "\n";
        return 0;
    }
    exec @serve
        or fail("cannot exec the dev server: $!");
    return 1;    # unreached (fail exits); keeps the verb shape uniform
}

sub cmd_version {
    my $root    = payload_root();
    my $version = 'unknown';
    if ( open my $fh, '<', "$root/VERSION" ) {
        chomp( $version = <$fh> // 'unknown' );
        close $fh;
    }
    my $m       = payload_manifest();
    my $channel = 'unpackaged (no release manifest)';
    $channel = $m->{channel} if $m && length( $m->{channel} // '' );
    $channel .= ', security-critical' if $m && $m->{security_critical};
    print "lazysite $version (channel: $channel, payload: $root)\n";
    return 0;
}

__END__

=head1 NAME

lazysite - host-side management CLI for lazysite sites

=head1 SYNOPSIS

  lazysite provision --docroot D --cgibin C [--domain NAME] [--channel edge|beta|stable|certified]
                     [--policy auto|manual]
  lazysite upgrade --docroot D [--cgibin C] [--force]
  lazysite upgrade --all [--force | --force-security]
  lazysite sites
  lazysite check [args...]
  lazysite users [args...]
  lazysite acl [args...]
  lazysite repair --docroot D | --domain NAME | --all [--dry-run]
  lazysite probe --docroot D | --domain NAME | --all
  lazysite migrate-engine-tree --docroot D | --all [--apply] [--back] [--min-version V]
  lazysite dev [args...]
  lazysite demo [--port N] [--dir PATH]
  lazysite version
  lazysite help

=head1 DESCRIPTION

C<lazysite> is the host-side front door to the lazysite engine payload: a
thin dispatcher over C<install.pl> and the C<tools/> scripts. Installed by
the C<lazysite-common> deb it lives at C</usr/bin/lazysite> with the payload
at C</usr/share/lazysite>; run from a git checkout or unpacked tarball it
locates the payload relative to its own path, so both install shapes behave
identically.

The load-bearing principle (SM139): B<no root writes into site trees>.
C<provision> and single-site C<upgrade> refuse to run as root and tell you
to re-run as the site user; files are then created with the correct
ownership from the start, and no chown-after repair pass is needed. The
exceptions are the verbs that drop to each site's owner (C<sudo -u>) before
touching a site tree: C<upgrade --all>, C<migrate-engine-tree --all> and
C<probe>.

=head1 VERBS

=over 4

=item B<provision> --docroot D --cgibin C [--domain NAME] [--channel edge|beta|stable|certified] [--policy auto|manual]

Fresh-install a site from the host payload (wraps C<install.pl>). Refuses
to run as root. C<--domain> seeds the site URL and names the registry
entry; C<--channel> pins the site's C<update_channel> after the install;
C<--policy> sets the site's C<update_policy> (C<auto> opts the site in to
fleet-wide C<upgrade --all> runs; C<manual>, the default, leaves upgrades
to the sysop). On success the site is recorded in the registry (see
L</REGISTRY>).

=item B<upgrade> --docroot D [--cgibin C] [--force]

Upgrade one site from the host payload, as the site user (refuses root).
When C<--cgibin> is omitted it is taken from the site's registry entry.
C<--force> overrides the site's update-channel policy (recorded in the
site's audit log by C<install.pl>).

=item B<upgrade> --all [--force | --force-security]

Iterate the registry and upgrade every registered site. Run as root it
drops to each site's owner via C<sudo -n -u OWNER>; run as a normal user
it refuses unless every registered site belongs to the caller. Entries
with a missing docroot, a missing C<cgibin=>, or owner C<root> are skipped
with a warning. Exits non-zero if any site failed.

Two per-site gates apply (SM139). B<Policy>: a site whose C<update_policy>
is C<manual> (the default when the key is absent) is skipped - the fleet
run, typically cron-driven, never touches it unless C<--force> is given.
B<Channel>: an C<auto>-policy site still takes an upgrade only when its
C<update_channel> accepts the payload's release channel; that gate lives
in C<install.pl> (a clean exit-3 skip, audited in the site's log), and the
CLI reports it as a skip, not a failure.

C<--force> overrides both gates (the installer records the channel
override in the site's audit log). C<--force-security> also overrides
both, but is accepted B<only> when the payload's F<release-manifest.json>
declares C<"security_critical": true> (stamped at build time with
C<tools/build-manifest.pl --security-critical>); otherwise it refuses
before touching any site - the override is only as strong as the
release's own declaration. This is the fleet answer to "a security fix
must reach every site now".

=item B<sites>

List the registered sites, one line each: name, owner, channel, policy,
installed version and docroot. Channel and policy show the live
C<lazysite.conf> value when readable (falling back to the registry's
cached value); the version is read from each site's
F<lazysite/.install-state.json> (C<-> when not discoverable).

=item B<check> [args...]

Pass-through to C<tools/lazysite-check.pl> (health/permissions doctor),
e.g. C<lazysite check --docroot D --fix> or C<lazysite check --dependencies>.

=item B<users> [args...]

Pass-through to C<tools/lazysite-users.pl> (built-in auth user management),
e.g. C<lazysite users --docroot D list>, C<lazysite acl --docroot D list>.

=item B<acl> [args...]

Pass-through to C<tools/lazysite-acl.pl> (per-path access: who may read or
write a file, a folder, or the whole site). Takes C<--domain NAME> or
C<--all> in place of C<--docroot>, resolved from the registry. Same rules
and same store as the manager, the control API and MCP.

=item B<repair> --docroot D | --domain NAME | --all [--dry-run]

Run the doctor, apply the fixes it can apply, then run it B<again> and
report the state after the repair - "the site is clean afterwards", not
"we ran --fix". C<--dry-run> reports what would be repaired and changes
nothing.

=item B<probe> --docroot D | --domain NAME | --all

Ask each site's live front door whether a protected path is actually
refused, rather than whether the configuration says it should be. Run as
root it drops to the site's owner.

=item B<migrate-engine-tree> --docroot D | --all [--apply] [--back] [--min-version V]

Move a site's F<lazysite/> tree out of the document root to
F<E<lt>docrootE<gt>-lazysite> (SM293). Reports what it would do unless
C<--apply> is given; C<--back> reverses the move. C<--all> walks the
registry and, as root, drops to each site's owner. C<--min-version V>
skips sites below that version, so a fleet can be migrated as the release
rolls through its channels.

=item B<dev> [args...]

Pass-through to C<tools/lazysite-server.pl>, the local development server,
e.g. C<lazysite dev --docroot D --auto-index>.

=item B<demo> [--port N] [--dir PATH]

The zero-argument try-it path: fresh-install a scratch site from the host
payload (the same C<install.pl> run that C<provision> wraps) into
C<--dir> - default F<~/lazysite-demo>, or F<$TMPDIR/lazysite-demo>
without a HOME - as the B<current user> (root is refused, like every
site-tree write), then exec the dev server on C<--port> (default 8080)
and print the URL, where the site lives and how to remove it
(C<rm -rf> the directory). Re-running reuses an existing demo site
instead of reinstalling. The demo site is not recorded in the fleet
registry - it is a throwaway.

=item B<version>

Print the payload version (from C<VERSION>), its release channel (from
C<release-manifest.json>; C<unpackaged> for a bare checkout) and the
payload location.

=back

=head1 REGISTRY

C<provision> records each site as one file at
C</etc/lazysite/sites.d/E<lt>domainE<gt>> in an INI-ish key=value format:

  docroot=/home/user/web/example.com/public_html
  cgibin=/home/user/web/example.com/cgi-bin
  owner=user
  channel=edge
  policy=manual

The deb ships the directory root-owned, so an unprivileged provision run
usually cannot write it: in that case provisioning still succeeds and the
CLI prints the exact file for the admin to drop in place. Reads tolerate
missing or garbled entries (skipped with a warning, never fatal).

C<channel=> and C<policy=> are provision-time caches for fleet tooling;
the authoritative values are the site's own C<update_channel> and
C<update_policy> keys in F<lazysite.conf> (set with C<install.pl
--channel> / C<--policy>), which C<upgrade --all> and C<sites> prefer
whenever the conf is readable.

=head1 ENVIRONMENT

=over 4

=item LAZYSITE_REGISTRY_DIR

Override the registry directory (default C</etc/lazysite/sites.d>). Used
by the test suite and useful on non-FHS hosts.

=item LAZYSITE_CLI_FAKE_ROOT

B<Test-only.> When set, the CLI behaves as if it were running as uid 0 so
the test suite can exercise the root-refusal paths. It only ever makes the
CLI more restrictive; never set it in production.

=item LAZYSITE_DEMO_NO_SERVE

B<Test-only.> When set, C<demo> stops after the install and prints the
dev-server command it would have exec'd, so the test suite can verify the
round-trip without a listening server process. Never set it in
production.

=back

=head1 EXIT STATUS

0 on success; 1 on refusals and failures; 2 on usage errors. Pass-through
verbs forward the wrapped tool's exit status verbatim.

=head1 SEE ALSO

install.pl (lazysite-install(1)), lazysite-check(1), lazysite-users(1),
and F</usr/share/doc/lazysite-common/README.Debian> for the FastCGI pool
unit pattern (lazysite@.service).

=cut
