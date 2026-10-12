#!/usr/bin/perl
# tools/integration.pl - the overnight run tests what is about to land (SM1062).
#
#   perl tools/integration.pl --queue FILE --results FILE --requeue FILE
#
# Run by tools/overnight.sh with tonight's queue (lines `WORKTREE TIP [FLAG]`).
# The release manager ruled on 2026-10-12: "maybe the suite runs on its own
# branch, not main, then the review process checks that in to main". So, in
# order:
#
#   1. RELEASE. Every queued worktree, and any worktree holding a branch of a
#      queued stack, is detached at main (the main checkout returns to main), so
#      vcs-review can offer the branches. One with uncommitted changes is left
#      as it is and its stack is NOT READY.
#   2. PRECHECK each stack as tools/handoff.sh does: every branch, lowest first,
#      against the branch below it (main for the lowest) - the mangled-literal
#      check, then tools/precheck.sh. A failure leaves the stack out, NOT READY.
#   3. BUILD the integration tree in tmp/wt-integration, a detached worktree,
#      fresh from main: each stack's commits that `git cherry` says are not yet
#      applied are cherry-picked in queue order, onto main and the stacks before
#      it. vcs-review lands by cherry-pick too, so landing the stacks in this
#      order makes main this tree. A stack that does not apply is reported
#      "CONFLICT with <earlier stack>: files" (or with main) and left out; the
#      rest continue. The tip is kept as review/assess/integration, a name
#      vcs-review never offers (it skips review/assess/).
#   4. ONE WHOLE SUITE on that tip: tools/suite.sh --tree, through the host-wide
#      suite lock, at nice 19 and idle I/O, inside the $LAZYSITE_NIGHTLY_LIMIT
#      (default 5h) the whole run keeps to. A held lock is a skip: the stacks go
#      back on the queue for the next night.
#   5. THE VERDICT, in the results file. GREEN: "LAND IN THIS ORDER:" and a
#      READY FOR REVIEW line per branch, as handoff.sh prints it. RED: each
#      failing test file is run again alone on main, on each stack applied
#      alone on main, and (when no single stack fails it) on each pair, and is
#      put down to "main itself", "stack X" or "stacks X+Y together (clash)".
#      Only the stacks it names are NOT READY. A red night, or any CONFLICT,
#      also files DATE-overnight-integration-red|green.md in the inbox
#      ($LAZYSITE_NIGHTLY_INBOX overrides); a green night files nothing there.
#
# Exit 0 GREEN; 1 RED; 3 nothing to integrate (the caller runs the plain
# nightly on main); 4 no verdict (the suite lock was held); 2 a bad argument.
use strict;
use warnings;
use Cwd          qw(abs_path);
use File::Path   qw(make_path);
use Getopt::Long ();
use POSIX        qw(strftime);

my ( $QUEUE, $RESULTS, $REQUEUE );
Getopt::Long::GetOptions(
    'queue=s'   => \$QUEUE,
    'results=s' => \$RESULTS,
    'requeue=s' => \$REQUEUE,
) or exit 2;
if ( !$QUEUE || !$RESULTS || !$REQUEUE ) {
    print STDERR "integration: --queue, --results and --requeue are all needed\n";
    exit 2;
}

my $BASE  = 'main';
my $INTEG = 'review/assess/integration';
my $ROOT  = abs_path( $0 =~ m{^(.*)/tools/[^/]+$} ? $1 : '.' );
my $STATE = state_dir();
my $DAY   = strftime( '%Y-%m-%d', localtime );
my $D     = "$STATE/tmp/overnight";
my $WT    = "$STATE/tmp/wt-integration";
my $LOG   = "$D/integration-$DAY.log";
my $INBOX = $ENV{LAZYSITE_NIGHTLY_INBOX} // "$STATE/inbox";
my $LIMIT = $ENV{LAZYSITE_NIGHTLY_LIMIT} // '5h';
my $END   = time + seconds($LIMIT);
make_path($D);

my @OUT;    # the verdict lines, in the order they are decided
my $CONFLICT = 0;

sub say_line { push @OUT, @_ }

sub seconds {
    my ($l) = @_;
    my %unit = ( '' => 1, s => 1, m => 60, h => 3600, d => 86400 );
    return $l =~ /\A(\d+)([smhd]?)\z/ ? $1 * $unit{$2} : 5 * 3600;
}

# --- running things ------------------------------------------------------------
# Every command's output goes to the run's log; what is wanted back is captured.
sub run_in {
    my ( $dir, $env, @cmd ) = @_;
    my $pid = fork;
    die "integration: cannot fork: $!\n" unless defined $pid;
    if ( !$pid ) {
        open STDIN,  '<',  '/dev/null'         or exit 127;
        open STDOUT, '>>', $LOG // '/dev/null' or exit 127;
        open STDERR, '>&', \*STDOUT            or exit 127;
        chdir $dir or exit 127 if defined $dir;
        @ENV{ keys %$env } = values %$env if $env;
        exec @cmd or exit 127;
    }
    waitpid $pid, 0;
    return $?;
}
sub run { return run_in( undef, undef, @_ ) }

sub capture {
    my (@cmd) = @_;
    my $pid   = open my $ph, '-|';
    die "integration: cannot fork: $!\n" unless defined $pid;
    if ( !$pid ) {
        open STDIN,  '<',  '/dev/null'         or exit 127;
        open STDERR, '>>', $LOG // '/dev/null' or exit 127;
        exec @cmd or exit 127;
    }
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    chomp $o;
    return $? == 0 ? $o : undef;
}

sub git    { my ( $dir, @a ) = @_; return capture( 'git', '-C', $dir, @a ) }
sub git_ok { my ( $dir, @a ) = @_; return run( 'git', '-C', $dir, @a ) == 0 }
sub lines  { my ($t) = @_; return grep { length } split /\n/, $t            // '' }
sub short  { my ($r) = @_; return git( $STATE, 'rev-parse', '--short', $r ) // '?' }
sub is_anc { my ( $a, $b ) = @_; return git_ok( $STATE, 'merge-base', '--is-ancestor', $a, $b ) }
sub dirty { my ($dir) = @_; my $s = git( $dir, 'status', '--porcelain' ); return !defined $s || $s ne '' }
sub same { my ( $a, $b ) = @_; return ( abs_path($a) // $a ) eq ( abs_path($b) // $b ) }
sub left { return $END - time }

sub state_dir {
    my $common = capture( 'git', '-C', $ROOT, 'rev-parse', '--path-format=absolute', '--git-common-dir' );
    if ( !defined $common ) {
        print STDERR "integration: $ROOT is not in a git repository\n";
        exit 2;
    }
    return $common =~ s{/[^/]+/?\z}{}r;
}

# --- the queue and its stacks --------------------------------------------------
# A stack is the local branches between main and TIP, lowest first, each sitting
# on the one below it - the stack tools/handoff.sh --stack main would check.
sub stack_of {
    my ($tip) = @_;
    my @in;
    for my $b ( lines( git( $STATE, 'for-each-ref', '--format=%(refname:short)', 'refs/heads' ) ) ) {
        next if $b eq $BASE || $b eq $INTEG;
        next unless is_anc( $b, $tip );
        next if is_anc( $b, $BASE );
        my $n = git( $STATE, 'rev-list', '--count', "$BASE..$b" ) // 0;
        push @in, [ $n, ( $b eq $tip ? 1 : 0 ), $b ];
    }
    my @br = map { $_->[2] } sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] || $a->[2] cmp $b->[2] } @in;
    return ( undef, "every commit of $tip is on $BASE" )        unless @br;
    return ( undef, "$tip is not the top of a stack on $BASE" ) unless $br[-1] eq $tip;
    # The lowest branch may sit on an older main - main moves in the day, and the
    # cherry-pick below is what finds out whether that matters.
    my ( $prev, @parents ) = ($BASE);
    for my $b (@br) {
        return ( undef, "$b does not sit on $prev - not a stack" ) unless $prev eq $BASE || is_anc( $prev, $b );
        push @parents, $prev;
        $prev = $b;
    }
    return ( \@br, \@parents );
}

sub not_ready {
    my ( $s, $why ) = @_;
    $s->{out} = 1;
    say_line( "NOT READY: $_ " . short($_) . " - $why" ) for @{ $s->{branches} || [ $s->{tip} ] };
    return;
}

sub read_queue {
    my ( @stacks, %seen );
    open my $q, '<', $QUEUE or return ();
    while ( my $line = <$q> ) {
        chomp $line;
        my ( $wt, $tip, $flag ) = split ' ', $line;
        next unless defined $tip;
        next if $seen{$tip}++;
        my $s = { line => $line, wt => $wt, tip => $tip, flag => $flag // '' };
        push @stacks, $s;
        if ( !defined git( $STATE, 'rev-parse', '--verify', '--quiet', "refs/heads/$tip" ) ) {
            $s->{out} = 1;
            say_line("NOT RUN: $tip - there is no such branch");
            next;
        }
        my ( $br, $why ) = stack_of($tip);
        if ( !$br ) {
            $s->{out} = 1;
            say_line("NOT RUN: $tip - $why");
            next;
        }
        $s->{branches} = $br;
        $s->{parents}  = $why;    # stack_of returns the parents when it found a stack
    }
    close $q;
    return @stacks;
}

# --- 1. release the worktrees --------------------------------------------------
sub worktrees {
    my ( @wt, $cur );
    for my $l ( lines( git( $STATE, 'worktree', 'list', '--porcelain' ) ) ) {
        if ( $l =~ /\Aworktree (.+)/ ) { push @wt, $cur = { path => $1, branch => '' } }
        elsif ( $l =~ m{\Abranch refs/heads/(.+)} && $cur ) { $cur->{branch} = $1 }
    }
    return @wt;
}

sub release {
    my ($s)  = @_;
    my %mine = map { $_ => 1 } @{ $s->{branches} };
    my @hold = grep { $mine{ $_->{branch} } || ( $s->{wt} && same( $_->{path}, $s->{wt} ) ) } worktrees();
    for my $h (@hold) {
        next if same( $h->{path}, $WT );
        my $what = $h->{branch} ? "$h->{branch} is" : 'it is';
        if ( dirty( $h->{path} ) ) {
            return not_ready( $s, "uncommitted changes in $h->{path}; $what left checked out there" );
        }
        my @to = same( $h->{path}, $STATE ) ? ($BASE) : ( '--detach', $BASE );
        if ( !git_ok( $h->{path}, 'checkout', '-q', @to ) ) {
            return not_ready( $s, "could not release $h->{path}; $what still checked out there" );
        }
    }
    return 1;
}

# --- the integration worktree --------------------------------------------------
sub reset_wt {
    my ($ref) = @_;
    run( 'git', '-C', $WT, 'cherry-pick', '--abort' )
        if -e "$WT/.git" && defined git( $WT, 'rev-parse', '-q', '--verify', 'CHERRY_PICK_HEAD' );
    git_ok( $WT, 'checkout', '-q', '-f', '--detach', $ref ) or die "integration: cannot move $WT to $ref\n";
    git_ok( $WT, 'clean', '-fdq' );
    make_path("$WT/tmp");
    return 1;
}

sub setup_wt {
    git_ok( $STATE, 'worktree', 'prune' );
    if ( !-e "$WT/.git" ) {
        git_ok( $STATE, 'worktree', 'add', '-q', '--detach', $WT, $BASE )
            or die "integration: cannot create $WT\n";
    }
    return reset_wt($BASE);
}

# Commits of TIP not yet applied on the worktree's HEAD, oldest first: what
# vcs-review would still land (it skips what `git cherry` marks as applied).
sub pending {
    my ($tip) = @_;
    return map { /\A\+ (\S+)/ ? $1 : () } lines( git( $WT, 'cherry', 'HEAD', $tip ) );
}

# Apply a stack's pending commits on the worktree's HEAD. Returns () on success,
# or the files a commit conflicted on (the commit's sha when it named none).
sub apply_stack {
    my ($s) = @_;
    my $before = git( $WT, 'rev-parse', 'HEAD' );
    for my $c ( pending( $s->{tip} ) ) {
        next if git_ok( $WT, 'cherry-pick', '--allow-empty', '--keep-redundant-commits', $c );
        my @u = lines( git( $WT, 'diff', '--name-only', '--diff-filter=U' ) );
        run( 'git', '-C', $WT, 'cherry-pick', '--abort' );
        git_ok( $WT, 'reset', '-q', '--hard', $before );
        return @u ? @u : ( '(commit ' . substr( $c, 0, 12 ) . ' did not apply; see the log)' );
    }
    return ();
}

# --- 2. precheck ---------------------------------------------------------------
my $MANGLED = join '', 'gh', '\.', '0721', '03'; # spelt apart, as handoff.sh avoids matching itself

sub precheck {
    my ($s) = @_;
    my $log = "$D/precheck-$DAY-$s->{tip}.log";
    my @br  = @{ $s->{branches} };
    for my $i ( 0 .. $#br ) {
        my ( $b, $p ) = ( $br[$i], $s->{parents}[$i] );
        reset_wt($b);
        my $diff = git( $WT, 'diff', "$p...HEAD" ) // '';
        my $why;
        if ( grep { /\A\+(?!\+\+)/ && /$MANGLED/ } split /\n/, $diff ) {
            $why = "the diff carries the mangled literal (gh, a dot, 072103)";
        }
        elsif ( !-f "$WT/tools/precheck.sh" ) {
            $why = 'it has no tools/precheck.sh';
        }
        else {
            my $rc = run_in( undef, undef, 'sh', '-c', 'exec bash "$1" "$2" >>"$3" 2>&1', 'precheck',
                "$WT/tools/precheck.sh", $p, $log );
            $why = "precheck failed against $p ($log)" if $rc != 0;
        }
        next unless $why;
        for my $j ( 0 .. $#br ) {
            my $x = $br[$j];
            say_line(
                "NOT READY: $x " . short($x) . ' - ' . ( $j == $i ? $why : "the stack stops at $b" ) );
        }
        $s->{out} = 1;
        return;
    }
    return 1;
}

# --- 3. build ------------------------------------------------------------------
sub build {
    my (@stacks) = @_;
    reset_wt($BASE);
    my @in;
    for my $s (@stacks) {
        if ( !pending( $s->{tip} ) ) {
            say_line("NOTHING TO APPLY: $s->{tip} - every commit is on $BASE or in an earlier stack tonight");
            $s->{out} = 1;
            next;
        }
        my $before = git( $WT, 'rev-parse', 'HEAD' );
        my @files  = apply_stack($s);
        if (@files) {
            my %f    = map { $_ => 1 } @files;
            my @with = map { $_->{tip} } grep {
                my $t = $_;
                grep { $t->{touched}{$_} } keys %f
            } @in;
            my $with = @with ? join( '+', @with ) : $BASE;
            say_line("CONFLICT with $with: $s->{tip} left out - @files");
            not_ready( $s, "CONFLICT with $with: @files" );
            $CONFLICT = 1;
            next;
        }
        my $after = git( $WT, 'rev-parse', 'HEAD' );
        $s->{touched} = { map { $_ => 1 } lines( git( $WT, 'diff', '--name-only', $before, $after ) ) };
        push @in, $s;
    }
    return @in;
}

# --- 5. attribution ------------------------------------------------------------
# Does FILE fail in the tree of main plus these stacks (applied in this order)?
# 1 yes, 0 no (or the file is not in that tree), undef when the tree cannot be
# made or the run's time is up.
sub fails_with {
    my ( $file, $tree, @stacks ) = @_;
    return undef if left() <= 60;
    reset_wt($tree);
    for my $s (@stacks) {
        return undef if apply_stack($s);
    }
    return 0 unless -f "$WT/$file";
    my $t = left() < 1200 ? left() : 1200;
    return run_in( $WT, undef, 'timeout', '--kill-after=60', "${t}s", 'prove', '-l', $file ) == 0 ? 0 : 1;
}

sub attribute {
    my ( $file, $tip, @in ) = @_;
    my $all = fails_with( $file, $tip );
    return ( "not attributed - the run reached its $LIMIT limit", @in ) unless defined $all;
    return ('not reproduced - it passed when run again on the integration tip') unless $all;
    my $main = fails_with( $file, $BASE );
    return ( "not attributed - the run reached its $LIMIT limit", @in ) unless defined $main;
    return ('main itself') if $main;
    my @alone = grep { fails_with( $file, $BASE, $_ ) } @in;
    return ( join( '; ', map { "stack $_->{tip}" } @alone ), @alone ) if @alone;
    my @pairs;
    for my $i ( 0 .. $#in - 1 ) {
        for my $j ( $i + 1 .. $#in ) {
            push @pairs, [ @in[ $i, $j ] ] if fails_with( $file, $BASE, @in[ $i, $j ] );
        }
    }
    my %hit;
    $hit{ $_->{tip} } = $_ for map { @$_ } @pairs;
    return ( join( '; ', map { "stacks $_->[0]{tip}+$_->[1]{tip} together (clash)" } @pairs ), values %hit )
        if @pairs;
    return ( 'stacks ' . join( '+', map { $_->{tip} } @in ) . ' together (clash)', @in );
}

sub failing_files {
    my %seen;
    open my $f, '<', "$WT/tmp/suite.log" or return ();
    my @files = grep { !$seen{$_}++ } map { m{\A(t/\S+\.t)\s+\(Wstat:} ? $1 : () } <$f>;
    close $f;
    return @files;
}

# --- the run -------------------------------------------------------------------
sub finish {
    my ( $rc, $colour ) = @_;
    open my $r, '>>', $RESULTS or die "integration: $RESULTS: $!\n";
    print {$r} map { "$_\n" } @OUT;
    close $r;
    if ( $colour && ( $colour eq 'red' || $CONFLICT ) ) {
        make_path($INBOX);
        my $file = "$INBOX/$DAY-overnight-integration-$colour.md";
        open my $m, '>', $file or die "integration: $file: $!\n";
        print {$m} "# Overnight integration $DAY: $colour"
            . ( $CONFLICT ? ', with a conflict' : '' ) . "\n\n"
            . "tools/overnight.sh built $INTEG from $BASE and tonight's queue, and ran the\n"
            . "whole suite on it. The verdict lines, as in $RESULTS:\n\n"
            . join( '', map { "    $_\n" } @OUT )
            . "\nThe run's log: $LOG\n";
        close $m;
    }
    exit $rc;
}

open my $lg, '>>', $LOG or die "integration: $LOG: $!\n";
print {$lg} strftime( '%F %T', localtime ) . " integration run, queue $QUEUE\n";
close $lg;

my @stacks = read_queue();
unshift @OUT,
    ( "== integration on $BASE " . short($BASE) . ': ' . join( ' ', map { $_->{tip} } @stacks ) );
my @live = grep { !$_->{out} } @stacks;
@live = grep { release($_) } @live;
# Every queued worktree is released, whatever became of its stack.
for my $s ( grep { $_->{out} && $_->{wt} && -d $_->{wt} } @stacks ) {
    next if same( $s->{wt}, $STATE ) || same( $s->{wt}, $WT ) || dirty( $s->{wt} );
    git_ok( $s->{wt}, 'checkout', '-q', '--detach', $BASE );
}
setup_wt();
@live = grep { precheck($_) } @live;
my @in = build(@live);

if ( !@in ) {
    reset_wt($BASE);
    say_line('NOTHING INTEGRATED: the plain nightly suite runs on main instead');
    finish( 3, 'green' );
}

my $tip = git( $WT, 'rev-parse', 'HEAD' );
git_ok( $STATE, 'branch', '-f', $INTEG, $tip );
my $TIP = short($tip);

my $rc = run_in(
    undef,
    { LAZYSITE_NIGHTLY_LIMIT => ( left() > 0 ? left() : 1 ) . 's' },
    'bash', "$ROOT/tools/suite.sh", '--tree', $WT
) >> 8;

if ( $rc == 75 ) {
    open my $q, '>>', $REQUEUE or die "integration: $REQUEUE: $!\n";
    print {$q} map { "$_->{line}\n" } @in;
    close $q;
    say_line( "NO VERDICT: another whole-suite run held the suite lock; "
            . join( ' ', map { $_->{tip} } @in )
            . ' went back on the queue for the next night' );
    finish( 4, undef );
}

if ( $rc == 0 ) {
    say_line("GREEN: the whole suite passed on $INTEG $TIP");
    say_line('LAND IN THIS ORDER:');
    my $n = 0;
    say_line( sprintf '  %d. %s %s (%s)', ++$n, $_->{tip}, short( $_->{tip} ), "@{ $_->{branches} }" )
        for @in;
    for my $s (@in) {
        say_line("READY FOR REVIEW: $_ @{[ short($_) ]} (precheck passed; suite passed on $INTEG $TIP)")
            for @{ $s->{branches} };
    }
    reset_wt($tip);
    finish( 0, 'green' );
}

# RED.
my %why;    # stack tip -> the reasons it is NOT READY
my @files = failing_files();
if ( $rc == 124 || $rc == 137 ) {
    say_line("RED: the whole suite stopped at the $LIMIT limit on $INTEG $TIP");
    push @{ $why{ $_->{tip} } }, "the suite stopped at the $LIMIT limit on the integration tip" for @in;
}
elsif ( !@files ) {
    say_line("RED: the whole suite failed (exit $rc) on $INTEG $TIP and named no file");
    push @{ $why{ $_->{tip} } }, "the integration suite failed and named no file" for @in;
}
else {
    say_line( "RED: the whole suite failed on $INTEG $TIP - " . scalar(@files) . ' file(s)' );
    for my $f (@files) {
        my ( $cause, @hit ) = attribute( $f, $tip, @in );
        say_line("FAIL $f: $cause");
        push @{ $why{ $_->{tip} } }, "$f fails ($cause)" for @hit;
    }
}
for my $s (@in) {
    if ( $why{ $s->{tip} } ) {
        not_ready( $s, join '; ', @{ $why{ $s->{tip} } } );
        next;
    }
    say_line("READY FOR REVIEW: $_ @{[ short($_) ]} (precheck passed; not implicated in the red integration run)")
        for @{ $s->{branches} };
}
reset_wt($tip);
finish( 1, 'red' );
