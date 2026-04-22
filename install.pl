#!/usr/bin/perl
# install.pl - lazysite installer (D021c)
#
# Upgrade-safe installer driven by release-manifest.json. Reads
# release-manifest.json at the tarball root, tracks installed
# state in {DOCROOT}/lazysite/.install-state.json, and makes
# upgrade decisions per file based on the classification bucket:
#
#   code: always overwritten on upgrade
#   seed: overwritten only if on-disk SHA matches the state file
#         (i.e. the operator has not edited it)
#
# Runtime directories come from the manifest's runtime_paths
# array. Some install steps are not manifest-expressible and stay
# imperative (cgi-bin symlinks for plugin endpoints, manager CSS
# duplicate, auth users/groups seed, nav.conf seed,
# lazysite.conf conditional write, SGID on lazysite/).
#
# Restore via --restore extracts a backup tarball produced on a
# prior upgrade.
#
# Core-only Perl; no CPAN deps. Shells out to `tar` for backup
# creation and extraction.

use strict;
use warnings;
use File::Copy ();
use File::Path qw(make_path remove_tree);
use File::Find ();
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir);
use Digest::SHA ();
use JSON::PP ();
use POSIX qw(strftime);
use Getopt::Long ();
use Cwd qw(abs_path);

my $STAGE_DIR = abs_path(dirname($0));

# ---------- arg parse ----------

my %opt = (
    docroot      => '',
    cgibin       => '',
    domain       => '',
    theme        => '',
    help         => 0,
    restore      => 0,
    backup       => '',
    list_backups => 0,
    dry_run      => 0,
);

sub usage {
    my ($rc) = @_;
    print <<'USAGE';
Usage: install.pl --docroot PATH --cgibin PATH [options]

Install or upgrade lazysite in-place. On first run, creates a
fresh installation from the shipped manifest. On subsequent
runs, upgrades while preserving operator-edited content (pages,
custom docs) and overwriting project-owned code.

Required (for install/upgrade):
  --docroot PATH      Path to web document root
  --cgibin  PATH      Path to cgi-bin directory

Optional:
  --domain  NAME      Domain name for lazysite.conf site_url
                      (used only when seeding a new lazysite.conf)
  --dry-run           Compute the plan without executing any
                      filesystem changes. Useful before upgrade.
  --help              Show this help

Maintenance modes:
  --list-backups      List available backups at
                      {docroot}/lazysite/backups/
  --restore           Restore the most recent backup
  --restore --backup PATH
                      Restore a specific backup tarball

Example:
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin --domain example.com
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin --dry-run

Upgrade notes:
  Seed files you have edited (pages, docs, forms config) are
  preserved across upgrades. Code files are always refreshed.
  Pre-upgrade backups accumulate under
  {docroot}/lazysite/backups/ per backup_retention
  (lazysite.conf; default 3).
USAGE
    exit( $rc // 0 );
}

# No args = help (matches install.sh behaviour)
usage(0) unless @ARGV;

Getopt::Long::Configure('no_ignore_case', 'bundling_override');
Getopt::Long::GetOptions(
    'docroot=s'     => \$opt{docroot},
    'cgibin=s'      => \$opt{cgibin},
    'domain=s'      => \$opt{domain},
    'theme=s'       => \$opt{theme},
    'help'          => \$opt{help},
    'restore'       => \$opt{restore},
    'backup=s'      => \$opt{backup},
    'list-backups'  => \$opt{list_backups},
    'dry-run'       => \$opt{dry_run},
) or usage(1);

usage(0) if $opt{help};

if ( $opt{theme} ) {
    warn "WARNING: --theme is no longer supported. install.pl "
       . "does not fetch remote themes. Upload themes via the "
       . "manager UI at /manager/themes.\n";
}

# --- mode dispatch ---

if ( $opt{list_backups} ) {
    die "--list-backups requires --docroot\n" unless $opt{docroot};
    exit cmd_list_backups( $opt{docroot} );
}

if ( $opt{restore} ) {
    die "--restore requires --docroot\n" unless $opt{docroot};
    exit cmd_restore( \%opt );
}

# Install / upgrade path.
die "--docroot is required\n" unless $opt{docroot};
die "--cgibin is required\n"  unless $opt{cgibin};

# Absolute paths to avoid surprises when cwd is not the install root.
$opt{docroot} = abs_path( $opt{docroot} ) // $opt{docroot};
$opt{cgibin}  = abs_path( $opt{cgibin} )  // $opt{cgibin};

exit cmd_install( \%opt );

# =========================================================
# ---------- install / upgrade command ----------
# =========================================================

sub cmd_install {
    my ($o) = @_;

    my $manifest = load_manifest("$STAGE_DIR/release-manifest.json");
    info("Installer: lazysite $manifest->{version}");

    my $state_path = state_path( $o->{docroot} );
    my $state      = load_state($state_path);

    my $mode;
    if ( !defined $state ) {
        $mode = 'fresh';
    }
    elsif ( $state->{version} eq $manifest->{version} ) {
        $mode = 'reinstall';
    }
    else {
        $mode = 'upgrade';
    }

    info("Mode: $mode");
    info("  docroot: $o->{docroot}");
    info("  cgibin:  $o->{cgibin}");
    if ( $mode ne 'fresh' ) {
        info("  from:    $state->{version}");
        info("  to:      $manifest->{version}");
    }

    my %subs = placeholders( $o->{docroot}, $o->{cgibin} );

    # ---- plan ----
    my $plan = compute_plan( $manifest, $state, \%subs );
    if ( $o->{dry_run} ) {
        print_plan( $plan, $manifest, \%subs );
        info("--dry-run: no changes made.");
        return 0;
    }

    # ---- backup (upgrade or reinstall only) ----
    my $backup_path;
    if ( $mode ne 'fresh' ) {
        my $backup_dir = "$o->{docroot}/lazysite/backups";
        make_path($backup_dir);
        $backup_path = create_backup(
            $state, $backup_dir, $state_path, $manifest->{version},
        );
        info("Backup: $backup_path");
    }

    # ---- runtime paths ----
    create_runtime_paths( $manifest->{runtime_paths} || [], \%subs );

    # ---- execute plan ----
    my ( $state_files, $plan_stats, $warnings ) = execute_plan( $plan );

    # ---- imperative post-steps ----
    post_install_steps( $o, $manifest, \%subs, $state_files, $mode, $plan_stats );

    # ---- write new state ----
    write_state( $state_path, $manifest->{version}, $state_files );

    # ---- retention ----
    if ( $mode ne 'fresh' ) {
        my $retention = read_retention( $o->{docroot} );
        apply_retention( "$o->{docroot}/lazysite/backups", $retention );
    }

    # ---- summary ----
    print_summary( $mode, $manifest, $plan_stats, $backup_path, $warnings );
    print_dep_check();
    print_next_steps( $o->{docroot} );

    return 0;
}

# =========================================================
# ---------- plan computation ----------
# =========================================================

sub compute_plan {
    my ( $manifest, $state, $subs ) = @_;

    my $stored_files = $state ? ( $state->{files} || {} ) : {};

    my @plan;
    my %manifest_installs;

    for my $entry ( @{ $manifest->{files} } ) {
        next unless defined $entry->{install_to};    # null = tarball-only

        my $dest   = resolve_placeholders( $entry->{install_to}, $subs );
        my $source = "$STAGE_DIR/$entry->{path}";
        $manifest_installs{$dest} = 1;

        if ( !exists $stored_files->{$dest} ) {
            push @plan, {
                action => 'install',
                source => $source,
                dest   => $dest,
                bucket => $entry->{bucket},
                path   => $entry->{path},
            };
            next;
        }

        my $stored = $stored_files->{$dest} // '';
        my $on_disk = -f $dest ? 'sha256:' . sha256_of($dest) : '';

        if ( $on_disk eq $stored ) {
            # unedited
            push @plan, {
                action => 'overwrite',
                source => $source,
                dest   => $dest,
                bucket => $entry->{bucket},
                path   => $entry->{path},
            };
        }
        else {
            # user-edited
            if ( ( $entry->{bucket} // '' ) eq 'code' ) {
                push @plan, {
                    action      => 'overwrite',
                    source      => $source,
                    dest        => $dest,
                    bucket      => 'code',
                    was_edited  => 1,
                    path        => $entry->{path},
                };
            }
            else {
                push @plan, {
                    action => 'preserve',
                    dest   => $dest,
                    bucket => $entry->{bucket},
                    path   => $entry->{path},
                };
            }
        }
    }

    # Files in the stored state but not in the new manifest.
    if ( keys %$stored_files ) {
        for my $dest ( sort keys %$stored_files ) {
            next if $manifest_installs{$dest};

            if ( !-e $dest ) {
                push @plan, { action => 'already_gone', dest => $dest };
                next;
            }

            my $stored = $stored_files->{$dest};
            my $on_disk = 'sha256:' . sha256_of($dest);
            if ( $on_disk eq $stored ) {
                push @plan, { action => 'remove', dest => $dest };
            }
            else {
                push @plan, { action => 'orphan_warn', dest => $dest };
            }
        }
    }

    return \@plan;
}

sub print_plan {
    my ( $plan, $manifest, $subs ) = @_;
    my %by_action;
    push @{ $by_action{ $_->{action} } }, $_ for @$plan;
    print "\n--- Plan ---\n";
    for my $action (qw(install overwrite preserve remove orphan_warn already_gone)) {
        my $items = $by_action{$action} or next;
        my $count = scalar @$items;
        print "  $action: $count\n";
        if ( $action eq 'preserve' || $action eq 'orphan_warn' ) {
            print "    - $_->{dest}\n" for @$items;
        }
    }
    print "\nRuntime paths:\n";
    for my $rp ( @{ $manifest->{runtime_paths} || [] } ) {
        my $resolved = resolve_placeholders( $rp->{path}, $subs );
        print "  $rp->{mode} $resolved  ($rp->{purpose})\n";
    }
    print "\n";
}

# =========================================================
# ---------- plan execution ----------
# =========================================================

sub execute_plan {
    my ($plan) = @_;

    my %state_files;
    my %stats = (
        installed  => 0,
        overwrote  => 0,
        preserved  => [],
        removed    => 0,
        orphaned   => [],
    );
    my @warnings;

    for my $step (@$plan) {
        my $a = $step->{action};

        if ( $a eq 'install' ) {
            install_file( $step->{source}, $step->{dest} );
            $state_files{ $step->{dest} } = 'sha256:' . sha256_of( $step->{dest} );
            $stats{installed}++;
        }
        elsif ( $a eq 'overwrite' ) {
            install_file( $step->{source}, $step->{dest} );
            $state_files{ $step->{dest} } = 'sha256:' . sha256_of( $step->{dest} );
            $stats{overwrote}++;
        }
        elsif ( $a eq 'preserve' ) {
            # Keep on-disk contents; record current SHA in new state
            # so next upgrade's preservation check is accurate.
            $state_files{ $step->{dest} } = 'sha256:' . sha256_of( $step->{dest} );
            push @{ $stats{preserved} }, $step->{dest};
        }
        elsif ( $a eq 'remove' ) {
            unlink $step->{dest}
                or warn "  warn: could not unlink $step->{dest}: $!\n";
            # Also remove any stale .html cache for .md sources.
            if ( $step->{dest} =~ /\.md$/ ) {
                ( my $cached = $step->{dest} ) =~ s/\.md$/.html/;
                unlink $cached if -f $cached;
            }
            $stats{removed}++;
        }
        elsif ( $a eq 'already_gone' ) {
            # No-op, not in new state.
        }
        elsif ( $a eq 'orphan_warn' ) {
            push @{ $stats{orphaned} }, $step->{dest};
            push @warnings, "orphan (edited post-install, left in place): $step->{dest}";
        }
    }

    return ( \%state_files, \%stats, \@warnings );
}

sub install_file {
    my ( $src, $dest ) = @_;
    make_path( dirname($dest) );
    File::Copy::copy( $src, $dest )
        or die "Failed to copy $src -> $dest: $!\n";
    chmod mode_for($dest), $dest;
}

sub mode_for {
    my ($path) = @_;
    return 0755 if $path =~ /\.(pl|sh)$/;
    return 0640 if $path =~ m{/lazysite/auth/};
    return 0644;
}

# =========================================================
# ---------- imperative post-install steps ----------
# =========================================================

sub post_install_steps {
    my ( $o, $manifest, $subs, $state_files, $mode, $stats ) = @_;

    my $docroot = $o->{docroot};
    my $cgibin  = $o->{cgibin};
    my $plugin_dir = resolve_placeholders( '{DOCROOT}/../plugins', $subs );

    # --- cgi-bin symlinks for plugin endpoints ---
    #
    # form-handler and payment-demo need /cgi-bin/<name>.pl presence
    # so Apache routes POSTs at them. Symlink from plugins; fall
    # back to install if symlink unsupported (some shared hosts).
    # These paths are NOT tracked in .install-state.json - they are
    # links to files that ARE tracked.
    for my $plugin (qw(form-handler payment-demo)) {
        my $src = "$plugin_dir/$plugin.pl";
        my $dst = "$cgibin/$plugin.pl";
        next unless -f $src;
        if ( -e $dst || -l $dst ) {
            # Already present from earlier install; refresh.
            unlink $dst;
        }
        if ( symlink( $src, $dst ) ) {
            info("  linked:    $dst -> $src");
        }
        else {
            File::Copy::copy( $src, $dst )
                or die "Could not install $dst: $!\n";
            chmod 0755, $dst;
            info("  installed: $dst (symlink unsupported)");
        }
    }

    # --- manager CSS duplicate ---
    #
    # The manager CSS source ships at lazysite/themes/manager/assets/
    # and the manager UI expects it web-accessible at
    # manager/assets/manager.css. The manifest ships the source copy;
    # this step mirrors it to the web-accessible path.
    #
    # Derived path: NOT tracked in .install-state.json. It is
    # rebuilt from the installed source on every install/upgrade,
    # so tracking it would cause the next run to falsely flag it
    # as "in stored but not in manifest" and mark it for removal.
    my $css_src = "$docroot/lazysite/themes/manager/assets/manager.css";
    my $css_dst = "$docroot/manager/assets/manager.css";
    if ( -f $css_src ) {
        make_path( dirname($css_dst) );
        File::Copy::copy( $css_src, $css_dst )
            or die "Could not install $css_dst: $!\n";
        chmod 0644, $css_dst;
    }

    # --- auth users/groups: seed from .example on fresh install ---
    #
    # Runtime state. Not tracked in .install-state.json. On upgrade
    # the live files are left alone (operator-edited); we do nothing.
    if ( $mode eq 'fresh' ) {
        for my $f (qw(users groups)) {
            my $src = "$docroot/lazysite/auth/$f.example";
            my $dst = "$docroot/lazysite/auth/$f";
            if ( -f $src && !-f $dst ) {
                File::Copy::copy( $src, $dst )
                    or die "Could not seed auth/$f: $!\n";
                chmod 0640, $dst;
                info("  seeded:    lazysite/auth/$f (from $f.example)");
            }
        }
    }

    # --- nav.conf: seed from .example on fresh install ---
    if ( $mode eq 'fresh' ) {
        my $src = "$STAGE_DIR/starter/nav.conf.example";
        my $dst = "$docroot/lazysite/nav.conf";
        if ( -f $src && !-f $dst ) {
            File::Copy::copy( $src, $dst )
                or die "Could not seed nav.conf: $!\n";
            chmod 0644, $dst;
            info("  seeded:    lazysite/nav.conf (from nav.conf.example)");
        }
    }

    # --- lazysite.conf: write on fresh install ---
    #
    # If --domain, write a minimal conf with templated site_name /
    # site_url. Otherwise, install the .example as the live conf.
    if ( $mode eq 'fresh' ) {
        my $conf = "$docroot/lazysite/lazysite.conf";
        if ( !-f $conf ) {
            if ( length $o->{domain} ) {
                write_text(
                    $conf,
                    "# lazysite.conf - site configuration\n"
                  . "# See https://lazysite.io/docs for reference\n\n"
                  . "site_name: $o->{domain}\n"
                  . "site_url: \${REQUEST_SCHEME}://$o->{domain}\n"
                );
                info("  wrote:     lazysite/lazysite.conf (from --domain)");
            }
            else {
                my $src = "$STAGE_DIR/starter/lazysite.conf.example";
                if ( -f $src ) {
                    File::Copy::copy( $src, $conf )
                        or die "Could not seed lazysite.conf: $!\n";
                    info("  seeded:    lazysite/lazysite.conf (from example)");
                }
            }
            chmod 0644, $conf if -f $conf;
        }
    }

    # --- SGID on the lazysite/ subtree (not whole docroot) ---
    my $laz = "$docroot/lazysite";
    if ( -d $laz ) {
        my $mode_now = ( stat $laz )[2] & 07777;
        my $want = $mode_now | 02020;    # g+ws
        if ( $mode_now != $want ) {
            chmod $want, $laz;
        }
    }
}

# =========================================================
# ---------- runtime paths ----------
# =========================================================

sub create_runtime_paths {
    my ( $rps, $subs ) = @_;
    for my $rp (@$rps) {
        my $path = resolve_placeholders( $rp->{path}, $subs );
        my $mode = oct( $rp->{mode} );
        if ( -d $path ) {
            # Directory exists; do not chmod. Operators may have
            # tightened it. Only chmod when we create.
            next;
        }
        make_path( $path, { mode => $mode } );
        chmod $mode, $path;    # make_path honours mode on creation
    }
}

# =========================================================
# ---------- backup / restore ----------
# =========================================================

sub create_backup {
    my ( $state, $backup_dir, $state_path, $new_version ) = @_;

    my $ts = strftime( '%Y%m%d-%H%M%S', gmtime );
    my $name = "lazysite-backup-$ts-pre-$new_version.tar.gz";
    my $out  = "$backup_dir/$name";

    # Collect the set of files to back up: everything in the current
    # .install-state.json plus .install-state.json itself. Missing
    # files are skipped with a warning (stale state).
    my @paths;
    for my $path ( sort keys %{ $state->{files} || {} } ) {
        if ( -f $path ) {
            push @paths, $path;
        }
        else {
            warn "  backup: missing $path (recorded in state but not on disk; skipped)\n";
        }
    }
    push @paths, $state_path if -f $state_path;

    unless ( @paths ) {
        die "Backup: no files to archive. Aborting upgrade to avoid unrecoverable state.\n";
    }

    # Build a file list for tar --files-from. Paths are absolute;
    # tar strips leading / by default. Restore re-adds it.
    my $listfile = "$backup_dir/.backup-list-$$";
    open my $lfh, '>', $listfile
        or die "Backup: could not write $listfile: $!\n";
    for my $p (@paths) { print $lfh "$p\n" }
    close $lfh;

    my @cmd = (
        'tar',
        '--absolute-names',
        '-czf', $out,
        '--files-from', $listfile,
    );
    my $rc = system(@cmd);
    unlink $listfile;

    if ( $rc != 0 ) {
        unlink $out if -f $out;
        die "Backup: tar failed (rc=$rc). Aborting upgrade. Your system is unchanged.\n";
    }

    return $out;
}

sub cmd_list_backups {
    my ($docroot) = @_;
    my $dir = "$docroot/lazysite/backups";
    unless ( -d $dir ) {
        print "No backups directory at $dir.\n";
        return 0;
    }
    my @files = sort glob("$dir/lazysite-backup-*.tar.gz");
    unless (@files) {
        print "No backups at $dir.\n";
        return 0;
    }
    printf "%-60s  %12s  %s\n", 'Backup', 'Size', 'Modified';
    for my $f (@files) {
        my @st   = stat $f;
        my $size = $st[7];
        my $mtime = strftime( '%Y-%m-%d %H:%M:%S UTC', gmtime $st[9] );
        printf "%-60s  %12d  %s\n", basename($f), $size, $mtime;
    }
    return 0;
}

sub cmd_restore {
    my ($o) = @_;

    my $backup_path;
    if ( length $o->{backup} ) {
        $backup_path = abs_path( $o->{backup} ) // $o->{backup};
        die "Backup not found: $backup_path\n" unless -f $backup_path;
    }
    else {
        my $dir = "$o->{docroot}/lazysite/backups";
        my @files = sort glob("$dir/lazysite-backup-*.tar.gz");
        die "No backups at $dir\n" unless @files;
        $backup_path = $files[-1];    # most recent (lexicographic == chronological)
    }

    info("Restoring from: $backup_path");

    # Extract into a temp dir. Do NOT pass --absolute-names at
    # extract: tar must strip leading / and land files under $tmp
    # so we can explicitly copy them to their real destinations.
    # Otherwise tar would write to the absolute paths directly and
    # bypass our state-driven restore logic (and the security
    # benefit of staging in a temp dir first).
    my $tmp = tempdir( 'lazysite-restore-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $rc = system(
        'tar',
        '-xzf', $backup_path,
        '-C',    $tmp,
    );
    die "tar -x failed (rc=$rc)\n" if $rc != 0;

    # The tar stripped the leading "/" from paths, so the content
    # lives at $tmp/<abs-path-without-leading-slash>.
    my $state_rel  = state_path( $o->{docroot} );
    $state_rel =~ s{^/+}{};
    my $state_copy = "$tmp/$state_rel";
    die "Backup is missing .install-state.json at $state_copy\n"
        unless -f $state_copy;

    my $backup_state = load_state($state_copy);
    my $files = $backup_state->{files} || {};

    my $restored = 0;
    for my $dest ( sort keys %$files ) {
        ( my $rel = $dest ) =~ s{^/+}{};
        my $src = "$tmp/$rel";
        unless ( -f $src ) {
            warn "  skip (missing in backup): $dest\n";
            next;
        }
        make_path( dirname($dest) );
        if ( -e $dest ) {
            unlink $dest
                or warn "  warn: could not remove existing $dest: $!\n";
        }
        File::Copy::copy( $src, $dest )
            or die "Could not restore $dest: $!\n";
        chmod mode_for($dest), $dest;
        $restored++;
    }

    # Rewrite .install-state.json from the backup.
    my $state_path = state_path( $o->{docroot} );
    make_path( dirname($state_path) );
    File::Copy::copy( $state_copy, $state_path )
        or die "Could not write $state_path: $!\n";
    chmod 0644, $state_path;

    # Invalidate rendered .html cache: content at the pre-upgrade
    # version may reference state that no longer matches.
    my $cache = "$o->{docroot}/lazysite/cache";
    if ( -d $cache ) {
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_ && /\.html$/;
                    unlink $_ or warn "  warn: could not unlink $_: $!\n";
                },
            },
            $cache,
        );
        info("  cleared:   lazysite/cache/ (rendered HTML invalidated)");
    }

    info("");
    info("Restore complete.");
    info("  Version:  $backup_state->{version}");
    info("  Files:    $restored restored");
    info("  Runtime:  untouched (auth, logs, locks, etc.)");
    info("");

    return 0;
}

# =========================================================
# ---------- retention ----------
# =========================================================

sub read_retention {
    my ($docroot) = @_;
    my $conf = "$docroot/lazysite/lazysite.conf";
    my $default = 3;
    return $default unless -f $conf;
    open my $fh, '<', $conf or return $default;
    my $val = $default;
    while (<$fh>) {
        if ( /^backup_retention\s*:\s*(\S+)/ ) {
            my $v = $1;
            if ( $v =~ /^\d+$/ ) {
                $val = $v + 0;
                last;
            }
            close $fh;
            die "lazysite.conf: backup_retention must be a non-negative integer (got '$v')\n";
        }
    }
    close $fh;
    return $val;
}

sub apply_retention {
    my ( $dir, $retention ) = @_;
    return if $retention == 0;
    my @backups = sort glob("$dir/lazysite-backup-*.tar.gz");
    # Sort by mtime ascending (oldest first) in case lexical and
    # chronological diverge (shouldn't, but defensive).
    @backups = sort { ( stat $a )[9] <=> ( stat $b )[9] } @backups;
    my $excess = @backups - $retention;
    return if $excess <= 0;
    for my $i ( 0 .. $excess - 1 ) {
        unlink $backups[$i]
            or warn "  warn: could not remove $backups[$i]: $!\n";
        info( "  retired:   " . basename( $backups[$i] ) );
    }
}

# =========================================================
# ---------- state i/o ----------
# =========================================================

sub state_path {
    my ($docroot) = @_;
    return "$docroot/lazysite/.install-state.json";
}

sub load_state {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path
        or die "Cannot read state $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    my $parsed = eval { JSON::PP::decode_json($text) }
        or die "Cannot parse state $path: $@\n";
    return $parsed;
}

sub write_state {
    my ( $path, $version, $files ) = @_;
    my $data = {
        schema_version => '1',
        version        => $version,
        installed_at   => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        files          => $files,
    };
    make_path( dirname($path) );
    my $json = JSON::PP->new->utf8(1)->pretty(1)->indent_length(2)
                   ->canonical(1)->encode($data);
    open my $fh, '>:raw', $path
        or die "Cannot write state $path: $!\n";
    print $fh $json;
    close $fh;
    chmod 0644, $path;
}

sub load_manifest {
    my ($path) = @_;
    die "release-manifest.json not found at $path\n" unless -f $path;
    open my $fh, '<:raw', $path
        or die "Cannot read $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    my $parsed = eval { JSON::PP::decode_json($text) }
        or die "Cannot parse $path: $@\n";
    return $parsed;
}

# =========================================================
# ---------- helpers ----------
# =========================================================

sub placeholders {
    my ( $docroot, $cgibin ) = @_;
    return (
        DOCROOT => $docroot,
        CGIBIN  => $cgibin,
    );
}

sub resolve_placeholders {
    my ( $template, $subs ) = @_;
    my $out = $template;
    for my $k ( keys %$subs ) {
        $out =~ s/\{\Q$k\E\}/$subs->{$k}/g;
    }
    # Collapse any "/../" sequences where the docroot placeholder
    # introduced them (e.g. {DOCROOT}/../plugins), by normalising
    # through a simple textual pass. Do NOT use abs_path here - the
    # directory may not exist yet.
    $out =~ s{/[^/]+/\.\./}{/}g;
    return $out;
}

sub sha256_of {
    my ($path) = @_;
    my $sha = Digest::SHA->new('sha256');
    $sha->addfile( $path, 'b' );
    return $sha->hexdigest;
}

sub write_text {
    my ( $path, $text ) = @_;
    make_path( dirname($path) );
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print $fh $text;
    close $fh;
}

sub info {
    my ($msg) = @_;
    print STDERR "$msg\n";
}

# =========================================================
# ---------- summary + dep check + next steps ----------
# =========================================================

sub print_summary {
    my ( $mode, $manifest, $stats, $backup_path, $warnings ) = @_;
    print STDERR "\n=== Install summary ($mode) ===\n";
    print STDERR "  Version:    $manifest->{version}\n";
    print STDERR "  Installed:  $stats->{installed}\n";
    print STDERR "  Overwrote:  $stats->{overwrote}\n";
    my $pcount = scalar @{ $stats->{preserved} };
    print STDERR "  Preserved:  $pcount";
    print STDERR " (operator-edited)" if $pcount;
    print STDERR "\n";
    if ($pcount) {
        print STDERR "    - $_\n" for @{ $stats->{preserved} };
    }
    print STDERR "  Removed:    $stats->{removed}\n";
    my $ocount = scalar @{ $stats->{orphaned} };
    if ($ocount) {
        print STDERR "  Orphans:    $ocount (edited post-install, left in place):\n";
        print STDERR "    - $_\n" for @{ $stats->{orphaned} };
    }
    print STDERR "  Backup:     $backup_path\n" if $backup_path;
    if ( @$warnings ) {
        print STDERR "\nWarnings:\n";
        print STDERR "  $_\n" for @$warnings;
    }
    print STDERR "\n";
}

sub print_dep_check {
    my @missing;
    for my $check (
        [ 'Archive::Zip',                 'libarchive-zip-perl',
          'theme upload (manager UI)' ],
        [ 'Template::Plugin::JSON::Escape', 'libtemplate-plugin-json-escape-perl',
          'search index (search-index.md)' ],
    ) {
        my ( $mod, $pkg, $feature ) = @$check;
        my $rc = system("perl -M$mod -e 1 2>/dev/null");
        push @missing, [ $mod, $pkg, $feature ] if $rc != 0;
    }
    return unless @missing;
    print STDERR "Missing optional Perl modules:\n";
    for my $m (@missing) {
        print STDERR "  $m->[0]    # $m->[2]\n";
    }
    print STDERR "\nOn Debian/Ubuntu:\n";
    my $pkgs = join ' ', map { $_->[1] } @missing;
    print STDERR "  sudo apt-get install $pkgs\n\n";
}

sub print_next_steps {
    my ($docroot) = @_;
    print STDERR <<"TEXT";
Next steps:
  1. Upload a theme via the manager UI at /manager/themes.
     A fresh install has no default view.tt - the processor
     falls back to a built-in template until a theme is
     activated via /manager/config.
  2. Edit $docroot/lazysite/lazysite.conf to configure your site.
  3. Replace $docroot/index.md with your content.

TEXT
}
