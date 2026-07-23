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
use Cwd qw(abs_path);
use File::Find ();

my %opt = ( docroot => undef, cgibin => undef, owner => undef,
            group => undef, fix => 0, check_dav => undef, dependencies => 0 );
while ( @ARGV ) {
    my $a = shift @ARGV;
    if    ( $a eq '--docroot' ) { $opt{docroot} = shift @ARGV }
    elsif ( $a eq '--cgibin' )  { $opt{cgibin}  = shift @ARGV }
    elsif ( $a eq '--owner' )   { $opt{owner}   = shift @ARGV }
    elsif ( $a eq '--group' )   { $opt{group}   = shift @ARGV }
    elsif ( $a eq '--fix' )     { $opt{fix}     = 1 }
    elsif ( $a eq '--check-dav' ) { $opt{check_dav} = shift @ARGV }
    elsif ( $a eq '--dependencies' ) { $opt{dependencies} = 1 }
    elsif ( $a eq '--handover-mode' ) { $opt{handover_mode} = shift @ARGV }
    elsif ( $a eq '--help' )    { usage(); exit 0 }
    else { print STDERR "lazysite-check: unknown option: $a\n"; exit 2 }
}

# SM126 D: host-dependency query. A standalone check of the OS-level Perl
# modules lazysite needs (from dist/config/sbom-deps.json) - no docroot needed,
# so it runs before the docroot validation below. An operator (or an onboarding
# agent) can ask "what must I install here" and get the missing-package line.
run_dependency_check() if $opt{dependencies};   # exits

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
                   then re-run the checks - the report shows the post-fix state
  --check-dav URL  probe URL/dav/ unauthenticated; expect 401 (route wired), not
                   404 (route missing - the web server / proxy does not forward /dav/)
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
    require JSON::PP;
    my $self = abs_path($0);
    ( my $tools = $self ) =~ s{/[^/]*$}{};
    ( my $root  = $tools ) =~ s{/[^/]*$}{};
    my $deps_path = "$root/dist/config/sbom-deps.json";
    unless ( -f $deps_path ) {
        print STDERR "lazysite-check: dependency metadata not found at $deps_path\n"
            . "  (run this from a lazysite source tree or release tarball)\n";
        exit 2;
    }
    open my $fh, '<', $deps_path
        or do { print STDERR "lazysite-check: cannot read $deps_path: $!\n"; exit 2 };
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
        my $ok = eval { require "$file.pm"; 1 };  ## no critic (Modules::RequireBarewordIncludes)
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
    print STDERR "lazysite-check: --docroot must be an existing directory\n";
    exit 2;
}
$DOC = abs_path($DOC);
my $LZ  = "$DOC/lazysite";
my $CGI = defined $opt{cgibin} ? abs_path( $opt{cgibin} ) : abs_path("$DOC/../cgi-bin");

unless ( -d $LZ ) {
    print STDERR "lazysite-check: no lazysite/ under $DOC - is this a lazysite docroot?\n";
    exit 2;
}

# --- expected owner / group (default: derived from the docroot itself) -------
my @ds = stat $DOC;
my $exp_uid = defined $opt{owner} ? ( ( getpwnam $opt{owner} )[2] // -1 ) : $ds[4];
# Expected GROUP defaults to the CGI's group (www-data), NOT the docroot's group:
# the no-suexec CGI runs as www-data and must keep group access to the tree.
# Falling back to the docroot group only if there is no www-data group.
my $exp_gid = defined $opt{group} ? ( ( getgrnam $opt{group} )[2] // -1 )
            : ( ( getgrnam 'www-data' )[2] // $ds[5] );
my $exp_user = ( getpwuid $exp_uid )[0] // $exp_uid;
my $exp_grp  = ( getgrgid $exp_gid )[0] // $exp_gid;
# The CGI (www-data) legitimately OWNS the files it creates at runtime - locks,
# cache entries, generated html, audit.log - so www-data ownership is valid, not a
# fault. Only a TRULY foreign owner (root, another user) breaks CGI access.
my $cgi_uid = ( getpwnam 'www-data' )[2];

# --- result collection -------------------------------------------------------
my ( @results, @chmod_fixes, $chown_needed, $tt_cache_bad );
my ( $git_fix_root, $git_shared_fix );
sub report {    # (level, message, [hint])
    my ( $level, $msg, $hint ) = @_;
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
        'lazysite/cache'         => 02775,
        'lazysite/logs'          => 02775,
        'lazysite/manager/locks' => 02775,
        'lazysite/layouts'       => 02775,
        'lazysite-assets'        => 02775,
        'lazysite/auth'          => 02770,
        'lazysite/forms'         => 02770,
        'lazysite/git'           => 02770,
    );
    for my $rel ( sort keys %want_dir ) {
        my $path = "$DOC/$rel";
        next unless -e $path;    # not every dir exists on every install
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

    # --- 3. group must be the CGI's group on the writable dirs -------------------
    for my $rel ( sort keys %want_dir ) {
        my $path = "$DOC/$rel";
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
        my $path = "$DOC/$rel";
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
        my $path = "$DOC/$rel";
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
        my $path = "$DOC/$rel";
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
        my $path = "$DOC/$rel";
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

    # --- 7. manager bootstrap (ties to setup-manager) ----------------------------
    my $mgr_enabled = ( conf_value( $conf, 'manager' ) // '' ) =~ /enabled/i;
    {
        # SM138: manager groups are those whose SETTINGS entry grants manager access
        # (ui / manage_users / the manager flag); the conf manager_groups key is
        # retired (a lingering line is inert and migrated away on first use).
        my @groups;
        if ( open my $gsf, '<', "$LZ/auth/groups-settings.json" ) {
            require JSON::PP;
            local $/;
            my $gs = eval { JSON::PP::decode_json(<$gsf>) } || {};
            close $gsf;
            @groups = sort grep {
                my $c = $gs->{$_};
                ref $c eq 'HASH' && ( $c->{ui} || $c->{manage_users} || $c->{manager} );
            } keys %{$gs};
        }
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

    # --- 9. content provenance (is this content lazysite's or the operator's?) ---
    # lazysite stamps its shipped seed pages with `provenance: lazysite-starter` in the
    # front matter. This reports which .md content is ours (unmodified vs customised)
    # versus operator-authored - the "is this likely ours?" test behind the upgrade-
    # safety work. Informational (always OK); never a FAIL.
    {
        require JSON::PP;
        require Digest::SHA;
        my %state;
        if ( open my $sf, '<', "$LZ/.install-state.json" ) {
            local $/;
            my $j = eval { JSON::PP::decode_json(<$sf>) };
            close $sf;
            %state = %{ $j->{files} }
                if ref $j eq 'HASH' && ref $j->{files} eq 'HASH';
        }
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
            if ( !length $site_url ) {
                report( 'FAIL',
                    'a remote service is enabled (' . join( ', ', @remote )
                        . ') but site_url is UNSET - the .well-known discovery docs will '
                        . 'advertise endpoints with no host, so an agent connect fails',
                    'set site_url: https://<this-host> in lazysite.conf' );
            }
            elsif ( $site_url !~ m{^https://} ) {
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
