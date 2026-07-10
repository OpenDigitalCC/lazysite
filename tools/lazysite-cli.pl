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
# provision and single-site upgrade REFUSE to run as root; only
# `upgrade --all` may run as root, because it drops to each site's owner
# (sudo -u) per site. Ownership is correct by construction - no chown-after
# pass, no lazysite-check --fix as a routine step.
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
elsif ( $verb eq 'check' )   { run_tool( 'tools/lazysite-check.pl',  @ARGV ) }
elsif ( $verb eq 'users' )   { run_tool( 'tools/lazysite-users.pl',  @ARGV ) }
elsif ( $verb eq 'dev' )     { run_tool( 'tools/lazysite-server.pl', @ARGV ) }
elsif ( $verb eq 'version' ) { exit cmd_version() }
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
  provision --docroot D --cgibin C [--domain NAME] [--channel edge|stable]
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
  users [args...]        Auth user management (lazysite-users.pl).
  dev [args...]          Local dev server (lazysite-server.pl).
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
            . "(Only 'lazysite upgrade --all' may run as root - it drops to each\n"
            . "site's owner per site.)" );
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
    my $rc = system( $^X, $tool, @args );
    exit 127 if $rc == -1;
    exit( $rc >> 8 );
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
    fail('provision needs --docroot and --cgibin')
        unless length $o{docroot} && length $o{cgibin};
    fail("--channel must be 'edge' or 'stable'")
        if length $o{channel} && $o{channel} !~ /^(?:edge|stable)$/;
    fail("--policy must be 'auto' or 'manual'")
        if length $o{policy} && $o{policy} !~ /^(?:auto|manual)$/;

    my $root = payload_root();
    my @cmd  = ( $^X, "$root/install.pl",
        '--docroot', $o{docroot}, '--cgibin', $o{cgibin} );
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
    fail('upgrade needs --docroot (or --all)') unless length $o{docroot};
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

    my @cmd = ( $^X, payload_root() . '/install.pl',
        '--docroot', $docroot, '--cgibin', $cgibin );
    push @cmd, '--force' if $o{force};
    run_or_fail(@cmd);
    return 0;
}

sub cmd_upgrade_all {
    my ($o) = @_;
    my $sites = read_registry();
    if ( !@$sites ) {
        print 'lazysite: no sites registered in ' . registry_dir() . "\n";
        return 0;
    }
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

    my $root = payload_root();
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
        my @cmd = ( $^X, "$root/install.pl",
            '--docroot', $s->{docroot}, '--cgibin', $s->{cgibin} );
        push @cmd, '--force' if $o->{force};
        # The only place root is allowed: drop to the site's owner per
        # site (sudo -n never prompts; a misconfigured sudo fails loudly).
        unshift @cmd, 'sudo', '-n', '-u', $owner, '--'
            if $is_root && $owner ne $me;
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
sub cmd_sites {
    my $sites = read_registry();
    if ( !@$sites ) {
        print 'lazysite: no sites registered in ' . registry_dir() . "\n";
        return 0;
    }
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

  lazysite provision --docroot D --cgibin C [--domain NAME] [--channel edge|stable]
                     [--policy auto|manual]
  lazysite upgrade --docroot D [--cgibin C] [--force]
  lazysite upgrade --all [--force | --force-security]
  lazysite sites
  lazysite check [args...]
  lazysite users [args...]
  lazysite dev [args...]
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
single exception is C<upgrade --all>, which may run as root because it
drops to each site's owner (C<sudo -u>) per site.

=head1 VERBS

=over 4

=item B<provision> --docroot D --cgibin C [--domain NAME] [--channel edge|stable] [--policy auto|manual]

Fresh-install a site from the host payload (wraps C<install.pl>). Refuses
to run as root. C<--domain> seeds the site URL and names the registry
entry; C<--channel> pins the site's C<update_channel> after the install;
C<--policy> sets the site's C<update_policy> (C<auto> opts the site in to
fleet-wide C<upgrade --all> runs; C<manual>, the default, leaves upgrades
to the operator). On success the site is recorded in the registry (see
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
e.g. C<lazysite users --docroot D list>.

=item B<dev> [args...]

Pass-through to C<tools/lazysite-server.pl>, the local development server,
e.g. C<lazysite dev --docroot D --auto-index>.

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

=back

=head1 EXIT STATUS

0 on success; 1 on refusals and failures; 2 on usage errors. Pass-through
verbs forward the wrapped tool's exit status verbatim.

=head1 SEE ALSO

install.pl (lazysite-install(1)), lazysite-check(1), lazysite-users(1),
and F</usr/share/doc/lazysite-common/README.Debian> for the FastCGI pool
unit pattern (lazysite@.service).

=cut
