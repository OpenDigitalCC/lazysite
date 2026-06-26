#!/usr/bin/perl
# lazysite-check - install health / permissions doctor.
#
# Verifies that a lazysite docroot is set up so the (no-suexec, www-data) CGI
# can read its config and write the things it must write (cache, logs, locks,
# secrets), that secrets are not world-exposed, and that the manager is
# bootstrapped. Reports OK / WARN / FAIL per check with a remediation hint;
# exits non-zero if anything FAILs. With --fix it applies the safe fixes
# (chmod always; chown only when run as root).
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
            group => undef, fix => 0 );
while ( @ARGV ) {
    my $a = shift @ARGV;
    if    ( $a eq '--docroot' ) { $opt{docroot} = shift @ARGV }
    elsif ( $a eq '--cgibin' )  { $opt{cgibin}  = shift @ARGV }
    elsif ( $a eq '--owner' )   { $opt{owner}   = shift @ARGV }
    elsif ( $a eq '--group' )   { $opt{group}   = shift @ARGV }
    elsif ( $a eq '--fix' )     { $opt{fix}     = 1 }
    elsif ( $a eq '--help' )    { usage(); exit 0 }
    else { print STDERR "lazysite-check: unknown option: $a\n"; exit 2 }
}

sub usage {
    print <<'USAGE';
lazysite-check - install health / permissions doctor

Usage: perl tools/lazysite-check.pl --docroot PATH [options]

  --docroot PATH   the site's public_html (required)
  --cgibin PATH    the cgi-bin dir (default: <docroot>/../cgi-bin)
  --owner USER     expected owner (default: the owner of the docroot)
  --group GROUP    expected group (default: the group of the docroot)
  --fix            apply the safe fixes (chmod always; chown only as root)
  --help           this help

Exit status is non-zero if any check FAILs.
USAGE
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

# --- result collection -------------------------------------------------------
my ( @results, @chmod_fixes, $chown_needed );
sub report {    # (level, message, [hint])
    my ( $level, $msg, $hint ) = @_;
    push @results, { level => $level, msg => $msg, hint => $hint };
}
sub owner_name { ( getpwuid( ( stat $_[0] )[4] ) )[0] // ( stat $_[0] )[4] }
sub group_name { ( getgrgid( ( stat $_[0] )[5] ) )[0] // ( stat $_[0] )[5] }
sub mode_of    { ( stat $_[0] )[2] & 07777 }

# --- 1. ownership: nothing under lazysite/ should be foreign-owned -----------
{
    my ( @bad, $total );
    File::Find::find(
        { no_chdir => 1, wanted => sub {
            my @s = lstat $File::Find::name or return;
            return if -l _;
            if ( $s[4] != $exp_uid ) {
                $total++;
                push @bad, $File::Find::name if @bad < 8;
            }
        } }, $LZ );
    if ($total) {
        my $sample = join( ', ', map { s{^\Q$DOC/\E}{}r } @bad );
        $sample .= ", …" if $total > @bad;
        report( 'FAIL',
            "$total path(s) under lazysite/ not owned by $exp_user "
          . "(owner mismatch breaks the www-data CGI): $sample",
            "chown -R $exp_user:$exp_grp '$LZ'" );
        $chown_needed = 1;
    }
    else {
        report( 'OK', "lazysite/ tree owned by $exp_user" );
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
);
for my $rel ( sort keys %want_dir ) {
    my $path = "$DOC/$rel";
    next unless -e $path;       # not every dir exists on every install
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
                ( $sgid ? '' : '; no setgid (new files miss the group)' ) ),
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

# --- 4. secrets must not be world-accessible ---------------------------------
for my $rel (qw(
    lazysite/auth/.secret lazysite/forms/.secret lazysite/manager/.csrf-secret
    lazysite/auth/oauth.json lazysite/auth/user-settings.json
)) {
    my $path = "$DOC/$rel";
    next unless -f $path;
    my $mode = mode_of($path);
    if ( $mode & 0007 ) {
        report( 'FAIL',
            sprintf( "%s is world-accessible (%04o) - a secret must not be", $rel, $mode ),
            sprintf( "chmod 0660 '%s'", $path ) );
        push @chmod_fixes, [ 0660, $path ];
    }
    else {
        report( 'OK', "$rel not world-accessible" );
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

# --- 6. config present + readable; cgi-bin scripts present + executable -------
my $conf = "$LZ/lazysite.conf";
if   ( -r $conf ) { report( 'OK', "lazysite.conf present and readable" ) }
else              { report( 'FAIL', "lazysite.conf missing or unreadable at $conf" ) }

if ( -d $CGI ) {
    for my $s (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
        my $p = "$CGI/$s";
        if    ( !-f $p ) { report( 'FAIL', "cgi-bin/$s missing", "re-run the deploy" ) }
        elsif ( !-x $p ) { report( 'FAIL', "cgi-bin/$s not executable",
                                    sprintf( "chmod 0755 '%s'", $p ) ) }
        else             { report( 'OK', "cgi-bin/$s present and executable" ) }
    }
}
else {
    report( 'WARN', "cgi-bin not found at $CGI (pass --cgibin to check it)" );
}

# --- 7. manager bootstrap (ties to setup-manager) ----------------------------
{
    my $mg = conf_value( $conf, 'manager_groups' );
    my $mgr_enabled = ( conf_value( $conf, 'manager' ) // '' ) =~ /enabled/i;
    if ( !defined $mg || $mg eq '' ) {
        report( 'WARN',
            "manager_groups not set - the manager is unconfigured "
          . "(or every authenticated user would be a manager)",
            "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" );
    }
    elsif ( !$mgr_enabled ) {
        report( 'WARN', "manager_groups set but 'manager: enabled' is not",
            "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" );
    }
    else {
        # is there a manager user with a password, in a manager group?
        my @groups = split /[,\s]+/, $mg;
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
                $have_pw = 1 if length( $2 // '' );
            }
            close $uf;
        }
        if    ( !$have_mgr ) { report( 'WARN', "no user in a manager group (@groups)",
                                       "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" ) }
        elsif ( !$have_pw )  { report( 'WARN', "manager user has no password (localhost-only)",
                                       "perl tools/lazysite-users.pl --docroot '$DOC' setup-manager" ) }
        else                 { report( 'OK', "manager bootstrapped (group + user + password)" ) }
    }
}

# --- apply fixes -------------------------------------------------------------
if ( $opt{fix} ) {
    for my $f (@chmod_fixes) {
        my ( $mode, $path ) = @$f;
        if ( chmod $mode, $path ) { printf "fixed: chmod %04o %s\n", $mode, $path }
        else                      { warn "could not chmod $path: $!\n" }
    }
    if ($chown_needed) {
        if ( $> == 0 ) {
            # recursive chown to the expected owner:group
            File::Find::find( { no_chdir => 1, wanted => sub {
                chown $exp_uid, $exp_gid, $File::Find::name;
            } }, $LZ );
            print "fixed: chown -R $exp_user:$exp_grp $LZ\n";
        }
        else {
            print "skip: ownership fix needs root - run:\n"
                . "  chown -R $exp_user:$exp_grp '$LZ'\n";
        }
    }
}

# --- report ------------------------------------------------------------------
my %icon = ( OK => '  ok  ', WARN => ' warn ', FAIL => ' FAIL ' );
my ( $fails, $warns ) = ( 0, 0 );
print "\nlazysite-check  docroot=$DOC  expect-owner=$exp_user:$exp_grp\n\n";
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
