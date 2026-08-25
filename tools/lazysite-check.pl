#!/usr/bin/perl
# lazysite-check - install health / permissions doctor.
#
# Verifies that a lazysite docroot is set up so the (no-suexec, www-data) CGI
# can read its config and write the things it must write (cache, logs, locks,
# secrets), that secrets are not world-exposed, and that the manager is
# bootstrapped. Reports OK / WARN / FAIL per check with a remediation hint;
# exits non-zero if anything FAILs. With --fix it applies the safe fixes
# (chmod always; chown only when run as root) and then RE-RUNS every check, so
# the printed report reflects the post-fix state (SM139 increment 5 - the old
# pre-fix snapshot misled operators in the field).
#
# Effective-access checks are evaluated as the CGI identity via ownership+mode
# arithmetic, never via -r/-w/-x: run as root those answer for root, which
# bypasses DAC and silently passes files the www-data CGI cannot touch.
#
#   perl tools/lazysite-check.pl --docroot /path/to/public_html [--fix]
#   options: --cgibin PATH  --owner USER  --group GROUP  --fix  --help
#
# Core-Perl only.
use strict;
use warnings;
use Cwd        qw(abs_path);
use File::Find ();
use JSON::PP   ();             # core; every call site is fully qualified

my %opt = ( docroot => undef, cgibin => undef, owner => undef,
    group        => undef, fix => 0, check_dav => undef, check_acl => undef,
    dependencies => 0 );

# SM285 probe state. Declared HERE, at the top, because this file's main body
# exits before its sub definitions are reached - so a `my` down beside the subs
# never executes. That is not a style point: the first version of the probe put
# its extension list down there, the list was empty when the probe ran, and it
# reported a leaking front end healthy. perlcritic flags the same hazard as
# unreachable code. Anything the probe needs at runtime is declared up here.
my $PROBE_DIR;    # absolute path of the probe directory
my $PROBE_KEY;    # the ACL key we added, so an interrupt can withdraw it

while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--docroot' )       { $opt{docroot}       = shift @ARGV }
    elsif ( $a eq '--cgibin' )        { $opt{cgibin}        = shift @ARGV }
    elsif ( $a eq '--owner' )         { $opt{owner}         = shift @ARGV }
    elsif ( $a eq '--group' )         { $opt{group}         = shift @ARGV }
    elsif ( $a eq '--fix' )           { $opt{fix}           = 1 }
    elsif ( $a eq '--check-dav' )     { $opt{check_dav}     = shift @ARGV }
    elsif ( $a eq '--check-acl' )     { $opt{check_acl}     = shift @ARGV }
    elsif ( $a eq '--dependencies' )  { $opt{dependencies}  = 1 }
    elsif ( $a eq '--handover-mode' ) { $opt{handover_mode} = shift @ARGV }
    elsif ( $a eq '--help' )          { usage(); exit 0 }
    else { print STDERR "lazysite-check.pl: unknown option '$a'\n"; exit 2 }
}

# SM126 D: host-dependency query. A standalone check of the OS-level Perl
# modules lazysite needs (from dist/config/sbom-deps.json) - no docroot needed,
# so it runs before the docroot validation below. An operator (or an onboarding
# agent) can ask "what must I install here" and get the missing-package line.
run_dependency_check() if $opt{dependencies};    # exits

# Introspection for the regression tests (the chown-handover logic is only
# reachable as root): print what handover_mode() computes for an octal mode.
if ( defined $opt{handover_mode} ) {
    printf "%04o\n", handover_mode( oct( $opt{handover_mode} ) );
    exit 0;
}

sub usage {
    print <<'USAGE';
lazysite-check - install health / permissions doctor

Usage: perl tools/lazysite-check.pl --docroot PATH [options]

  --docroot PATH   the site's public_html (required)
  --cgibin PATH    the cgi-bin dir (default: <docroot>/../cgi-bin)
  --owner USER     expected owner (default: the owner of the docroot)
  --group GROUP    expected group (default: the group of the docroot)
  --fix            apply the safe fixes (chmod always; chown only as root),
                   then re-run the checks - the report shows the post-fix state.
                   On the docroot's own content directories it restores GROUP
                   WRITE and nothing else: without it the CGI cannot save, and
                   every other bit is your choice, not the model's (SM274). A
                   mode that differs any other way is reported, never changed.
  --check-dav URL  probe URL/dav/ unauthenticated; expect 401 (route wired), not
                   404 (route missing - the web server / proxy does not forward /dav/)
  --check-acl URL  ask whether PROTECTED CONTENT is reachable: briefly gate a
                   probe folder, fetch it anonymously from URL under several
                   file extensions, and FAIL if any bytes come back. Several
                   extensions on purpose - SM283 leaked .png/.pdf/.txt and
                   gated .dat, so a one-extension probe reports OK on a leaking
                   site. Writes a temporary entry to the ACL store and removes
                   it, including after an interrupt.
  --dependencies   report the OS Perl packages lazysite needs (present vs missing)
                   and the install line for whatever is absent; no docroot needed
  --help           this help

Exit status is non-zero if any check FAILs.
USAGE
}

# SM126 D: report required non-core Perl modules vs what is present on this host,
# reading the authoritative list from dist/config/sbom-deps.json. Informational
# (always exits 0); the doc docs/reference/host-dependencies.md is generated from
# the same source by tools/gen-host-deps.pl.
sub run_dependency_check {
    my $self = abs_path($0);
    ( my $tools = $self )  =~ s{/[^/]*$}{};
    ( my $root  = $tools ) =~ s{/[^/]*$}{};
    my $deps_path = "$root/dist/config/sbom-deps.json";
    unless ( -f $deps_path ) {
        print STDERR "lazysite-check.pl: dependency metadata not found at $deps_path\n"
            . "  (run this from a lazysite source tree or release tarball)\n";
        exit 2;
    }
    open my $fh, '<', $deps_path
        or do { print STDERR "lazysite-check.pl: cannot read $deps_path: $!\n"; exit 2 };
    my $json = do { local $/; <$fh> };
    close $fh;
    my $data    = JSON::PP->new->decode($json);
    my $modules = $data->{modules} || {};

    print "lazysite host dependencies (from dist/config/sbom-deps.json)\n\n";
    print "Non-core Perl modules:\n";
    my ( $present, $total, %missing_pkg );
    for my $mod ( sort keys %{$modules} ) {
        my $m = $modules->{$mod};
        next if $m->{core};
        $total++;
        ( my $file = $mod ) =~ s{::}{/}g;
        # Probe a module named in the trusted local SBOM file; block-form require
        # of a path string, no injection surface.
        my $ok = eval { require "$file.pm"; 1 }; ## no critic (Modules::RequireBarewordIncludes)
        if ($ok) {
            $present++;
            printf "  %-8s %-22s %s\n", 'OK', $mod, ( $m->{debian_pkg} // '' );
        }
        else {
            my $pkg = $m->{debian_pkg} // '';
            $missing_pkg{$pkg} = 1 if length $pkg;
            printf "  %-8s %-22s %-26s (%s)\n", 'MISSING', $mod, $pkg,
                ( $m->{used_by} // '' );
        }
    }

    if ( my $env = $data->{environment} ) {
        print "\nRuntime environment (operator-provided):\n";
        printf "  %-20s %s\n", $_->{name} // '', $_->{description} // '' for @{$env};
    }

    print "\n$present of $total non-core modules present.\n";
    if (%missing_pkg) {
        print "Missing - on Debian/Ubuntu install with:\n\n";
        print "  sudo apt-get install " . join( ' ', sort keys %missing_pkg ) . "\n";
    }
    else {
        print "All required non-core modules are installed.\n";
    }
    exit 0;
}

my $DOC = $opt{docroot};
unless ( defined $DOC && -d $DOC ) {
    print STDERR "lazysite-check.pl: --docroot must be an existing directory\n";
    exit 2;
}
$DOC = abs_path($DOC);
# SM293: ASK where the engine tree is. A site that has moved it beside its
# docroot is still a lazysite site, and computing "$DOC/lazysite" here rejected
# it outright at the guard below - the health tool refusing to look at exactly
# the sites that had taken the safer layout.
BEGIN {
    # SM366: locate the Lazysite module tree relative to this script
    # (run-in-place, tarball and Hestia installs), falling back to the system
    # @INC (package installs). The same bootstrap lazysite-users.pl has always
    # carried; without it this tool cannot start anywhere the modules are not
    # already on @INC, which is every install that is not a package.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

require Lazysite::Paths;
my $LZ = Lazysite::Paths::lazysite_dir($DOC);

# SM293: the permission model is written in docroot-relative paths
# ("lazysite/auth"), because that is the layout it grew up in. On a MIGRATED
# site those paths are not under the docroot at all, and a bare "$DOC/$rel"
# simply does not exist - so every check below would `next unless -e` its way
# past the entire engine tree and report a clean bill of health while verifying
# nothing. The auth store's 02770 is the most important mode on the site.
sub model_path {
    my ($rel) = @_;
    return "$LZ/$1" if $rel =~ m{\Alazysite/(.*)\z};
    return $LZ      if $rel eq 'lazysite';
    return "$DOC/$rel";
}
my $CGI = defined $opt{cgibin} ? abs_path( $opt{cgibin} ) : abs_path("$DOC/../cgi-bin");

unless ( -d $LZ ) {
    print STDERR "lazysite-check.pl: no engine tree for $DOC - looked inside it "
        . "and beside it. Is this a lazysite docroot?\n";
    exit 2;
}

# --- expected owner / group (default: derived from the docroot itself) -------
my @ds      = stat $DOC;
my $exp_uid = defined $opt{owner} ? ( ( getpwnam $opt{owner} )[2] // -1 ) : $ds[4];
# Expected GROUP defaults to the CGI's group (www-data), NOT the docroot's group:
# the no-suexec CGI runs as www-data and must keep group access to the tree.
# Falling back to the docroot group only if there is no www-data group.
my $exp_gid = defined $opt{group} ? ( ( getgrnam $opt{group} )[2] // -1 )
    :   ( ( getgrnam 'www-data' )[2] // $ds[5] );
my $exp_user = ( getpwuid $exp_uid )[0] // $exp_uid;
my $exp_grp  = ( getgrgid $exp_gid )[0] // $exp_gid;
# The CGI (www-data) legitimately OWNS the files it creates at runtime - locks,
# cache entries, generated html, audit.log - so www-data ownership is valid, not a
# fault. Only a TRULY foreign owner (root, another user) breaks CGI access.
my $cgi_uid = ( getpwnam 'www-data' )[2];

# --- result collection -------------------------------------------------------
my ( @results, @chmod_fixes, $chown_needed, $tt_cache_bad );
my ( $git_fix_root, $git_shared_fix );
my $store_create_needed;    # SM313: the private store to create under --fix
my $store_repair_needed;    # SM323: an existing store whose owner/mode locks the CGI out
sub report {    # (level, message, [hint])
    my ( $level, $msg, $hint ) = @_;

    # SM584: the level is a closed vocabulary. A typo used to pass straight
    # through: the icon printed empty, perl warned about an undefined value,
    # and - the part that mattered - the summary counts `eq 'OK'`, so a
    # mis-spelled level was counted as neither ok, warning nor failure and
    # vanished from both the tally and the exit code. A check whose answer
    # nobody sees is worse than a check that is not there.
    die "report: unknown level '$level' for: $msg\n"
        unless $level =~ /\A(?:OK|WARN|FAIL)\z/;
    push @results, { level => $level, msg => $msg, hint => $hint };
}
sub owner_name { ( getpwuid( ( stat $_[0] )[4] ) )[0] // ( stat $_[0] )[4] }
sub group_name { ( getgrgid( ( stat $_[0] )[5] ) )[0] // ( stat $_[0] )[5] }
sub mode_of    { ( stat $_[0] )[2] & 07777 }

# Effective access for the CGI identity, from ownership + mode arithmetic.
# $bit is the "other" permission bit: 4 read, 2 write, 1 execute/traverse.
# Never -r/-w/-x here: run as root those answer for root, which bypasses DAC
# and passes files/dirs the www-data CGI cannot actually use (field-hit
# 2026-07-09: the manager layout, readable by root, unusable by the CGI).
sub cgi_can {    # ( $bit, @stat )
    my ( $bit, @s ) = @_;
    my $mode = $s[2] & 07777;
    return 1 if defined $cgi_uid && $s[4] == $cgi_uid && $mode & ( $bit << 6 );
    return 1 if $s[5] == $exp_gid && $mode & ( $bit << 3 );
    return ( $mode & $bit ) ? 1 : 0;
}

# The access bits a path under lazysite/git must gain, or 0 when the CGI can
# already use it (probe 7c-i and its --fix share this). The FLAG condition is
# CGI access arithmetic (cgi_can); the FIX bits also top up the owner so a
# stripped dir serves both identities (matching git's own shared-repo modes:
# dirs 2775-shaped, mutable files 0664-shaped). Dirs need group rwx + setgid
# (git creates object files inside them); loose objects/packs need group READ
# only (git deliberately keeps them read-only - mutable state is replaced via
# rename, so directory writability is the real requirement); other files get
# read+write (COMMIT_EDITMSG and FETCH_HEAD are rewritten IN PLACE, and an
# unwritable COMMIT_EDITMSG is fatal to a commit).
sub git_want_bits {    # ( $gd, $path, $is_dir, @stat )
    my ( $gd, $p, $is_dir, @s ) = @_;
    if ($is_dir) {
        return 0 if cgi_can( 4, @s ) && cgi_can( 2, @s ) && cgi_can( 1, @s );
        return 02770;
    }
    if ( index( $p, "$gd/objects/" ) == 0 ) {
        return cgi_can( 4, @s ) ? 0 : 0040;
    }
    return 0 if cgi_can( 4, @s ) && cgi_can( 2, @s );
    return 0660;
}

my $conf = "$LZ/lazysite.conf";

# All checks are collected here so --fix can run them AGAIN after applying
# fixes: the printed report must reflect the post-fix tree, not the pre-fix
# snapshot (SM139 increment 5).
sub run_checks {
    @results        = ();
    @chmod_fixes    = ();
    $chown_needed   = 0;
    $tt_cache_bad   = 0;
    $git_fix_root   = '';
    $git_shared_fix = '';

    # --- 1. ownership: nothing under lazysite/ should be foreign-owned -----------
    {
        my ( @bad, $total );
        File::Find::find(
            { no_chdir => 1, wanted => sub {
                    my @s = lstat $File::Find::name or return;
                    return if -l _;
                   # ispadmin owns the code/content; www-data owns the files it creates at
                   # runtime (locks/cache/generated/audit) - both are fine. Flag only a
                   # truly foreign owner the CGI cannot access.
                    if ( $s[4] != $exp_uid && ( !defined $cgi_uid || $s[4] != $cgi_uid ) ) {
                        $total++;
                        push @bad, $File::Find::name if @bad < 8;
                    }
            } }, $LZ );
        if ($total) {
            my $sample = join( ', ', map { s{^\Q$DOC/\E}{}r } @bad );
            $sample .= ", …" if $total > @bad;
            report( 'FAIL',
                "$total path(s) under lazysite/ owned by neither $exp_user nor www-data "
                    . "(a foreign owner the CGI cannot access): $sample",
                "chown -R $exp_user:$exp_grp '$LZ'" );
            $chown_needed = 1;
        }
        else {
            report( 'OK', "lazysite/ tree owned by $exp_user (or the www-data CGI)" );
        }
    }

    # --- 2. the dirs the CGI must write: group-writable + setgid -----------------
    # (so www-data can create cache/.html, logs, locks, .secret, rate DBs, and new
    #  files inherit the group)
    my %want_dir = (
        'lazysite/backups'           => 02775,    # SM246 manager-written snapshots
        'lazysite/cache'             => 02775,
        'lazysite/logs'              => 02775,
        'lazysite/stats'             => 02775,    # SM213 durable per-day stats store
        'lazysite/stats/form-events' => 02775,    # SM216-2 form-outcome log (PII-free)
        'lazysite/manager/locks'     => 02775,
        'lazysite/layouts'           => 02775,
        'lazysite-assets'            => 02775,
        'lazysite/auth'              => 02770,
        'lazysite/forms'             => 02770,
        'lazysite/git'               => 02770,
    );
    for my $rel ( sort keys %want_dir ) {
        my $path = model_path($rel);
        next unless -e $path;                     # not every dir exists on every install
        unless ( -d $path ) { report( 'WARN', "$rel exists but is not a directory" ); next }
        my $mode = mode_of($path);
        my $want = $want_dir{$rel};
        my $gw   = ( $mode & 0070 ) >= 0070 ? 1 : ( $mode & 0020 ? 1 : 0 );
        my $sgid = $mode & 02000;
        if ( !( $mode & 0020 ) || !$sgid ) {
            my $g = group_name($path);
            report( 'FAIL',
                sprintf( "%s is %04o (group=%s) - the CGI cannot write here%s%s",
                    $rel, $mode, $g,
                    ( $mode & 0020 ? '' : '; not group-writable' ),
                    ( $sgid        ? '' : '; no setgid (new files miss the group)' ) ),
                sprintf( "chmod %04o '%s'", $want, $path ) );
            push @chmod_fixes, [ $want, $path ];
        }
        else {
            report( 'OK', sprintf( "%s writable + setgid (%04o)", $rel, $mode ) );
        }
    }

    # --- 2b. the rest of the declared model (SM268 03-F7) -----------------------
    #
    # SM246 states the design as "one table, three consumers - install applies,
    # check verifies, check --fix repairs". That was true of runtime_paths and
    # false of install_dirs: the eleven entries above are hand-written and the
    # model declares twenty-eight. So a site carrying the reported fault - the
    # docroot's content directories stripped of group write, which is the 0.6.5
    # incident SM246 exists for - stayed broken while this tool called it
    # healthy. The fix was prospective only: make_declared_path applies a mode
    # ON CREATION and never corrects an existing directory.
    #
    # Reported, not repaired, and deliberately so. These are content directories
    # on a live site; an operator who tightened one on purpose should not have it
    # widened by a tool they ran to ask a question. --fix stays on the CGI
    # writability set above, where the mode is a functional requirement rather
    # than a default. The suggested command is printed so the repair is one
    # paste away.
    {
        my %declared;
        my $st = _read_json("$LZ/.install-state.json");
        %declared = %{ $st->{dirs} }
            if ref $st eq 'HASH' && ref $st->{dirs} eq 'HASH';

        my $checked = 0;
        my $wrong   = 0;
        # SM270: the DOCROOT ITSELF is checked, and it is a FAIL rather than a
        # warning.
        #
        # SM268 03-F7 excluded it along with the parent and the cgi-bin, on the
        # reasoning that those are pre-existing and the platform's business.
        # That was right about the parent and the cgi-bin and WRONG about the
        # docroot: its mode is a functional requirement, not a preference - the
        # CGI writes every authoring surface through it. A live 0.10.5 upgrade
        # then proved the point. Hestia's v-rebuild-web-domain reset public_html
        # to 2751 (setgid, no group write), the operator followed the release
        # notes' instruction to re-render vhosts, and this tool reported the site
        # healthy while the manager could not save a file.
        #
        # Queued for --fix, unlike the content directories below: this one is
        # "the site does not work", not "someone may have tightened it on
        # purpose".
        if ( my $want_doc = $declared{$DOC} ) {
            my $w = oct $want_doc;
            my $m = mode_of($DOC);
            # Two severities, because they are two different problems. NOT
            # GROUP-WRITABLE is "the site does not work" - it is the reported
            # incident, and the CGI cannot save anything. Group-writable but no
            # SETGID works today and breaks the group on newly created files,
            # which is the slower-burning SM215 class. Reporting both as FAIL
            # would fire on every hand-made dev docroot and teach the reader to
            # skip the line that matters.
            if    ( !-d $DOC ) { }
            elsif ( !( $m & 0020 ) ) {
                report( 'FAIL',
                    sprintf( 'the docroot is %04o and is NOT group-writable - the CGI '
                            . 'cannot save anything. A Hestia vhost rebuild resets this '
                            . '(SM270); re-run after any rebuild', $m ),
                    sprintf( "chmod %04o '%s'", $w, $DOC ) );
                push @chmod_fixes, [ $w, $DOC ];
            }
            elsif ( !( $m & 02000 ) ) {
                report( 'WARN',
                    sprintf( 'the docroot is %04o - writable, but without setgid new '
                            . 'files will not inherit the web-server group', $m ),
                    sprintf( "chmod %04o '%s'", $w, $DOC ) );
            }
            else {
                report( 'OK', sprintf( 'docroot is group-writable + setgid (%04o)', $m ) );
            }
        }

        for my $path ( sort keys %declared ) {
            # Only the site's OWN directories BELOW the docroot. The parent and
            # the cgi-bin stay out: those really are the platform's, and a
            # finding that fires on every install is one its reader learns to
            # skip past. The docroot itself is handled above.
            next unless index( $path, "$DOC/" ) == 0;
            ( my $rel = $path ) =~ s{\A\Q$DOC\E/}{};
            next if $rel =~ m{\A\.\.(?:/|\z)};
            next if exists $want_dir{$rel};    # already covered, with --fix
            next unless -d $path;
            $checked++;
            my $want = oct $declared{$path};
            my $mode = mode_of($path);
            next if $mode == $want;
            $wrong++;
            # SM274: two questions, not one - "is this mode different from the
            # model" and "can the CGI still write here".
            #
            # SM246's design says "install applies, check verifies, --fix
            # repairs", and the repair third was held because these are content
            # directories on a live site: an operator who tightened one on
            # purpose must not have it widened by a tool they ran to ask a
            # question. That reasoning is right about the WHOLE mode and wrong
            # about one bit of it.
            #
            # The install state records the DECLARED mode, not the mode the
            # installer actually left, so it cannot distinguish "drifted" from
            # "deliberate" by history - which is what ruled out comparing
            # against a baseline. But it does not need to. Group-write on a
            # declared directory is FUNCTIONAL: without it the CGI cannot write
            # there, which is the site not working. Every other bit is
            # preference, and nobody tightens a docroot subdirectory to break
            # their own site on purpose.
            #
            # So --fix ADDS the group-write bit and nothing else, leaving an
            # operator's own choices about world and owner bits exactly as they
            # made them. A mode that differs in any other way is still reported
            # and still not touched.
            if ( !( $mode & 0020 ) ) {
                report( 'FAIL',
                    sprintf( '%s is %04o and is NOT group-writable - the CGI cannot '
                            . 'write here (the model declares %04o)', $rel, $mode, $want ),
                    sprintf( "chmod g+w '%s'", $path ) );
                push @chmod_fixes, [ 0020, $path, 'add' ];
                $wrong++;
                next;
            }
            report( 'WARN',
                sprintf( '%s is %04o, the model declares %04o - reported only; '
                        . '--fix restores group write, never other bits',
                    $rel, $mode, $want ),
                sprintf( "chmod %04o '%s'", $want, $path ) );
        }
        if ( !$checked ) {
            report( 'OK',
                'no declared directory modes recorded (payload predates the model)' );
        }
        elsif ( !$wrong ) {
            report( 'OK', "$checked declared directories carry their declared mode" );
        }
    }

    # --- 3. group must be the CGI's group on the writable dirs -------------------
    for my $rel ( sort keys %want_dir ) {
        my $path = model_path($rel);
        next unless -d $path;
        my $gid = ( stat $path )[5];
        if ( $gid != $exp_gid ) {
            report( 'FAIL',
                "$rel group is " . group_name($path) . ", expected $exp_grp "
                    . "(the group the CGI runs as) - the CGI cannot access it",
                "chown -R $exp_user:$exp_grp '$LZ'" );
            $chown_needed = 1;
        }
    }

    # --- 3a. traversal: the CGI must be able to cross into these dirs ------------
    # Every check below presupposes the CGI can TRAVERSE the path components
    # above the file (execute bit on each dir). A root-run -x cannot see a
    # missing group-execute (root bypasses DAC), so evaluate ownership+mode.
    for my $rel (qw(lazysite lazysite/manager lazysite/auth)) {
        my $path = model_path($rel);
        next unless -d $path;
        my @s = stat $path;
        if ( !cgi_can( 1, @s ) ) {
            report( 'FAIL',
                sprintf( "%s/ (%04o, %s:%s) is not traversable by the CGI (%s) - "
                        . "everything beneath it is unreachable from the web",
                    $rel, $s[2] & 07777, owner_name($path), group_name($path), $exp_grp ),
                sprintf( "chown %s:%s '%s' && chmod g+x '%s'", $exp_user, $exp_grp, $path, $path ) );
            push @chmod_fixes, [ 0010, $path, 'add' ];
            $chown_needed = 1 if $s[5] != $exp_gid;
        }
        else {
            report( 'OK', "$rel/ traversable by the CGI" );
        }
    }

    # --- 3b. TT compile cache: every dir must be writable by the CGI -------------
    # Template Toolkit 2.x treats a failed .ttc compile-cache write as a FATAL
    # render error, silently downgrading every page (manager included) to the
    # built-in fallback layout. Root-era or post-chown dirs under cache/tt are the
    # classic cause (0755 without group-write). The tree is a pure cache: the safe
    # fix is to remove it wholesale and let the CGI regrow it.
    if ( -d "$LZ/cache/tt" ) {
        File::Find::find(
            { no_chdir => 1, wanted => sub {
                    return unless -d $File::Find::name;
                    my @s = stat _;
                    $tt_cache_bad++ unless cgi_can( 2, @s );
            } }, "$LZ/cache/tt" );
        if ($tt_cache_bad) {
            report( 'FAIL',
                "lazysite/cache/tt has $tt_cache_bad dir(s) the CGI ($exp_grp) cannot "
                    . "write - on Template Toolkit 2.x this silently downgrades every page "
                    . "to the built-in fallback layout",
                "rm -rf '$LZ/cache/tt'  (a pure cache - it regenerates)" );
        }
        else {
            report( 'OK', "lazysite/cache/tt writable by the CGI" );
        }
    }

    # --- 4. secrets: not world-accessible AND readable by the CGI ----------------
    # (the common live-500: .secret is 0600 owned by a non-www-data user, so a
    #  cookie/secret verification by the www-data CGI dies before headers)
    # SM141: sessions.jsonl + revoked.json carry visitor IP/UA + revocation
    # state - 0660, CGI-readable, never world-accessible, like the secrets.
    for my $rel ( qw(
        lazysite/auth/.secret lazysite/forms/.secret lazysite/manager/.csrf-secret
        lazysite/auth/oauth.json lazysite/auth/user-settings.json
        lazysite/auth/sessions.jsonl lazysite/auth/revoked.json
        lazysite/notify-xmpp.conf lazysite/forms/smtp.conf
        ) ) {
        my $path = model_path($rel);
        next unless -f $path;
        my @s    = stat $path;
        my $mode = $s[2] & 07777;
        if ( $mode & 0007 ) {
            report( 'FAIL',
                sprintf( "%s is world-accessible (%04o) - a secret must not be", $rel, $mode ),
                sprintf( "chmod 0660 '%s'", $path ) );
            push @chmod_fixes, [ 0660, $path ];
        }
        elsif ( !cgi_can( 4, @s ) ) {
            report( 'FAIL',
                sprintf( "%s (%04o, %s:%s) is not readable by the CGI (%s) - "
                        . "cookie/secret verification dies before headers (a 500)",
                    $rel, $mode, owner_name($path), group_name($path), $exp_grp ),
                sprintf( "chown %s:%s '%s' && chmod 0660 '%s'", $exp_user, $exp_grp, $path, $path ) );
            push @chmod_fixes, [ 0660, $path ];
            $chown_needed = 1;
        }
        else {
            report( 'OK', "$rel readable by the CGI, not world-accessible" );
        }
    }

    # --- 4b. config/auth files the CGI overwrites in place must be group-writable -
    # (the manager saves nav.conf / lazysite.conf / the user store + ACLs through the
    #  www-data CGI; if they are not group-writable by www-data, the save fails)
    for my $rel ( qw(
        lazysite/nav.conf lazysite/lazysite.conf
        lazysite/auth/users lazysite/auth/groups lazysite/auth/acls.json
        lazysite/logs/audit.log
        ) ) {
        my $path = model_path($rel);
        next unless -f $path;
        my @s    = stat $path;
        my $mode = $s[2] & 07777;
        my $cgi_writable =
            ( defined $cgi_uid && $s[4] == $cgi_uid && ( $mode & 0200 ) ) # www-data owner, owner-write
            || ( $s[5] == $exp_gid && ( $mode & 0020 ) );    # www-data group, group-write
        unless ($cgi_writable) {
            report( 'FAIL',
                sprintf( "%s (%04o, %s:%s) is not writable by the CGI (%s) - the manager cannot save it",
                    $rel, $mode, owner_name($path), group_name($path), $exp_grp ),
                sprintf( "chown %s:%s '%s' && chmod g+w '%s'", $exp_user, $exp_grp, $path, $path ) );
            push @chmod_fixes, [ 0020, $path, 'add' ];    # add group-write, keep the rest
            $chown_needed = 1;
        }
        else {
            report( 'OK', "$rel writable by the CGI" );
        }
    }

    # --- 5. the user store must not be world-writable ----------------------------
    for my $rel (qw(lazysite/auth/users lazysite/auth/groups)) {
        my $path = model_path($rel);
        next unless -f $path;
        my $mode = mode_of($path);
        if ( $mode & 0002 ) {
            report( 'FAIL', sprintf( "%s is world-writable (%04o)", $rel, $mode ),
                sprintf( "chmod 0660 '%s'", $path ) );
            push @chmod_fixes, [ 0660, $path ];
        }
    }

    # --- 6. config present + readable BY THE CGI; cgi-bin scripts executable -----
    # (-r/-x here would answer for the invoking user - run as root they pass on
    #  files the www-data CGI cannot read or exec; use the arithmetic instead)
    my @cs = stat $conf;
    if ( !@cs || !-f _ ) {
        report( 'FAIL', "lazysite.conf missing at $conf" );
    }
    elsif ( !cgi_can( 4, @cs ) ) {
        report( 'FAIL',
            sprintf( "lazysite.conf (%04o, %s:%s) is not readable by the CGI (%s) - "
                    . "the site cannot load its configuration",
                $cs[2] & 07777, owner_name($conf), group_name($conf), $exp_grp ),
            sprintf( "chown %s:%s '%s' && chmod 0664 '%s'", $exp_user, $exp_grp, $conf, $conf ) );
        push @chmod_fixes, [ 0044, $conf, 'add' ];
        $chown_needed = 1 if $cs[5] != $exp_gid;
    }
    else {
        report( 'OK', "lazysite.conf present and readable by the CGI" );
    }

    if ( -d $CGI ) {
        for my $s (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
            my $p  = "$CGI/$s";
            my @ss = stat $p;
            if ( !@ss || !-f _ ) { report( 'FAIL', "cgi-bin/$s missing", "re-run the deploy" ) }
            elsif ( !cgi_can( 1, @ss ) ) {
                report( 'FAIL',
                    sprintf( "cgi-bin/%s (%04o, %s:%s) is not executable by the CGI (%s)",
                        $s, $ss[2] & 07777, owner_name($p), group_name($p), $exp_grp ),
                    sprintf( "chmod 0755 '%s'", $p ) );
                push @chmod_fixes, [ 0755, $p ];
            }
            else { report( 'OK', "cgi-bin/$s present and executable" ) }
        }
    }
    else {
        report( 'WARN', "cgi-bin not found at $CGI (pass --cgibin to check it)" );
    }

    # --- 6b. SM279: a stale group dav_scope is a confinement that is not one ----
    #
    # SM165 moved confinement to the domain-owned model in 0.7.26. The group
    # `dav_scope` field kept being accepted and stored for every release after,
    # and enforced nowhere - so an operator who set one between 0.7.26 and 0.10.6
    # has an account they believe is confined and which is not.
    #
    # FAIL, not WARN, and deliberately so: every other finding in this tool is
    # about a permission being wrong. This one is about a permission the operator
    # thinks exists. There is no repair to apply - the fix is to confine the group
    # through its domain - so it is reported and never touched by --fix.
    {
        my %scoped;
        my $gs = _read_json("$LZ/auth/groups-settings.json") || {};
        for my $g ( sort keys %$gs ) {
            next unless ref $gs->{$g} eq 'HASH';
            my $s = $gs->{$g}{dav_scope};
            $scoped{$g} = $s if defined $s && length $s;
        }
        for my $g ( sort keys %scoped ) {
            report( 'FAIL',
                "group '$g' carries a retired dav_scope ($scoped{$g}) - it has "
                    . "confined NOBODY since 0.7.26; any member you believe is "
                    . "restricted to that folder is not",
                "confine the group by naming it in the allowed_groups of the "
                    . "domain it may manage, then clear the stale value: "
                    . "perl tools/lazysite-users.pl --docroot '$DOC' group-set "
                    . "'$g' dav_scope ''" );
        }
    }

    # --- 6c. SM335: a retired anonymise_ip is a choice the operator no longer has
    #
    # The manager Stats page used to count visitors itself, and honoured
    # `anonymise_ip: false` by keying them on the raw address. Both readers now
    # share one tally, and that tally always anonymises - a /24 truncation then
    # a hash, before anything is stored - which is what the export has always
    # done.
    #
    # So the line is inert. WARN rather than FAIL, and the distinction matters:
    # SM279's retired dav_scope is a confinement somebody believes exists and
    # does not, which is a permission being wrong. This is the opposite
    # direction - an operator who asked for LESS anonymisation is now getting
    # more - so nothing is exposed and nobody is less safe. They are simply not
    # getting what they asked for, and should be told rather than left to infer
    # it from a control that has disappeared.
    {
        my $anon = conf_value( $conf, 'anonymise_ip' );
        if ( defined $anon && length $anon ) {
            report( 'WARN',
                "lazysite.conf carries a retired anonymise_ip ($anon) - visitor "
                    . "addresses are now always truncated to their /24 and hashed "
                    . "before anything is stored, so this line has no effect",
                "remove the anonymise_ip line from "
                    . "'$DOC/lazysite/lazysite.conf'; if you were relying on "
                    . "un-anonymised addresses, that capability is gone "
                    . "deliberately and no setting restores it" );
        }
    }

    # --- 7. manager bootstrap (ties to setup-manager) ----------------------------
    my $mgr_enabled = ( conf_value( $conf, 'manager' ) // '' ) =~ /enabled/i;
    {
        # SM138: manager groups are those whose SETTINGS entry grants manager access
        # (ui / manage_users / the manager flag); the conf manager_groups key is
        # retired (a lingering line is inert and migrated away on first use).
        my $gs     = _read_json("$LZ/auth/groups-settings.json") || {};
        my @groups = sort grep {
            my $c = $gs->{$_};
            ref $c eq 'HASH' && ( $c->{ui} || $c->{manage_users} || $c->{manager} );
        } keys %{$gs};
        if ( !@groups ) {
            report( 'WARN',
                "no group grants manager access - the manager is unconfigured "
                    . "(every authenticated user would be a manager)",
                "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" );
        }
        elsif ( !$mgr_enabled ) {
            report( 'WARN', "a manager group exists but 'manager: enabled' is not set",
                "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" );
        }
        else {
            # is there a manager user with a password, in a manager group?
            my %is_mgr_group = map { $_ => 1 } @groups;
            my %members;
            if ( open my $gf, '<', "$LZ/auth/groups" ) {
                while ( my $l = <$gf> ) {
                    next unless $l =~ /^([^:#]+):\s*(.*)$/;
                    next unless $is_mgr_group{$1};
                    $members{$_} = 1 for split /[,\s]+/, ( $2 // '' );
                }
                close $gf;
            }
            my ( $have_mgr, $have_pw ) = ( 0, 0 );
            if ( open my $uf, '<', "$LZ/auth/users" ) {
                while ( my $l = <$uf> ) {
                    next if $l =~ /^\s*#/;
                    next unless $l =~ /^([^:]+):(.*)$/;
                    next unless $members{$1};
                    $have_mgr = 1;
                    $have_pw  = 1 if length( $2 // '' );
                }
                close $uf;
            }
            if ( !$have_mgr ) { report( 'WARN', "no user in a manager group (@groups)",
                    "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" ) }
            elsif ( !$have_pw ) { report( 'WARN', "manager user has no password (localhost-only)",
                    "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" ) }
            else { report( 'OK', "manager bootstrapped (group + user + password)" ) }

            # SM471: A CAPABILITY ADDED AFTER THIS SITE WAS CREATED NEVER
            # REACHED IT.
            #
            # The manager group is seeded ONCE, with the capabilities that
            # existed that day, and _ensure_manager_group_caps returns early
            # when the group already has an entry - so no later release
            # backfills. Every capability added since is absent, and the
            # operator meets it as "you do not hold it" about something their
            # role is designed to hold.
            #
            # REPORTED, NOT REPAIRED, and that is the decision rather than
            # laziness. The code cannot tell "this did not exist when the group
            # was made" from "an operator turned it off on purpose", and
            # granting on upgrade gets the second silently wrong. Re-granting
            # something somebody removed is worse than telling them about
            # something they are missing.
            #
            # api and mcp are excluded: SM127 keeps manager groups off the
            # remote channels deliberately, so their absence is the design.
            # THE CAPABILITY LIST IS A DELIBERATE LOCAL COPY. This file is
            # core-Perl by design and cannot load Lazysite::Auth::Settings, so
            # it carries the list the way the processor carries its ACL copy -
            # and t/lint/81 pins the pair, which is what makes the copy safe
            # rather than a second opinion.
            my @CAPS = qw(
                ui webdav
                manage_content manage_nav manage_forms
                manage_themes manage_layouts manage_domains manage_config
                manage_users analytics audit notifications feedback
                read_submissions create_sub_users delegate_sub_user_creation
                manage_data manage_briefs housekeeping purge);

            my $gsettings = _read_json("$LZ/auth/groups-settings.json") || {};

            # SM496: ABSENT and DECLINED are different answers now. An
            # explicit 0 is a recorded human decision (the Groups page banner
            # or a group-set off wrote it) and stays silent as a warning -
            # re-warning about a decision is how warnings get ignored. Only a
            # capability the store has never seen a decision on warns, and
            # the remedy is the UI first: capability upkeep is app support,
            # and app support must not need a shell on the box.
            my ( @missing, @declined );
            for my $g (@groups) {
                my $have = $gsettings->{$g} or next;
                next unless $have->{manager};
                for my $c (@CAPS) {
                    if    ( !exists $have->{$c} ) { push @missing,  "$g/$c" }
                    elsif ( !$have->{$c} )        { push @declined, "$g/$c" }
                }
            }
            if (@missing) {
                report( 'WARN',
                    'manager group(s) have not decided on capabilities this '
                        . 'release has: '
                        . join( ', ', @missing )
                        . ' - added after the group was seeded. Decide in the '
                        . 'manager UI: Groups -> the group -> the "new '
                        . 'capabilities" banner (grant or dismiss)',
                    do {
                        my ($fg) = $missing[0] =~ m{\A([^/]+)/};
                        my ($fc) = $missing[0] =~ m{/(.+)\z};
                        'or from a shell, exactly: perl tools/lazysite-users.pl '
                            . "--docroot '$DOC' group-set $fg $fc on|off";
                    } );
            }
            else {
                report( 'OK',
                    'manager group(s) carry a decision on every capability '
                        . 'this release has'
                        . ( @declined
                        ? ' (' . scalar(@declined) . ' declined by decision)'
                        : '' )
                );
            }
        }
    }

    # --- 7b. manager layout: present + usable by the CGI (field-hit 2026-07-09) --
    # lazysite/manager/layout.tt readable by root but not by the CGI makes the
    # manager render in the built-in fallback layout, stuck at "Loading..." -
    # and a root-run -r check cannot see it. Evaluate as the CGI identity.
    if ($mgr_enabled) {
        my $path = "$LZ/manager/layout.tt";
        if ( !-f $path ) {
            report( 'FAIL',
                "lazysite/manager/layout.tt missing - the manager renders in the "
                    . "built-in fallback layout, stuck at Loading...",
                "re-run the deploy (install.pl restores manager/layout.tt)" );
        }
        else {
            my @s = stat $path;
            if ( !cgi_can( 4, @s ) ) {
                report( 'FAIL',
                    sprintf( "lazysite/manager/layout.tt (%04o, %s:%s) is not readable by "
                            . "the CGI (%s) - the manager renders in the built-in fallback "
                            . "layout, stuck at Loading...",
                        $s[2] & 07777, owner_name($path), group_name($path), $exp_grp ),
                    sprintf( "chown %s:%s '%s' && chmod 0664 '%s'", $exp_user, $exp_grp, $path, $path ) );
                push @chmod_fixes, [ 0664, $path ];
                $chown_needed = 1 if $s[5] != $exp_gid;
            }
            else {
                report( 'OK', "lazysite/manager/layout.tt present and readable by the CGI" );
            }
        }
    }

    # --- 7c. content history (SM085) ----------------------------------------------
    # When git_history is enabled: the git binary must exist (WARN - saves keep
    # working, history silently stops), the repo dir must not be world-accessible,
    # and info/exclude MUST carry the lazysite/auth exclusion - a history that can
    # be pushed to a remote must never contain the credential store (SECURITY).
    if ( ( conf_value( $conf, 'git_history' ) // '' ) =~ /enabled/i ) {
        my $have_git = 0;
        for my $bd ( split /:/, ( $ENV{PATH} // '' ) ) {
            next unless length $bd;
            if ( -f "$bd/git" && -x _ ) { $have_git = 1; last }
        }
        if ( !$have_git ) {
            report( 'WARN',
                "git_history is enabled but git is not installed - saves keep working "
                    . "but no content history is recorded",
                "apt-get install git (or the distro equivalent)" );
        }
        my $gd = "$LZ/git";
        if ( !-d $gd ) {
            report( 'WARN',
                "git_history is enabled but lazysite/git is not initialised",
                "use the Content history plugin's Enable action on Plugin Config "
                    . "(or the git-init control-API action)" );
        }
        else {
            my $mode = mode_of($gd);
            if ( $mode & 0007 ) {
                report( 'FAIL',
                    sprintf( "lazysite/git is world-accessible (%04o) - the content "
                            . "history must not be", $mode ),
                    sprintf( "chmod 02770 '%s'", $gd ) );
                push @chmod_fixes, [ 02770, $gd ];
            }
            my $excl = '';
            if ( open my $xf, '<', "$gd/info/exclude" ) {
                local $/;
                $excl = <$xf> // '';
                close $xf;
            }
            if ( $excl !~ m{^/?lazysite/auth/?\s*$}m ) {
                report( 'FAIL',
                    "lazysite/git/info/exclude does not exclude lazysite/auth - the "
                        . "credential store could be committed and PUSHED to a remote",
                    "add a '/lazysite/auth/' line to '$gd/info/exclude' (and "
                        . "'git rm -r --cached lazysite/auth' if it was ever committed)" );
            }
            else {
                report( 'OK', "content history: lazysite/auth is excluded from the repo" );
            }
            # git-sync.conf holds the remote access token; when it exists it
            # must be excluded too (the sync plugin self-heals this before
            # every sync, but a missing line is still a pushable-secret risk).
            if ( -f "$LZ/git-sync.conf"
                && $excl !~ m{^/?lazysite/git-sync\.conf\s*$}m ) {
                report( 'FAIL',
                    "lazysite/git/info/exclude does not exclude lazysite/git-sync.conf - "
                        . "the remote access token could be committed and PUSHED to a remote",
                    "add a '/lazysite/git-sync.conf' line to '$gd/info/exclude' (and "
                        . "'git rm --cached lazysite/git-sync.conf' if it was ever committed)" );
            }

            # 7c-i. repo internals (field defect 2026-07-11, dito.tech): a
            # pre-0.7.7 doctor chown left 0755 object dirs the CGI cannot
            # write, so every commit failed while the saves succeeded - new
            # file versions were silently not recorded. Ownership+mode
            # arithmetic (cgi_can) as everywhere: root's -w would pass what
            # the CGI cannot use.
            my ( $git_bad, @git_sample ) = (0);
            File::Find::find(
                { no_chdir => 1, wanted => sub {
                        my $p = $File::Find::name;
                        my @s = lstat $p or return;
                        return if -l _;
                        my $bits = git_want_bits( $gd, $p, ( -d _ ? 1 : 0 ), @s );
                        return unless $bits;
                        $git_bad++;
                        push @git_sample, $p if @git_sample < 5;
                        $chown_needed = 1 if $s[5] != $exp_gid;
                } }, $gd );
            if ($git_bad) {
                my $sample = join( ', ', map { s{^\Q$DOC/\E}{}r } @git_sample );
                $sample .= ', …' if $git_bad > @git_sample;
                report( 'FAIL',
                    "$git_bad path(s) under lazysite/git the CGI ($exp_grp) cannot use - "
                        . "commits fail while saves succeed, so new file versions are "
                        . "SILENTLY NOT RECORDED ($sample)",
                    "re-run with --fix (restores group access; a foreign group also needs "
                        . "the chown above)" );
                $git_fix_root = $gd;
            }
            else {
                report( 'OK', "content history: the repo is usable by the CGI" );
            }

            # 7c-ii. core.sharedRepository=group makes git itself keep every
            # path it creates group-accessible regardless of the process umask
            # - set at init since 0.7.8; repos initialised earlier predate it
            # and regress on the next umask-0022 write unless set.
            if ($have_git) {
                my $val = '';
                if ( open my $ph, '-|', 'git', "--git-dir=$gd", 'config', '--get',
                    'core.sharedRepository' ) {
                    local $/; $val = <$ph> // ''; close $ph;
                }
                $val =~ s/\s+//g;
                if ( $val =~ /\A(?:1|2|group|true|all|world|everybody|0[0-7]{2,3})\z/i ) {
                    report( 'OK',
                        "content history: core.sharedRepository keeps the repo group-accessible" );
                }
                else {
                    report( 'WARN',
                        "content history: core.sharedRepository is not set - git creates new "
                            . "object dirs with the process umask, which can silently break "
                            . "version recording after an ownership change",
                        "git --git-dir='$gd' config core.sharedRepository group  (--fix does this)" );
                    $git_shared_fix = $gd;
                }
            }

            # 7c-iii. recording-health breadcrumb: the engine touches
            # COMMIT_FAILED when a version could not be recorded (the save
            # itself succeeds by design) and removes it on the next successful
            # commit. WARN, not FAIL: --fix repairs the cause above; only a
            # subsequent save can prove recording works again.
            if ( -e "$gd/COMMIT_FAILED" ) {
                report( 'WARN',
                    "content history: the last version-recording attempt FAILED "
                        . "(lazysite/git/COMMIT_FAILED present) - changes since then are "
                        . "missing from the history",
                    "fix the findings above (--fix), then save any page - a successful "
                        . "save clears this flag" );
            }
        }
    }

    # --- 8. WebDAV route health (SM121, opt-in) ----------------------------------
    # A wired /dav/ challenges with 401 even unauthenticated; a missing route 404s.
    # 404-vs-401 is the fastest way to tell "web server / proxy doesn't forward /dav/"
    # (provisioning) from an auth/scope problem.
    if ( defined $opt{check_dav} ) {
        my $u = $opt{check_dav};
        $u =~ s{/+$}{};
        if ( $u !~ m{^https?://\S+$} ) {
            report( 'WARN', "--check-dav needs an http(s):// URL; skipping the WebDAV probe" );
        }
        else {
            my $code = '';
           # list-form open: no shell, so the URL can't inject. -k tolerates a fresh cert.
            if ( open my $ph, '-|', 'curl', '-sS', '-k', '-o', '/dev/null',
                '-w', '%{http_code}', '--max-time', '8', "$u/dav/" ) {
                local $/; $code = <$ph> // ''; close $ph;
            }
            $code =~ s/\D//g;
            if ( $code eq '401' ) { report( 'OK', "WebDAV /dav/ is routed (401 challenge at $u/dav/)" ) }
            elsif ( $code eq '404' ) {
                report( 'FAIL',
                    "WebDAV /dav/ returns 404 at $u/dav/ - the web server / proxy is not forwarding "
                        . "/dav/ to lazysite-dav.pl (route missing, not an auth problem)",
                    "wire /dav/ -> cgi-bin/lazysite-dav.pl in the vhost (and the nginx proxy if used), then reload" );
            }
            elsif ( $code eq '' ) { report( 'WARN', "WebDAV /dav/ probe got no response (curl missing or host unreachable)" ) }
            else { report( 'WARN', "WebDAV /dav/ returned $code at $u/dav/ (expected 401)" ) }
        }
    }

    # --- 8b. does the front end actually respect the ACL? (SM285) ---------------
    run_acl_probe( $opt{check_acl} ) if defined $opt{check_acl};

    # --- 8b2. does the engine see static requests at all? (SM377 follow-up) -----
    report_engine_sees_statics( $opt{check_acl} ) if defined $opt{check_acl};

    # --- 8c. who an @group ACL entry now admits (SM288) -------------------------
    report_unscoped_data_tables();
    report_group_acl_reach();

    # --- 8d. is any protected content ALSO sitting in the docroot? (SM286) ------
    report_stray_public();

    # --- 8g. can this site's private store actually be written? (SM296) --------
    report_private_store_usable();

    # --- 8e. where is this site's engine tree, and is there only one? (SM293) ---
    report_engine_tree();

    # --- 8f. registries left behind from before they were served (SM293) --------
    report_stale_registries();

    # --- 8h. is front-door mode on for this site? (SM294 / SM309) --------------
    report_front_door_mode();

    # --- 8i. is the ACTIVE theme's stylesheet actually being served? (SM315) ----
    report_theme_assets_mirrored();

    # --- 9. content provenance (is this content lazysite's or the operator's?) ---
    # lazysite stamps its shipped seed pages with `provenance: lazysite-starter` in the
    # front matter. This reports which .md content is ours (unmodified vs customised)
    # versus operator-authored - the "is this likely ours?" test behind the upgrade-
    # safety work. Informational (always OK); never a FAIL.
    {
        require Digest::SHA;
        my %state;
        my $st = _read_json("$LZ/.install-state.json");
        %state = %{ $st->{files} }
            if ref $st eq 'HASH' && ref $st->{files} eq 'HASH';
        my $sha_file = sub {
            my ($p) = @_;
            open my $fh, '<:raw', $p or return '';
            my $d = Digest::SHA->new(256);
            $d->addfile($fh);
            close $fh;
            return 'sha256:' . $d->hexdigest;
        };

        my ( @operator, @customised );
        my $unmodified = 0;
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    my $p = $File::Find::name;
                    return unless $p =~ /\.md\z/ && -f $p;
                    # Skip lazysite internals + code-managed trees (always ours).
                    for my $skip (qw(lazysite manager docs .well-known)) {
                        return if index( $p, "$DOC/$skip/" ) == 0;
                    }
                    open my $fh, '<', $p or return;
                    my $first = <$fh> // '';
                    my $head  = '';
                    if ( $first =~ /\A---\s*\R?\z/ ) {    # front matter opens
                        while ( my $l = <$fh> ) { last if $l =~ /\A---\s*\R?\z/; $head .= $l }
                    }
                    close $fh;
                    ( my $rel = $p ) =~ s/\A\Q$DOC\E\/?//;
                    if ( $head !~ /^provenance\s*:\s*lazysite-starter\s*$/m ) {
                        push @operator, $rel;
                        return;
                    }
                    # Ours: unmodified vs customised, via the recorded install-state sha.
                    my $rec = $state{$p};
                    if ( defined $rec && $rec eq $sha_file->($p) ) { $unmodified++ }
                    else { push @customised, $rel }
                },
            },
            $DOC,
        );

        report( 'OK', sprintf(
                'content provenance: %d lazysite page(s) [%d unmodified, %d customised], %d operator-authored',
                $unmodified + scalar @customised, $unmodified, scalar @customised, scalar @operator ) );
        my $cap = sub { my @l = @_; @l > 10 ? ( @l[ 0 .. 9 ], '...' ) : @l };
        report( 'OK', '  customised (edited from a lazysite page): ' . join( ', ', $cap->(@customised) ) )
            if @customised;
        report( 'OK', '  operator-authored (not ours, never touched by upgrades): ' . join( ', ', $cap->(@operator) ) )
            if @operator;
    }

    # --- 10. system pages resolve (SM201) ----------------------------------------
    # login/claim/402/403/404 are served with a fallback: a content-root or
    # docroot-root copy overrides, else the protected engine default under
    # lazysite/templates/system/. Verify each route resolves - so /login and /claim
    # never 404 even after an agent deletes a root copy - and that the protected
    # defaults (which make the fallback self-healing) are present.
    {
        my ( @dead, @root_only );
        for my $name (qw(login claim 402 403 404)) {
            my $has_default = -f "$LZ/templates/system/$name.md";
            my $has_root    = -f "$DOC/$name.md";
            push @dead,      $name if !$has_default && !$has_root;
            push @root_only, $name if !$has_default && $has_root;
        }
        if (@dead) {
            report( 'FAIL',
                'system page(s) with neither an engine default nor a root copy - these '
                    . 'routes will 404: ' . join( ', ', @dead ),
                'reinstall/upgrade to restore lazysite/templates/system/ (SM201)' );
        }
        if (@root_only) {
            report( 'WARN',
                'system page(s) served only from a root copy - the protected default is '
                    . 'missing (an agent-proof fallback): ' . join( ', ', @root_only ),
                'run an upgrade to install lazysite/templates/system/ (SM201)' );
        }
        report( 'OK', 'system pages (login/claim/40x) all resolve via the fallback chain (SM201)' )
            if !@dead && !@root_only;
    }

    # --- 11. OAuth/remote discovery coherence (SM190 / SM200 lever 4) -------------
    # The .well-known discovery docs advertise every endpoint from site_url. If a
    # remote service is enabled but site_url is unset or not https, the docs hand a
    # connecting agent a broken/wrong endpoint (the token exchange then fails with a
    # confusing sign-in-incomplete - the outsourcify onboarding incident). Catch it
    # here at deploy time, before onboarding, without an HTTP round-trip.
    {
        my @remote =
            grep { ( conf_value( $conf, $_ ) // '' ) =~ /^(?:enabled|true|yes|on|1)$/i }
            qw(oauth_enabled token_exchange_enabled control_api_enabled webdav_enabled mcp_enabled);
        if (@remote) {
            my $site_url = conf_value( $conf, 'site_url' ) // '';

            # The recommended house value is the dynamic
            # ${REQUEST_SCHEME}://${SERVER_NAME}, which the processor expands
            # per-request; behind TLS (every deployed vhost terminates it) the
            # scheme resolves to https, so the advertised endpoints are https.
            # Treat that form as acceptable instead of warning "not https" on
            # every site - that literal-prefix test was 0.9.13 field noise.
            my $dynamic_scheme = $site_url =~ m{^\$\{REQUEST_SCHEME\}://};

            if ( !length $site_url ) {
                report( 'FAIL',
                    'a remote service is enabled (' . join( ', ', @remote )
                        . ') but site_url is UNSET - the .well-known discovery docs will '
                        . 'advertise endpoints with no host, so an agent connect fails',
                    'set site_url: https://<this-host> in lazysite.conf' );
            }
            elsif ( $site_url !~ m{^https://} && !$dynamic_scheme ) {
                report( 'WARN',
                    "site_url is '$site_url' (not https://) while a remote service is "
                        . 'enabled - OAuth connectors require https advertised endpoints',
                    'set site_url to the https:// URL of this host' );
            }
            elsif ( $site_url =~ m{/$} ) {
                report( 'WARN',
                    "site_url '$site_url' has a trailing slash - advertised endpoints get a "
                        . 'double slash; trim it',
                    'remove the trailing / from site_url' );
            }
            else {
                report( 'OK', "OAuth/remote discovery: site_url ($site_url) is coherent for the "
                        . 'enabled service(s)' );
            }
        }
    }
    return;
}

# --- apply fixes; returns how many were applied -------------------------------
# A queued fix [ $mode, $path ] sets $mode exactly; [ $bits, $path, 'add' ] ORs
# $bits into the file's mode AT APPLY TIME, so two fixes on the same path
# compose (e.g. group-write from check 4b + group/other-read from check 6)
# instead of the later chmod clobbering the earlier one.

# The mode a CGI-owned path must carry BEFORE the root chown pass hands it to
# the site user: the owner bits are replicated onto the group, so the access
# the CGI had AS OWNER survives the handover AS GROUP (0600 secret -> 0660,
# 0755 tt-cache dir -> 0775). Field defect 2026-07-11: the chown pass turned
# the CGI's own 0600 .secret files into site-user-owned 0600 - breaking them
# in the very run that printed "fixed:" - because run 1 had verified them via
# OWNERSHIP, which the chown then took away. Pure function; unit-tested.
sub handover_mode {
    my ($mode) = @_;
    $mode &= 07777;
    return $mode | ( ( $mode & 0700 ) >> 3 );
}

sub apply_fixes {
    my $fixed = 0;
    if ($tt_cache_bad) {
        require File::Path;
        my $err;
        File::Path::remove_tree( "$LZ/cache/tt", { error => \$err } );
        if ( $err && @{$err} ) { warn "could not remove $LZ/cache/tt\n" }
        else {
            print "fixed: rm -rf $LZ/cache/tt (compile cache regenerates)\n";
            $fixed++;
        }
    }
    if ($git_fix_root) {
        # One walk, one summary line - a repo can hold hundreds of object
        # dirs; per-path "fixed:" lines would drown the report.
        my $gd = $git_fix_root;
        my $n  = 0;
        File::Find::find(
            { no_chdir => 1, wanted => sub {
                    my $p = $File::Find::name;
                    my @s = lstat $p or return;
                    return if -l _;
                    my $bits = git_want_bits( $gd, $p, ( -d _ ? 1 : 0 ), @s );
                    return unless $bits;
                    $n++ if chmod( ( $s[2] & 07777 ) | $bits, $p );
            } }, $gd );
        if ($n) {
            print "fixed: restored group access on $n path(s) under lazysite/git "
                . "(version recording works again on the next save)\n";
            $fixed++;
        }
    }
    if ($git_shared_fix) {
        if ( system( 'git', "--git-dir=$git_shared_fix", 'config',
                'core.sharedRepository', 'group' ) == 0 ) {
            print "fixed: git config core.sharedRepository group "
                . "(git keeps future repo paths group-accessible, umask-independent)\n";
            $fixed++;
        }
        else { warn "could not set core.sharedRepository on $git_shared_fix\n" }
    }
    for my $f (@chmod_fixes) {
        my ( $mode, $path, $how ) = @{$f};
        my @s   = stat $path or next;      # vanished (e.g. under the tt purge)
        my $cur = $s[2] & 07777;
        $mode |= $cur if ( $how // '' ) eq 'add';
        next          if $mode == $cur;    # already in the target state - no re-print
        if ( chmod $mode, $path ) {
            printf "fixed: chmod %04o %s\n", $mode, $path;
            $fixed++;
        }
        else { warn "could not chmod $path: $!\n" }
    }
    # SM313: create the private store, so protecting content can actually move it.
    if ($store_create_needed) {
        my $s = $store_create_needed;
        if ( -d $s ) {
            # A previous iteration made it; nothing to do. --fix loops until
            # stable, so this branch is reached on the second pass.
        }
        elsif ( $> == 0 ) {
            require File::Path;
            my $err;
            File::Path::make_path( $s, { error => \$err } );
            if ( -d $s ) {
                # Owned by the site user, setgid so content moved in keeps the
                # group. The engine then writes into a directory it owns, and
                # never needs write permission on the parent.
                chown $exp_uid, $exp_gid, $s;
                chmod 02770, $s;
                printf "fixed: created the private store %s (%s:%s, mode 2770)\n",
                    $s, $exp_user, $exp_grp;
                $fixed++;
            }
            else { warn "could not create the private store $s\n" }
        }
        else {
            # Not root, and by construction the parent is not writable by us -
            # so print the exact commands rather than failing silently.
            print "skip: creating the private store needs root - run:\n"
                . "  mkdir -p '$s'\n"
                . "  chown $exp_user:$exp_grp '$s'\n"
                . "  chmod 2770 '$s'\n";
        }
    }
    # SM323: repair a store that exists but the CGI cannot write into.
    if ($store_repair_needed) {
        my $s = $store_repair_needed;
        if ( $> == 0 ) {
            # Same shape --fix creates: owned by the site user, group the CGI
            # identity, setgid so content moved in keeps the group.
            chown $exp_uid, $exp_gid, $s;
            chmod 02770, $s;
            # The contents too - a store populated by a sweep running as the site
            # user holds files the CGI cannot rewrite either, and un-protecting
            # has to move them back OUT.
            my $n = 0;
            File::Find::find(
                { no_chdir => 1, wanted => sub {
                        my $p  = $File::Find::name;
                        my @st = lstat $p or return;
                        return if -l _;
                        chown $exp_uid, $exp_gid, $p;
                        chmod( ( -d _ ? 02770 : 0660 ), $p );
                        $n++;
                } }, $s );
            printf "fixed: private store %s now %s:%s mode 2770 (%d path(s))\n",
                $s, $exp_user, $exp_grp, $n;
            $fixed++;
        }
        else {
            print "skip: repairing the private store needs root - run:\n"
                . "  chown -R $exp_user:$exp_grp '$s'\n"
                . "  chmod 2770 '$s'\n";
        }
    }
    if ($chown_needed) {
        if ( $> == 0 ) {
            # Recursive chown to the expected owner:group. Handing a path the
            # CGI currently OWNS to the site user must not strip the CGI's
            # access - replicate the owner bits onto the group first (see
            # handover_mode above).
            File::Find::find( { no_chdir => 1, wanted => sub {
                        my $p = $File::Find::name;
                        my @s = lstat $p or return;
                        return if -l _;
                        if ( defined $cgi_uid && $s[4] == $cgi_uid ) {
                            my $want = handover_mode( $s[2] );
                            chmod $want, $p if $want != ( $s[2] & 07777 );
                        }
                        chown $exp_uid, $exp_gid, $p;
            } }, $LZ );
            print "fixed: chown -R $exp_user:$exp_grp $LZ\n";
            $fixed++;
        }
        else {
            print "skip: ownership fix needs root - run:\n"
                . "  chown -R $exp_user:$exp_grp '$LZ'\n";
        }
    }
    return $fixed;
}

run_checks();

# When --fix is on, apply-and-recollect UNTIL STABLE (bounded): one pass can
# CREATE new fixable findings - the field case 2026-07-11 was the root chown
# pass handing CGI-owned files to the site user, after which the 0600 secrets
# needed a 0660 chmod that only the NEXT collection could queue; the old
# single apply pass reported that new damage but never repaired it ("--fix
# said fixed, the site still 500s"). Each iteration re-collects, so the
# report below always describes the tree as it now IS (SM139 increment 5).
my $fixes_applied = 0;
if ( $opt{fix} ) {
    for my $pass ( 1 .. 3 ) {
        my $n = apply_fixes();
        $fixes_applied += $n;
        run_checks();
        last unless $n;
    }
}

# --- report ------------------------------------------------------------------
my %icon = ( OK => '  ok  ', WARN => ' warn ', FAIL => ' FAIL ' );
my ( $fails, $warns ) = ( 0, 0 );
print "\nlazysite-check  docroot=$DOC  expect-owner=$exp_user:$exp_grp\n";
print "(--fix applied $fixes_applied change(s); this report reflects the post-fix state)\n"
    if $fixes_applied;
print "\n";
for my $r (@results) {
    $fails++ if $r->{level} eq 'FAIL';
    $warns++ if $r->{level} eq 'WARN';
    printf "[%s] %s\n", $icon{ $r->{level} }, $r->{msg};
    printf "         -> %s\n", $r->{hint} if $r->{hint} && $r->{level} ne 'OK';
}
printf "\n%d ok, %d warning(s), %d failure(s)%s\n",
    scalar( grep { $_->{level} eq 'OK' } @results ), $warns, $fails,
    ( !$opt{fix} && ( $fails || $warns ) ? "  (re-run with --fix to apply the chmod/chown fixes)" : "" );
exit( $fails ? 1 : 0 );

# --- helpers -----------------------------------------------------------------
sub conf_value {
    my ( $file, $key ) = @_;
    open my $fh, '<', $file or return undef;
    my $val;
    while ( my $l = <$fh> ) { if ( $l =~ /^\Q$key\E\s*:\s*(.+)/ ) { $val = $1; last } }
    close $fh;
    return undef unless defined $val;
    $val =~ s/^\s+|\s+$//g;
    return $val;
}

# SM288 WIDENS ACCESS ON UPGRADE, so the operator gets to see it coming.
#
# An @group ACL entry used to match a cookie user and a WebDAV partner, and
# silently never matched the same account over MCP or the control API. From
# SM288 it matches everywhere - which is the intended behaviour and is still a
# change of effective permissions on a live site. Nobody should discover that
# from a changelog line.
#
# Informational, never a WARN: an @group entry is a normal thing to have and
# nagging about it would teach the reader to skip this section. It reports the
# entries and who resolves into them, so "who gains" is answerable before the
# upgrade rather than after.
# SM593: on an instance serving several unrelated domains, a table that names
# no `domain:` is reachable by ANY manage_data holder - including a partner
# scoped to a neighbouring domain, who is not supposed to know it exists.
#
# A WARNING RATHER THAN A FAILURE, and only where several domains are
# configured. On a single-site instance the instance-wide namespace is the only
# namespace there is and the key would be noise; the exposure needs a second
# party before it is an exposure. This is also the migration list: an instance
# upgrading into the release keeps every table working, and this names the ones
# still to scope.
sub report_unscoped_data_tables {
    my $d = $opt{docroot};
    my $dir = "$d/lazysite/db/tables";
    return unless -d $dir;

    # Several domains configured? `alias_hosts` is the list SM151 keys the
    # multi-domain instance on, read here the same way every other conf value
    # in this tool is read.
    my $aliases = conf_value( $conf, 'alias_hosts' ) // '';
    my @hosts = grep { length } map { s/^\s+|\s+$//gr } split /,/, $aliases;
    return unless @hosts;    # one domain: nothing to be confined from

    opendir( my $dh, $dir ) or return;
    my @files = sort grep { /\.ya?ml\z/ } readdir $dh;
    closedir $dh;
    return unless @files;

    my ( @unscoped, @scoped );
    for my $f (@files) {
        ( my $name = $f ) =~ s/\.ya?ml\z//;
        my $txt = '';
        if ( open my $fh, '<', "$dir/$f" ) { local $/; $txt = <$fh>; close $fh }
        # Read as TEXT, not through the YAML parser: this tool runs on installs
        # where the data plugin's modules may not be present, and a check that
        # cannot run where the problem lives is not a check.
        if ( $txt =~ /^domain:\s*\S/m ) { push @scoped, $name }
        else                            { push @unscoped, $name }
    }
    return unless @unscoped;

    report( 'WARN',
        sprintf( '%d data table%s %s no domain on a %d-domain instance: %s',
            scalar @unscoped,
            ( @unscoped == 1 ? ''      : 's' ),
            ( @unscoped == 1 ? 'names' : 'name' ),
            scalar @hosts + 1, join( ', ', @unscoped ) ),
        'Any manage_data holder on this instance reads them, including a '
            . 'partner scoped to another domain - and a table name is itself a '
            . "disclosure. Add `domain: <host>` to each descriptor in "
            . "lazysite/db/tables/. See /docs/data-tables."
    );
    report( 'OK',
        sprintf( '%d data table%s scoped to a domain',
            scalar @scoped, ( @scoped == 1 ? ' is' : 's are' ) )
    ) if @scoped;
    return;
}

sub report_group_acl_reach {
    my $d = $opt{docroot};
    # SM551: through the engine-tree resolver, never "$d/lazysite/..." by hand -
    # on a migrated site (SM293) that path does not exist and this section
    # reported nothing while rules were in force.
    my $f = _acls_file($d);
    return unless -f $f;

    my $map = _read_json($f);
    return unless ref $map eq 'HASH';

    # Every @group named by any entry, in any mode.
    return unless keys %$map;

    # SM287: is anything site-wide? Informational, deliberately NOT a warning,
    # and reported BEFORE the @group section because it is a different question
    # and a site can have one without the other.
    #
    # Enumerating top-level folders is a legitimate choice and nagging about it
    # would teach the reader to skip this section. But it fails OPEN as content
    # grows - a file added at the docroot root next month is public, with
    # nothing else in this tool to say so - and an operator who believes the
    # site is closed should be able to see which of the two shapes they have.
    my $has_root = grep { exists $map->{$_} } ( '/', '', '.', './' );
    report( 'OK',
        $has_root
        ? 'a site-wide ACL rule is in force - every path is governed unless a '
            . 'more specific entry says otherwise'
        : 'access is granted per path; there is no site-wide rule, so anything '
            . 'added outside the listed paths is public (use "/" if the whole '
            . 'site should be private)' );

    my %wanted;
    for my $path ( keys %$map ) {
        my $e = $map->{$path};
        next unless ref $e eq 'HASH';
        for my $mode (qw(read write)) {
            my $list = $e->{$mode};
            next unless ref $list eq 'ARRAY';
            for my $entry (@$list) {
                next unless defined $entry && $entry =~ /\A\@(.+)\z/;
                push @{ $wanted{ lc $1 } }, "$path ($mode)";
            }
        }
    }
    return unless %wanted;

    # DELIBERATELY NOT RESOLVING MEMBERSHIP HERE.
    #
    # The honest options were: duplicate the closure logic (a fourth answer to
    # "which groups is this account in", which is the defect SM288 exists to
    # remove, so no), report DIRECT membership only (which omits anyone in a
    # nested group and would tell an operator that somebody does not gain access
    # when they do), or name the entries and point at the tool that knows. This
    # file is core-Perl by design and cannot load Lazysite::Auth::Settings.
    #
    # Under-reporting who gains access is worse than not reporting it.
    for my $g ( sort keys %wanted ) {
        report( 'OK',
            "\@$g is granted by " . join( ', ', sort @{ $wanted{$g} } ) );
    }
    report( 'OK',
        'SM288: these @group entries now apply on EVERY channel, including MCP '
            . 'and the control API, where they were silently inert before. '
            . 'For who is in each group, including via nested groups: '
            . 'lazysite-users.pl --docroot <docroot> groups' );
    return;
}

# ---------------------------------------------------------------------------
# SM285: the ACL self-probe.
#
# Everything else in this tool inspects the site from the inside. This asks the
# only question that matters from the outside, and it is the question nothing
# could answer before: WHEN THE ENGINE REFUSES A FILE, DOES THE VISITOR ACTUALLY
# GET REFUSED? Front-end configuration decides that, lazysite ships templates it
# cannot test where they are installed, and on most deployments we have no
# access to look. SM248, SM268 H17 and SM283 were all that gap; SM283 was live
# across a fleet for weeks and was found by a person fetching a URL by hand.
#
# WHY SEVERAL EXTENSIONS, which is the whole design. SM283 leaked .png, .pdf,
# .txt and .bin and gated .dat - because .dat was the one extension absent from
# the front end's static list. A probe using one extension would have picked
# .dat and reported OK. Deciding by extension cannot be made safe, so neither
# can testing one.
#
# A SUB, not a file-scoped `my` list. The first version was
# `my @PROBE_EXT = qw(...)` down here, and this file executes its main body near
# the top - so the list was still EMPTY when the probe ran. The loop iterated
# zero times, `@gated == @PROBE_EXT` compared 0 with 0, and the probe reported
# "the front end respects the ACL" against a port with nothing listening on it.
# A security check that passes by testing nothing is the exact defect this whole
# programme is about, and it survived until a test drove a real leaking front
# end at it.
sub _probe_exts { return qw(png pdf txt css gz dat) }

# ---------------------------------------------------------------------------
# SM293: which layout this site has, and a FAIL if it has both.
#
# `lazysite/` holds config, credentials, the audit log, session state, form
# submissions and pre-install snapshots. Inside the docroot it is kept
# unreachable by a `deny /lazysite/` repeated in every shipped front-end
# template - the same arrangement SM248, SM268 H17 and SM283 each turned out to
# be. SM283's proxy answered static extensions off the docroot, so on any host
# whose list includes `gz` it would have served
# `lazysite/backups/preinstall-*.tar.gz`: the whole site, including the account
# store, to anyone who knew the path.
#
# A site migrates by MOVING the directory beside its docroot. Both layouts work,
# so this reports rather than nags - EXCEPT for the half-migrated state, which is
# a genuine fault and an invisible one: the engine reads the outside copy while
# the front end can still serve the inside one, so the site behaves perfectly and
# publishes its credentials.
# SM293 step 3: registries left over from before they were engine-served.
#
# They used to be written into the content root and served from disk. Now they
# are generated on request and cached outside it - but a file left at the old
# path is still resolved by the front end BEFORE the engine is consulted, so it
# keeps being served and nothing ever regenerates it. A sitemap frozen on the day
# of the upgrade, quietly, is the failure mode.
#
# WARN, not FAIL: a stale sitemap is an SEO problem, not a disclosure. And the
# operator may have authored their own on purpose, which the engine deliberately
# yields to - so this names the files and explains, rather than deleting them.
sub report_stale_registries {
    my $d = $opt{docroot};
    return unless -d "$LZ/templates/registries";

    my @names;
    if ( opendir my $dh, "$LZ/templates/registries" ) {
        @names = map { s/\.tt\z//r } grep { /\.tt\z/ } readdir $dh;
        closedir $dh;
    }
    return unless @names;

    my @found = grep { -f "$d/$_" } sort @names;
    return unless @found;

    report(
        'WARN',
        'these generated files are still in the document root: '
            . join( ', ', @found )
            . ' - the engine now generates them on request and caches them '
            . 'outside the document root, so a file left here is served '
            . 'instead and never refreshed',
        'if you did not write them yourself, delete them and the engine will '
            . 'serve a current one. If you DID write your own, leave it: the '
            . 'engine yields to it deliberately.'
    );
    return;
}

sub report_engine_tree {
    my $d = $opt{docroot};

    require Lazysite::Paths;
    my $ext    = Lazysite::Paths::external_lazysite_dir($d);
    my $inside = "$d/lazysite";

    if ( Lazysite::Paths::stray_lazysite($d) ) {
        report(
            'FAIL',
            'this site has an engine tree in BOTH places - beside the document '
                . 'root AND inside it. The engine reads the one outside, so the '
                . 'site works; the one inside is still where a web server can '
                . 'serve it.',
            'confirm the tree beside the document root is the current one '
                . '(compare lazysite.conf and auth/), then remove the copy '
                . 'inside the document root. This tool will not delete '
                . 'credentials for you.'
        );
        return;
    }

    if ( defined $ext && -d $ext ) {
        report( 'OK',
            'the engine tree is held outside the document root, so no '
                . 'front-end rule is needed to keep config, credentials and '
                . 'snapshots unreachable' );
        return;
    }

    if ( -d $inside ) {
        # Deliberately not a WARN. Both layouts are supported, the deny rules
        # are in every shipped template, and nagging every site on every run
        # teaches the reader to skip the section - which is where the FAIL
        # above lives.
        report( 'OK',
            'the engine tree is inside the document root, kept '
                . 'unreachable by the front end`s deny rules - supported, and '
                . 'the alternative is to move it beside the document root, '
                . 'after which no such rule is needed' );
    }
    return;
}

# ---------------------------------------------------------------------------
# SM286: content that exists in BOTH trees.
#
# The private store's one invariant is that a path lives in exactly one tree.
# A path in both is always a fault, and always the same fault in the same
# direction: the private copy is the one the engine governs, and the public one
# is reachable without asking the engine at all. That is SM283 restored for a
# single file - the gate holds everywhere the engine is consulted, and the front
# end serves the copy beside it.
#
# It cannot arise from a completed move (move_in renames, and refuses when the
# destination is already occupied rather than overwriting). It arises from a
# move interrupted mid-copy on a cross-device fallback, from a restore of an
# archive written before the content was protected, and from an operator putting
# a file back by hand - none of which anything else would notice.
#
# FAIL, not WARN. The site is serving content it has been told to protect. And
# reported rather than repaired: which copy to delete is a content decision, and
# a tool that silently removes an operator's file to fix a permission problem is
# a worse tool than one that tells them.
# SM296: can the engine put protected content where it belongs?
#
# Protecting content moves it to <docroot>-lazysite-private, which the CGI has to
# CREATE the first time - a directory beside the document root, in the domain
# folder. On some layouts that parent is not writable by the CGI identity, and
# then every protect operation warns instead of moving: the rule is stored and
# honoured for pages while the files stay in the document root and go on being
# served. Correct, documented, and completely invisible unless something asks.
#
# It was worse than invisible on 0.10.8, where the same condition crashed the
# call outright (SM296). The crash is fixed; this is the half that tells an
# operator whether their site can protect anything at all BEFORE they try.
#
# FAIL, because a site that cannot move content cannot honour the protection its
# own manager offers - and the operator would otherwise learn that from a warning
# buried in one API response.
# SM309: say whether front-door mode is actually on for this site.
#
# SM294 moved the front door under the FastCGI pool in 0.10.9. Whether it is
# running is decided by FRONT_DOOR= in /etc/lazysite/pools/<instance>.conf, which
# is an operator step - and until now NOTHING reported whether that step had been
# taken. `X-Lazysite-Front` exists only in the SM283 proxy template, so on any
# instance without that template installed - which is the instance the SM283
# sweep is still pending on - the mode was indistinguishable from its absence.
#
# A 0.10.9 field test measured ten anonymous samples before and after the
# upgrade, found no difference network noise could resolve, and had no way to
# establish whether the feature was even active. That is the situation 0.10.7
# added an observable for, after three rebuilds and a template install produced
# byte-identical responses; SM294 is a LARGER behavioural change than that one
# and had less observability.
#
# Read from the pool conf on disk rather than from what an installer intended to
# write, and matched to THIS docroot rather than to the instance name, because
# the instance name is conventionally the domain and nothing enforces that. A
# check that reported the wrong site's setting would be worse than none.
sub report_front_door_mode {
    my $dir = '/etc/lazysite/pools';
    return unless -d $dir;    # no pools configured: plain CGI, nothing to say

    opendir my $dh, $dir or return;
    my @confs = sort grep { /\.conf\z/ } readdir $dh;
    closedir $dh;

    my $want = abs_path( $opt{docroot} ) // $opt{docroot};
    my ( $mine, $raw );
    for my $c (@confs) {
        open my $fh, '<', "$dir/$c" or next;
        my ( $doc, $fd );
        while ( my $l = <$fh> ) {
            $doc = $1 if $l =~ /^\s*DOCROOT\s*=\s*"?([^"\s]+)"?/;
            $fd  = $1 if $l =~ /^\s*FRONT_DOOR\s*=\s*"?([^"\s]*)"?/;
        }
        close $fh;
        next unless defined $doc;
        my $r = abs_path($doc) // $doc;
        next unless $r eq $want;
        ( $mine, $raw ) = ( $c, $fd );
        last;
    }

    # A site with no pool conf runs plain CGI, where front-door mode does not
    # apply at all. Silence is right - a check that speaks on every healthy site
    # is one people learn to scroll past.
    return unless defined $mine;

    my $v = defined $raw ? lc $raw : '';
    $v =~ s/\A\s+|\s+\z//g;

    if ( $v =~ /\A(?:1|true|yes|on)\z/ ) {
        report( 'OK', "front-door mode is ON (FRONT_DOOR=$raw in $mine)",
            'The pool worker routes every request itself, so the vhost needs '
                . 'one rule rather than a dozen.' );
    }
    elsif ( $v eq '' || $v =~ /\A(?:0|false|no|off)\z/ ) {
        report( 'OK',
            'front-door mode is OFF'
                . ( length $v ? " (FRONT_DOOR=$raw in $mine)" : " (not set in $mine)" ),
            'Set FRONT_DOOR=1 in the pool conf and restart the pool to enable '
                . 'it. Off is the default, so an existing pool behaves exactly '
                . 'as it did.' );
    }
    else {
        # The pool now refuses to start on this (SM309), so a site in this state
        # has a stopped pool - which the operator will meet as an outage with no
        # obvious cause unless something names the line.
        report( 'FAIL', "FRONT_DOOR=$raw in $mine is not a yes/no value",
            'The pool refuses to start rather than guess, so this site is not '
                . 'serving through its pool. Use 1, true, yes or on to switch '
                . 'front-door mode on; 0, false, no or off to switch it off.' );
    }
}

# SM315: an active theme whose assets never reached the mirror is a site that is
# rendering unstyled RIGHT NOW.
#
# Theme assets live at layouts/<layout>/themes/<theme>/assets/ and are mirrored
# to /lazysite-assets/<layout>/<theme>/ at activation. Put them one level higher
# and everything succeeds - upload, activation, every page - and the stylesheet
# link is never emitted, because `theme_assets` resolves to nothing. At the HTTP
# level the result is indistinguishable from a working site: 200, valid markup,
# correct content, browser default serif.
#
# SM315 makes activation say so at the moment it happens. This is the standing
# version, for a site that was already in that state, or that got there by some
# other route - a partial deploy, a mirror cleared by hand, an asset directory
# that vanished. The activation warning cannot help those.
sub report_theme_assets_mirrored {
    # SM550: conf_value is ($file, $key). Called with the key alone it opened a
    # file named `layout`, so this check returned before looking - and had
    # never run since SM315 shipped it.
    my $layout = conf_value( $conf, 'layout' );
    my $theme  = conf_value( $conf, 'theme' );
    return unless defined $layout && length $layout;
    return unless defined $theme  && length $theme;

    my $tdir = "$LZ/layouts/$layout/themes/$theme";
    return unless -d $tdir;    # not a layout-and-theme site; nothing to say

    my $mirror = "$DOC/lazysite-assets/$layout/$theme";
    my $n      = 0;
    File::Find::find(
        { no_chdir => 1, wanted => sub { $n++ if -f $File::Find::name } },
        $mirror ) if -d $mirror;

    return report( 'OK', "theme assets are mirrored ($n file(s) for $layout/$theme)" )
        if $n;

    # Nothing mirrored. Name the likely cause rather than the symptom: an author
    # who put the CSS beside theme.json has made one specific mistake and needs
    # one specific sentence.
    my @misplaced;
    if ( opendir my $dh, $tdir ) {
        @misplaced = sort grep { /\.(?:css|js|woff2?|ttf|png|jpe?g|svg|webp)\z/i }
            readdir $dh;
        closedir $dh;
    }

    report(
        'FAIL',
        "the active theme $layout/$theme has no mirrored assets"
            . ( @misplaced
            ? ' - but ' . join( ', ', @misplaced ) . " sit directly in $tdir"
            : '' ),
        ( @misplaced
            ? "move them into $tdir/assets/ and re-activate the layout. "
            : "if this theme has a stylesheet it belongs in $tdir/assets/. " )
            . 'Until then every page renders with no stylesheet and still '
            . 'returns 200, so nothing else will report it.'
    );
    return;
}

sub report_private_store_usable {
    my $d = $opt{docroot};

    require Lazysite::Private;
    my $store = Lazysite::Private::private_root($d) or return;

    # Only when the site actually protects something, or already has a store.
    #
    # A site that has never gated a path does not need the store and will never
    # try to create it, so demanding a writable parent everywhere would fail
    # every ordinary layout for a facility it is not using. That is the same
    # reasoning that made SM223 safe to ship - no ACL store, no change - and the
    # same reason this section stays quiet rather than nagging: a check that
    # cries on healthy sites is a check people learn to scroll past.
    my $gating = 0;
    if ( open my $afh, '<:raw', "$LZ/auth/acls.json" ) {
        my $raw = do { local $/; <$afh> };
        close $afh;
        my $map = eval { JSON::PP::decode_json( $raw // '{}' ) };
        if ( ref $map eq 'HASH' ) {
            for my $k ( keys %$map ) {
                my $e = $map->{$k};
                next unless ref $e eq 'HASH';
                next if $k =~ m{\A[/.]*\z};    # the site-wide rule moves nothing
                next
                    unless $e->{draft}
                    || ( ref $e->{read} eq 'ARRAY' && @{ $e->{read} } );
                $gating = 1;
                last;
            }
        }
    }
    return unless $gating || -e $store;

    if ( -d $store ) {
        # It exists. The question is then whether the CGI can write INTO it.
        my @st = stat $store;
        if ( cgi_can( 2, @st ) && cgi_can( 1, @st ) ) {
            report( 'OK',
                'the private store exists and the engine can write to it' );
        }
        else {
            # SM323: REPAIR it, do not merely name it.
            #
            # SM313 taught --fix to CREATE a missing store and stopped there, so
            # a store that exists and is unusable was reported on every run and
            # repaired by nothing. That is the state edge reached: the operator
            # sweep runs as the SITE USER and creates the store through
            # Private::_mkpath, which sets no ownership and no mode - so the
            # store ends up owned by the site user with a umask default, and the
            # CGI identity cannot write into it.
            #
            # The consequence is that protecting content became an OPERATOR-ONLY
            # operation: `acl reapply` works, and the manager UI, MCP and the
            # control API all return a warning with the content still served, on
            # a product whose partner surfaces are supposed to do exactly this.
            #
            # Whichever creator runs first decides. That is the argument for
            # declaring the store in runtime_paths (SM321) so there is ONE
            # description of what it should be - this repairs a store that
            # already exists in the wrong shape, which the declaration alone
            # cannot do.
            $store_repair_needed = $store;
            report(
                'FAIL',
                'the private store exists but the engine cannot write to it '
                    . sprintf( '(%s, owner %s:%s, mode %04o)',
                    $store, owner_name($store), group_name($store),
                    mode_of($store) ),
                'protecting content stores the rule and leaves the files in the '
                    . 'document root, so the manager UI, MCP and the control API '
                    . 'cannot protect anything - only the operator sweep can. '
                    . 'Run with --fix as root to repair the ownership and mode.'
            );
        }
        return;
    }

    if ( -e $store ) {
        report( 'FAIL',
            "something that is not a directory is at $store",
            'the engine cannot create the private store while that exists; move '
                . 'it aside.' );
        return;
    }

    # It does not exist yet, so the question is whether it CAN be created.
    my $parent = $store;
    $parent =~ s{/[^/]+\z}{};
    my @pst = stat $parent;
    unless (@pst) {
        report( 'FAIL', "the private store's parent does not exist: $parent" );
        return;
    }
    if ( cgi_can( 2, @pst ) && cgi_can( 1, @pst ) ) {
        report( 'OK',
            'the private store does not exist yet and the engine can create '
                . 'it when content is first protected' );
        return;
    }
    # SM313: --fix CREATES the store rather than widening its parent.
    #
    # SM270's repair covers the DOCROOT. The store is a SIBLING of the docroot,
    # so creating it needs write access on the docroot's PARENT - a different
    # directory, which that repair never touched. Confirmed in the field on
    # 2026-08-15: after a complete and successful docroot repair, protecting a
    # folder still left 11 of 11 entries public and 8 of 10 probed extensions
    # serving 200 anonymously under an active read rule.
    #
    # THE OBVIOUS REPAIR IS THE WRONG ONE. Making the parent group-writable is
    # "the same operation one directory up", and on the Hestia layout that parent
    # is the domain folder - which also holds cgi-bin. Write permission on a
    # directory is permission to create, delete and RENAME its entries, so that
    # would let anything running as the CGI group replace cgi-bin. Repairing an
    # exposure by opening a larger one is not a repair.
    #
    # Creating the store instead is strictly narrower and it removes the need for
    # the permission entirely: the engine never has to create the directory, only
    # write into one it already owns. `_mkpath` becomes a no-op on the next
    # protect. setgid (2770) so content moved in keeps the group, matching how
    # every other lazysite-owned directory is provisioned.
    $store_create_needed = $store;
    report(
        'FAIL',
        'the private store does not exist and the engine cannot create it - '
            . sprintf( '%s is owner %s:%s mode %04o',
            $parent, owner_name($parent), group_name($parent), mode_of($parent) ),
        'until the store exists, protecting content stores the rule and leaves '
            . 'the files in the document root, where a front end serves them - '
            . 'this is SM283 reached through the mechanism built to prevent it. '
            . 'Run with --fix as root to create it. Note that repairing the '
            . 'DOCROOT does not fix this: the store is its sibling, not its '
            . 'child.'
    );
    return;
}

sub report_stray_public {
    my $d = $opt{docroot};

    require Lazysite::Private;
    my $root = Lazysite::Private::private_root($d);
    return unless defined $root && -d $root;

    my @stray;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                return if -l $p || !-f $p;
                my $rel = substr $p, length($root) + 1;
                push @stray, $rel if -e "$d/$rel";
            },
        },
        $root
    );

    unless (@stray) {
        report( 'OK',
            'protected content is held outside the document root, with no '
                . 'public copy left beside it' );
        return;
    }

    # Cap the listing, but never the COUNT - a truncated list that does not say
    # it was truncated reads as the whole problem.
    my $n     = scalar @stray;
    my @shown = @stray[ 0 .. ( $n > 10 ? 9 : $n - 1 ) ];
    report(
        'FAIL',
        "$n protected "
            . ( $n == 1 ? 'file is' : 'files are' )
            . ' ALSO present in the document root, where the front end serves '
            . 'them without asking the engine: '
            . join( ', ', @shown )
            . ( $n > 10 ? sprintf( ' (and %d more)', $n - 10 ) : '' ),
        'the copy in the document root is the exposure. Confirm the copy in '
            . 'the private store is the current one, then remove the public '
            . 'copy - this tool will not delete content for you.'
    );
    return;
}

END { _acl_probe_cleanup() if defined $PROBE_DIR || defined $PROBE_KEY }

sub _acl_probe_marker { join '', map { sprintf '%02x', int rand 256 } 1 .. 16 }

# SM551: the engine tree may sit beside the docroot (SM293); resolve it the
# way run_checks does rather than assuming it is inside.
sub _acls_file { my ($d) = @_; return Lazysite::Paths::lazysite_dir($d) . '/auth/acls.json' }

# Read the ACL store as raw text -> hash. Deliberately not via
# Lazysite::Auth::Acl: this tool is core-Perl only and runs where the library
# may not be installed.
sub _acl_read {
    my ($d) = @_;
    my $f = _acls_file($d);
    return {} unless -f $f;
    return _read_json($f) || {};
}

sub _acl_write {
    my ( $d, $map ) = @_;
    my $f   = _acls_file($d);
    my $tmp = "$f.probe.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($map);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $f;
}

# Remove the probe's file tree and its ACL entry. RE-READS the store rather than
# restoring a copy taken earlier, so a rule the operator added while the probe
# was running is not silently reverted.
sub _acl_probe_cleanup {
    if ( defined $PROBE_KEY ) {
        my $d = $opt{docroot};

        # SM377: unprotect through the ENGINE, so the content it moved comes
        # back and the private store is not left holding a probe folder nobody
        # can see. Deleting the acls.json key alone would orphan it - the
        # inverse of the defect this probe had, and just as quiet.
        my $removed = 0;
        if ( defined $Lazysite::Manager::Files::DOCROOT ) {
            $removed = _probe_unprotect( $d, $PROBE_KEY );
        }
        unless ($removed) {
            my $map = _acl_read($d);
            if ( delete $map->{$PROBE_KEY} ) { _acl_write( $d, $map ) }
        }

        # Whatever route was taken, the private copies are this probe's litter
        # and are removed by path rather than by trusting the move back.
        if ( eval { require Lazysite::Private; 1 } ) {
            my $priv = Lazysite::Private::private_path( $d, $PROBE_KEY );
            if ( defined $priv && -d $priv ) {
                if ( opendir my $ph, $priv ) {
                    for my $e ( readdir $ph ) {
                        next if $e eq '.' || $e eq '..';
                        unlink "$priv/$e";
                    }
                    closedir $ph;
                }
                rmdir $priv;
            }
        }
        undef $PROBE_KEY;
    }
    if ( defined $PROBE_DIR ) {
        if ( -d $PROBE_DIR ) {
            opendir my $dh, $PROBE_DIR or return;
            for my $e ( readdir $dh ) {
                next if $e eq '.' || $e eq '..';
                unlink "$PROBE_DIR/$e";
            }
            closedir $dh;
            rmdir $PROBE_DIR;
        }
        # The public controls sit BESIDE the folder, not inside it, so they need
        # removing separately - they are ordinary readable files and leaving one
        # behind would be litter in the operator's docroot.
        unlink glob("$PROBE_DIR-open.*");
        undef $PROBE_DIR;
    }
    return;
}

# Sweep anything a previous interrupted run left behind, so the tool self-heals
# rather than accumulating gated directories nobody knows about.
sub _acl_probe_sweep {
    my ($d)     = @_;
    my $map     = _acl_read($d);
    my $changed = 0;
    for my $k ( keys %$map ) {
        next unless $k =~ m{\Alazysite-acl-probe-};
        delete $map->{$k};
        $changed = 1;
    }
    _acl_write( $d, $map ) if $changed;

    opendir my $dh, $d or return;
    my @stale = grep { /\Alazysite-acl-probe-/ } readdir $dh;
    closedir $dh;
    for my $s (@stale) {
        if ( -d "$d/$s" ) {
            opendir my $sd, "$d/$s" or next;
            for my $e ( readdir $sd ) {
                next if $e eq '.' || $e eq '..';
                unlink "$d/$s/$e";
            }
            closedir $sd;
            rmdir "$d/$s";
        }
        else { unlink "$d/$s" }    # a stray public control
    }
    report( 'OK', 'cleared a probe left by an interrupted earlier run' )
        if $changed || @stale;
    return;
}

# Read a JSON file into a hash. undef when the file cannot be opened or does
# not decode to an object - the callers each decide what that means for them,
# which is why this does not substitute a default of its own.
sub _read_json {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ref $d eq 'HASH' ? $d : undef;
}

# One anonymous GET. Returns (status, body). Cache directives on purpose: a
# cached 200 from an intermediary must not be mistaken for the origin serving
# the file, and neither must it hide a leak.
sub _probe_get { return _curl( '-sS', $_[0], qr/\n(\d{3})\z/ ) }

# The one curl invocation both probes make. $mode is the only difference in the
# command line, and $tail the only difference in how the status code is peeled
# off the end of the output.
sub _curl {
    my ( $mode, $url, $tail ) = @_;
    my @cmd = (
        'curl', $mode,                     '-k', '--max-time', '8',
        '-H',   'Cache-Control: no-cache', '-H', 'Pragma: no-cache',
        '-w',   "\n%{http_code}",          $url,
    );
    open my $ph, '-|', @cmd or return ( '', '' );
    my $out = do { local $/; <$ph> };
    close $ph;
    return ( '', '' ) unless defined $out;
    my $code = '';
    if ( $out =~ s/$tail// ) { $code = $1 }
    return ( $code, $out );
}

# SM319: every path that returns WITHOUT FETCHING says "ACL PROBE SKIPPED".
#
# The token is a designated marker, not incidental prose. A caller has to be able
# to tell "the front end honoured the rule" from "nothing was measured", and the
# deploy's caller is a shell script reading this output - so the distinction has
# to survive someone improving the wording. t/tools/41 pins the token on both
# sides for exactly that reason.
#
# This matters because absence-of-FAIL was read as a pass one layer up, which is
# the defect THIS PROBE ITSELF shipped with: SM285's first implementation had an
# empty extension list, made zero fetches, and reported the front end as
# respecting the ACL against a port with nothing listening.
# SM377: APPLY PROTECTION THE WAY THE ENGINE DOES, OR MEASURE NOTHING.
#
# _acl_write stores acls.json and nothing else. The engine protects content by
# MOVING it into the private store, so a probe that only writes the rule leaves
# its own files in the document root - where a front end serving statics by
# extension serves them CORRECTLY, because nothing ever protected them. The
# probe then read that as the site's protected content being reachable, and
# reported FAIL in the same run where the check above reported "protected
# content is held outside the document root". Two checks, one tool, one run.
#
# content_moved is the assertion that makes this honest. It is a structural flag
# (SM313) rather than a match on warning text, so it cannot be improved away: if
# it is absent or zero, this probe has not established the condition it is about
# to measure, and it says so instead of measuring.
sub _probe_load_engine {
    my ($d) = @_;
    return 'this build cannot load the engine modules'
        unless eval {
        require Lazysite::Manager::Files;
        require Lazysite::Manager::Common;
        require Lazysite::Auth::Acl;
        require Lazysite::Paths;
        1;
        };

    my $root = $d;
    $root =~ s{/+\z}{};

    # `no warnings 'once'` because these package globals are SET here and read
    # inside the engine modules, so this file mentions each exactly once - which
    # is indistinguishable from a typo to perl and printed as one on every run.
    no warnings 'once';    ## no critic (ProhibitNoWarnings)
    $Lazysite::Manager::Files::DOCROOT = $root;
    $Lazysite::Manager::Files::LOCK_DIR
        = Lazysite::Paths::lazysite_dir($root) . '/cache/locks';
    $Lazysite::Manager::Common::DOCROOT = $root;
    $Lazysite::Auth::Acl::DOCROOT       = $root;
    $Lazysite::Auth::Acl::token_auth    = 0;
    return '';
}

# Protecting MOVES content, creating directories in the private store as it
# goes. SM139: lazysite never writes into a site tree as root, because
# root-owned files there are exactly what stops the manager working afterwards
# (the Class-B drift SM215 repairs). So as root this probe declines to establish
# the state rather than establishing it badly.
sub _probe_may_protect {
    return 'running as root - protecting content here would leave root-owned '
        . 'files in the site tree (SM139); run the probe as the site user'
        if $> == 0 || $ENV{LAZYSITE_CLI_FAKE_ROOT};
    return '';
}

sub _probe_protect {
    my ( $d, $name ) = @_;
    my $r = eval {
        local $Lazysite::Manager::Files::auth_user = 'local';
        local $Lazysite::Auth::Acl::auth_user      = 'local';
        local @Lazysite::Auth::Acl::user_groups    = ();
        Lazysite::Manager::Files::action_acl_set( "/$name/", 'local',
            ['__lazysite-acl-probe-nobody__'], undef, undef, undef );
    };
    return ( 0, "the engine refused to protect the probe folder: $@" )
        if !$r || $@;
    return ( 0, "the engine refused to protect the probe folder: "
            . ( $r->{error} // 'no reason given' ) )
        unless $r->{ok};

    # THE ASSERTION. A rule stored with nothing moved is the exact state that
    # produced the wrong answer for five months of this probe's life.
    return ( 0, 'the rule was stored but no content moved out of the document '
            . 'root, so nothing here was ever protected' )
        unless $r->{content_moved};
    return ( 1, '' );
}

sub _probe_unprotect {
    my ( $d, $name ) = @_;
    return eval {
        local $Lazysite::Manager::Files::auth_user = 'local';
        local $Lazysite::Auth::Acl::auth_user      = 'local';
        local @Lazysite::Auth::Acl::user_groups    = ();
        Lazysite::Manager::Files::action_acl_remove( "/$name/", 'local' );
        1;
    } ? 1 : 0;
}

# SM377 FOLLOW-UP: detect a bypassing front end WITHOUT any protected content.
#
# Fixing SM377 cost the probe this. It now protects the way the engine does,
# which MOVES content out of the document root - so a front end answering
# statics on its own has nothing left to serve and looks identical to one
# routing correctly. The detection was lost precisely because the probe got
# honest.
#
# THE ENGINE'S OWN HEADERS ANSWER IT DIRECTLY. Since SM352 every response the
# engine writes carries the security header set, so their ABSENCE on a static is
# the signature of something else having answered it. No ACL, no fixture files,
# no credentials, nothing to clean up - two GETs.
#
# THE PAGE REQUEST IS LOAD-BEARING and is the first thing a later reader will
# delete as redundant. Without it, "no headers on a static" is ambiguous between
# a bypassing front end and an engine setting no headers anywhere. The page
# establishes that this instance does set them, so the static's silence means
# something. Same shape as the pre-protection fetch in the gating fixture: the
# step that exists to create the confusable case looks like waste until it is
# gone.
#
# NOT HSTS, AND NOT CSP, though a field measurement used HSTS. HSTS is emitted
# only over TLS and CSP only on HTML, so either would report a bypass on a
# plain-HTTP instance or against any static at all. The unconditional markers
# are the ones to compare.
#
# WHAT THIS DOES NOT SAY, stated because the last probe's inference is what went
# wrong: it does NOT mean content is exposed. Protected content has left the
# served tree (SM286), so a front end answering statics is answering public
# files, correctly. This is the PRECONDITION for SM283-shaped exposure, and a
# fact about ROUTING rather than about access control.
sub report_engine_sees_statics {
    my ($url) = @_;
    return unless defined $url && $url =~ m{^https?://\S+$};
    $url =~ s{/+$}{};

    my @markers = ( 'x-content-type-options', 'permissions-policy' );

    my ( $pcode, $phead ) = _probe_head("$url/");
    unless ( ( $pcode // '' ) =~ /^[23]/ ) {
        report( 'WARN', 'ROUTING CHECK SKIPPED: the site root did not answer' );
        return;
    }
    my $page_has = scalar grep { $phead =~ /^\Q$_\E:/mi } @markers;

    unless ( $page_has == @markers ) {
        # The engine is not setting them anywhere, so a static's silence would
        # mean nothing. A different fault, and not this check's to diagnose.
        report( 'WARN',
            'ROUTING CHECK SKIPPED: the engine is not setting its response '
                . 'headers on a page either, so a static cannot be compared '
                . 'against it - check the installed release first' );
        return;
    }

    my $asset = _probe_static_url($url);
    unless ( defined $asset ) {
        report( 'WARN',
            'ROUTING CHECK SKIPPED: no static asset found to compare against' );
        return;
    }

    my ( $scode, $shead ) = _probe_head($asset);
    unless ( ( $scode // '' ) =~ /^2/ ) {
        report( 'WARN',
            'ROUTING CHECK SKIPPED: the static asset did not answer' );
        return;
    }
    my $static_has = scalar grep { $shead =~ /^\Q$_\E:/mi } @markers;

    if ($static_has) {
        report( 'OK',
            'the engine answers static requests: a page and a static asset '
                . 'both carry its response headers, so nothing is intercepting '
                . 'statics ahead of it' );
        return;
    }

    # A fact about ROUTING. Deliberately says nothing about access control:
    # protected content has left the served tree, so what this front end is
    # answering is public files, correctly.
    report( 'WARN',
        'static requests are answered WITHOUT the engine: a page carries the '
            . 'engine response headers and a static asset carries none, so '
            . 'something in front is serving statics directly',
        'not an exposure on its own - protected content has been moved out of '
            . 'the served tree, so what is being served is public. It is the '
            . 'precondition for the SM283 family, and it means engine security '
            . 'headers, ACL decisions and cache behaviour do not apply to '
            . 'statics. The lazysite-proxy template routes them back.' );
    return;
}

# A HEAD request, returning ( status, headers ). Separate from _probe_get
# because this compares HEADERS and has no interest in bodies - and a HEAD
# cannot be answered from a body cache in a way that hides the difference.
sub _probe_head { return _curl( '-sSI', $_[0], qr/\n(\d{3})\s*\z/ ) }

# A static asset this site actually serves, found from the docroot rather than
# guessed - a guessed path that 404s would be indistinguishable from a bypass.
sub _probe_static_url {
    my ($url) = @_;
    my $d = $opt{docroot};
    for my $dir ( "$d/lazysite-assets", "$d/assets", $d ) {
        next unless -d $dir;
        my @found;
        _collect_statics( $dir, \@found, 0 );
        next unless @found;
        my $rel = $found[0];
        $rel =~ s{\A\Q$d\E/}{};
        return "$url/$rel";
    }
    return undef;
}

sub _collect_statics {
    my ( $dir, $out, $depth ) = @_;
    return if @$out || $depth > 3;
    opendir my $dh, $dir or return;
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $e (@entries) {
        my $p = "$dir/$e";
        next if $e eq 'lazysite';    # the engine tree is never served
        if    ( -d $p ) { _collect_statics( $p, $out, $depth + 1 ) }
        elsif ( $e =~ /\.(?:css|js|png|jpg|jpeg|gif|svg|webp)\z/i ) {
            push @$out, $p;
        }
        return if @$out;
    }
    return;
}

sub run_acl_probe {
    my ($url) = @_;
    $url =~ s{/+$}{};
    if ( $url !~ m{^https?://\S+$} ) {
        report( 'WARN', 'ACL PROBE SKIPPED: --check-acl needs an http(s):// URL' );
        return;
    }
    my $d = $opt{docroot};

    _acl_probe_sweep($d);

    my $marker = _acl_probe_marker();
    my $name   = "lazysite-acl-probe-$marker";
    $PROBE_DIR = "$d/$name";
    unless ( mkdir $PROBE_DIR ) {
        undef $PROBE_DIR;
        report( 'WARN',
            'ACL PROBE SKIPPED: cannot create a probe directory in the docroot '
                . '- this reports nothing either way about the front end' );
        return;
    }
    my @exts = _probe_exts();
    unless (@exts) {
        _acl_probe_cleanup();
        report( 'FAIL', 'the ACL probe has no file types to test - this is a bug '
                . 'in lazysite-check, and a probe that tests nothing must never '
                . 'report a pass' );
        return;
    }
    for my $ext (@exts) {
        open my $fh, '>', "$PROBE_DIR/probe.$ext" or next;
        print {$fh} $marker;
        close $fh;
        # The CONTROL for this extension: same bytes, same type, OUTSIDE the
        # gated folder. Without it, "refused" and "nothing here works" are the
        # same observation - a 403 because the front end cannot read the file,
        # or a site that is simply down, would read as healthy gating.
        open my $cf, '>', "$PROBE_DIR-open.$ext" or next;
        print {$cf} $marker;
        close $cf;
    }

    # SM331: FETCH THEM WHILE PUBLIC FIRST.
    #
    # This probe created its folder, gated it, and fetched it - so its files were
    # never requested while public, which is precisely the case that works. The
    # field found the case that does not: on a site protected AFTER the fact,
    # which is the whole SM283 remediation story, a file fetched while public
    # kept serving after the move, while untouched files in the same folder
    # gated. The engine had moved everything and reported it moved; something
    # downstream was still answering for the ones that had been asked for.
    #
    # A probe that cannot generate the failing case reports a healthy site while
    # that case leaks - which is SM283's own shape, where a one-extension probe
    # passed a leaking site. So the folder is warmed before it is gated, and the
    # comparison below then covers both populations at once.
    #
    # Cheap: one extra request per extension, on a probe that already makes two.
    for my $ext (@exts) {
        _probe_get("$url/$name/probe.$ext");
    }

    # Gate the folder against a principal that cannot exist. An EMPTY read list
    # would not restrict anything - "no list for this mode" means allowed, which
    # is the documented behaviour and would make this probe pass vacuously.
    $PROBE_KEY = $name;
    for my $reason ( _probe_may_protect(), _probe_load_engine($d) ) {
        next unless length $reason;
        _acl_probe_cleanup();
        report( 'WARN', "ACL PROBE SKIPPED: $reason" );
        return;
    }
    my ( $protected, $why ) = _probe_protect( $d, $name );
    unless ($protected) {
        _acl_probe_cleanup();
        report( 'WARN', "ACL PROBE SKIPPED: $why" );
        return;
    }

    my ( @leaked, @gated, @blind );
    for my $ext (@exts) {
        my ( $code,  $body )  = _probe_get("$url/$name/probe.$ext");
        my ( $ccode, $cbody ) = _probe_get("$url/$name-open.$ext");
        my $served_gated  = defined $body  && index( $body,  $marker ) >= 0;
        my $served_public = defined $cbody && index( $cbody, $marker ) >= 0;

        print {*STDERR} "acl-probe: .$ext gated=$code public=$ccode\n"
            if $ENV{LAZYSITE_ACL_PROBE_DEBUG};

        if    ($served_gated) { push @leaked, $ext }
        elsif ( !$served_public ) {
            # The control did not come back either, so the refusal proves
            # nothing about the ACL.
            push @blind, ".$ext(gated $code / control $ccode)";
        }
        else { push @gated, $ext }
    }

    # SM368: WHICH CAUSE? Asked, rather than inferred.
    #
    # A split - some extensions served, others refused - has two candidates that
    # look identical from here:
    #
    #   SM283  the front end serves a static list by EXTENSION, straight off
    #          the docroot, without consulting the engine. An operator task.
    #   SM331  the front end still holds a descriptor for a file it fetched
    #          while the folder was public. Clears itself. Nobody's task.
    #
    # This probe reported the first, in the same sentence and the same voice as
    # the measurement, and it was wrong in the field: the finding was carried up
    # as a fleet condition needing a human and relayed onward as one, twice,
    # before anyone re-ran the experiment.
    #
    # THE DISCRIMINATOR IS ONE REQUEST. A file written AFTER the gate and never
    # fetched cannot be in any front-end cache. If it serves, the split is by
    # extension and SM283 is the answer. If it gates, the extensions that served
    # were warmed by the SM331 pass above and are cache residue.
    #
    # Only run when there IS a leak to explain, so a healthy site pays nothing.
    # SM377: THE NEVER-FETCHED FILE GOES WHERE PROTECTED CONTENT LIVES.
    #
    # The folder has left the document root by now, so writing this file to
    # $PROBE_DIR would put an UNPROTECTED file back into the docroot and it
    # would be served for the same reason the old probe's files were - which is
    # the flaw this whole change is about, reappearing one step further along.
    # It goes into the private store instead, which is where the engine just
    # moved everything else.
    my $late_verdict = '';
    if (@leaked) {
        my $late_ext = $leaked[0];
        require Lazysite::Private;
        my $late_priv = Lazysite::Private::private_path( $d, "$name/late.$late_ext" );
        my $late_ok   = 0;
        if ( defined $late_priv ) {
            my $dir = $late_priv;
            $dir =~ s{/[^/]+\z}{};
            require File::Path;
            eval { File::Path::make_path($dir); 1 };
            if ( open my $lf, '>', $late_priv ) {
                print {$lf} $marker;
                close $lf;
                $late_ok = 1;
            }
        }
        if ($late_ok) {
            my ( undef, $lbody ) = _probe_get("$url/$name/late.$late_ext");
            $late_verdict
                = ( defined $lbody && index( $lbody, $marker ) >= 0 )
                ? 'extension'
                : 'cache';
        }
    }

    _acl_probe_cleanup();

    # The verdicts. Note what is NOT said: never the filesystem path, and never
    # the name of a real file - the operator is told which EXTENSIONS leaked,
    # because that is what identifies the layer at fault.
    if (@leaked) {
        my $l = join ', ', map { ".$_" } @leaked;
        my $g = @gated ? join( ', ', map { ".$_" } @gated ) : '';
        # SM368: the CACHE verdict is not a failure of the site's gating. The
        # engine moved the content and the front end is still answering from a
        # descriptor it already held; it clears itself, and telling an operator
        # to change a template would send them after nothing.
        # SM377: THE VERDICT IS READ FROM THE PAIR, NEVER FROM ONE FILE.
        #
        # Reading the never-fetched file alone can only ever yield a binary, and
        # the distinction that matters is not two points on one scale - it is two
        # different questions:
        #
        #   warmed served / never GATED    residue. Bounded, self-clearing, and
        #                                  nobody's task (SM331)
        #   warmed served / never SERVED   a genuine bypass. Protected content
        #                                  is being served. An operator's task
        #   neither served                 gated, nothing to report
        #
        # Those have opposite consequences, and the old probe collapsed them.
        if ( $late_verdict eq 'cache' ) {
            report( 'WARN',
                "a file the engine refuses is still being served to anonymous "
                    . "visitors: $l served, $g refused - but a file created "
                    . "AFTER the gate and never requested is refused, so this "
                    . "is a front-end cache still holding descriptors for files "
                    . "fetched while the folder was public, not a routing rule",
                'no action: the front end clears these itself. Re-run this '
                    . 'check after its cache window if you want to confirm. '
                    . 'See SM331.' );
        }
        else {
            my $shape
                = !@gated
                ? "$l served - the front end is answering without consulting the engine"
                : $late_verdict eq 'extension'
                ? "$l served, $g refused, AND a file written into the PROTECTED "
                . "store after the gate and never requested is also served - so "
                . "the front end is serving protected content by FILE "
                . "EXTENSION, and this is not cache residue"
                : "$l served, $g refused - which is either a front end serving "
                . "by file extension or a cache still holding files fetched "
                . "while the folder was public. This probe could not write a "
                . "test file to tell them apart";
            report( 'FAIL',
                "a file the engine refuses is served to anonymous visitors: $shape",
                'the request is not reaching lazysite. On Hestia apply the '
                    . 'lazysite-proxy template (or turn that domain\'s proxy off); '
                    . 'elsewhere check that the front end routes to the engine when '
                    . 'lazysite/auth/acls.json exists. See SM283.' );
        }
    }
    elsif ( @gated == @exts ) {
        report( 'OK',
            'protected content is not reachable anonymously: every probed '
                . 'file type ('
                . join( ', ', map { ".$_" } @exts )
                . ') was served when public and refused after protection'
                . ' - note this is a statement about the CONTENT, not about the'
                . ' front end. Protection MOVES the bytes out of the document'
                . ' root, so a front end that never consults the engine passes'
                . ' this by having nothing left to serve' );
    }
    elsif (@gated) {
        report( 'WARN',
            'the ACL probe could not vouch for some file types: '
                . join( ', ', @blind )
                . ' (confirmed gated: ' . join( ', ', map { ".$_" } @gated ) . ')',
            'no bytes leaked, so this is not an exposure - but the public '
                . 'control was not served for those types either, so a refusal '
                . 'there proves nothing' );
    }
    else {
        report( 'WARN',
            'the ACL probe got no usable answer - nothing was served, gated or '
                . 'public (' . join( ', ', @blind ) . ')',
            'no bytes leaked, and nothing is confirmed. Check the URL is this '
                . 'site and reachable from here; curl must be installed' );
    }
    return;
}

__END__

=head1 NAME

lazysite-check - lazysite install health and permissions doctor

=head1 SYNOPSIS

  perl tools/lazysite-check.pl --docroot PATH [--fix] [options]
  perl tools/lazysite-check.pl --dependencies

=head1 DESCRIPTION

Verifies that a lazysite docroot is set up so the (no-suexec, C<www-data>) CGI
can read its configuration and write the things it must write - cache, logs,
locks, secrets - that secrets are not world-exposed, that the CGI can traverse
into the directories it must cross and use the manager layout, and that the
manager is bootstrapped. Each check reports C<OK>, C<WARN> or C<FAIL> with a
remediation hint; the command exits non-zero if any check C<FAIL>s.

Effective-access checks are evaluated as the CGI identity via ownership and
mode arithmetic, never via C<-r>/C<-w>/C<-x> - run as root those answer for
root, which bypasses file permissions and would pass files the CGI cannot use.

With C<--fix> it applies the safe fixes (C<chmod> always; C<chown> only when
run as root) and then re-runs every check, so the printed report reflects the
post-fix state.

The C<--dependencies> mode is a standalone host query - it needs no docroot and
reports the non-core Perl modules lazysite needs (from
F<dist/config/sbom-deps.json>), which are present, and the install line for any
that are missing.

=head1 OPTIONS

=over 4

=item B<--docroot> PATH

The site's F<public_html> (required for the health checks).

=item B<--cgibin> PATH

The C<cgi-bin> directory. Default: F<< <docroot>/../cgi-bin >>.

=item B<--owner> USER

Expected owner. Default: the owner of the docroot.

=item B<--group> GROUP

Expected group. Default: C<www-data> (the CGI's group), else the docroot's group.

=item B<--fix>

Apply the safe fixes (C<chmod> always; C<chown> only when run as root). When
anything was fixed, the checks run again and the report shows the post-fix
state (the C<fixed:> action lines come first).

=item B<--check-dav> URL

Probe C<< URL/dav/ >> unauthenticated; expect 401 (route wired), not 404 (the web
server or proxy is not forwarding F</dav/>).

=item B<--check-acl> URL

Ask whether the B<front end> respects the ACL - the one question this tool
cannot answer from the inside, and the one three incidents turned on
(SM248, SM268 H17, SM283).

It creates a probe folder in the docroot, gates it against a principal that
cannot exist, and fetches it anonymously from C<URL> under several file
extensions. If any bytes come back, the front end is answering without
consulting the engine, and the check B<FAILs>.

B<Several extensions on purpose.> SM283 leaked C<.png>, C<.pdf>, C<.txt> and
C<.bin> and gated C<.dat>, because C<.dat> was the one extension absent from the
front end's static list. A probe testing one extension would have picked C<.dat>
and reported the site healthy. When the answers split by extension, this check
says so - that split is the signature of a front end serving a static list
straight off the docroot.

Each gated file has a B<public control> of the same type outside the gated
folder. If the control is not served either, the refusal proves nothing - a site
that is simply unreachable would otherwise read as correctly gated - and the
check reports that it could not tell rather than passing.

The probe writes a temporary entry to the ACL store and removes both it and its
files afterwards, including after an interrupt, and it clears anything an
earlier interrupted run left behind. It re-reads the store before removing its
entry, so a rule added while it was running is not reverted. No filesystem path
appears in its output; the operator is told which B<extensions> leaked, because
that is what identifies the layer at fault.

Needs C<curl>, and needs the site to be reachable from where the check runs.

=item B<--dependencies>

Report the OS Perl packages lazysite needs (present vs missing) and the install
line for whatever is absent. No docroot required; informational (exits 0).

=item B<--help>

Print the usage summary.

=back

=head1 EXIT STATUS

Non-zero if any health check C<FAIL>s (after C<--fix>, the post-fix state).
The C<--dependencies> query is informational and exits 0.

=head1 SEE ALSO

L<lazysite-users.pl(1)>, L<install.pl(1)>. See also F<docs/OPERATOR.md> and
F<docs/reference/host-dependencies.md>.

=cut
