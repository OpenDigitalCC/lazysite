#!/usr/bin/perl
# SM1457 (R1, R2, R3): the quiet rollout report lists what the DEPLOY did, and a
# line budget holds it to that.
#
# THE 0.17.1 ROLLOUT updated 32 sites with 0 failed and printed about a hundred
# lines of findings after its summary table: 45 distinct messages, nearly all of
# them each site's own standing `lazysite check` warnings. SM701 and SM889 had
# fixed the output twice and left nothing that measured it, so the next check
# that reported through the rollout grew it again. This is the measure.
#
# THE FIXTURE: a fleet of 32 sites, each carrying the standing warnings of the
# filing's list (pages with no description or title, shared titles, data tables
# naming no domain, `| html` on db: values, an account called "manager", the
# trusted_proxies reminder on 31 of them, a shadowed /docs manual, undeclared
# sites/ roots, no app icons) and TWO real faults: one site whose upgrade was
# refused permission under a private store (six messages, one cause) and one
# whose root did not answer. The rollout's own phases run - the deploy loop, the
# repair and the probe, the summary and the closing verdict - extracted from the
# script and driven with stand-ins for the deploy and the CLI that print the
# fixture's transcripts, so what is measured is what ships.
#
# IT FAILS when the report after the summary table is longer than the budget,
# when either fault is missing from it, or when the standing-warnings line is.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $UPD  = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $DEP  = "$root/installers/hestia/lazysite-hestia-deploy.sh";
my $CHK  = "$root/tools/lazysite-check.pl";
my $T    = Cwd::realpath( site_tempdir() );
my $me   = scalar getpwuid($>);

my $BUDGET = 15;

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return; local $/; my $s = <$fh>; close $fh; return $s }

my $u = slurp($UPD);

# --- the script's own pieces, extracted ---------------------------------------
my %part;
( $part{lazysite_dir} ) = $u =~ /^(lazysite_dir\(\) \{\n.*?^\}\n)/ms;
( $part{helpers} )      = $u =~ /(^TBL_FMT=.*?^run_quiet\(\) \{.*?^\}$)/ms;
( $part{probe_site} )   = $u =~ /^(probe_site\(\) \{\n.*?^\}\n)/ms;
( $part{check_verdict} ) = $u =~ /^(check_verdict\(\) \{\n.*?^\}\n)/ms;
( $part{deploy_loop} )  = $u =~ /^(ok=0; SKIPPED=\(\); FAILED=\(\); UNSERVICEABLE=\(\); RESULTS=\(\)\nfor i in .*?^done\n)/ms;
( $part{health} )       = $u =~ /^(if \[ -f "\$LZS" \]; then\n    # SM345.*?^fi\n)\n# SM1239/ms;
( $part{summary} )      = $u =~ /^(# --- SUMMARY:.*?\n    echo '  \(quiet report[^\n]*\n)/ms;
( $part{verdict} )      = $u =~ /^(if \[ "\$\{#FAILED\[\@\]\}" -gt 0 \] \|\| \[ "\$\{#PROXY_FAILED.*)\z/ms;
for my $k ( sort keys %part ) {
    ok( $part{$k}, "the rollout's $k was found in the script" ) or do { done_testing; exit };
}

# --- the two designated markers, pinned against the tools that print them -----
subtest 'the markers the report reads are the ones the tools print' => sub {
    like( slurp($DEP), qr/^echo "==> verifying install \(permissions \+ health, auto-repair\)"$/m,
        'the deploy introduces its final check with the heading collect_findings splits on' );
    like( $u, qr/grep -n -x -F -m1 -- '==> verifying install \(permissions \+ health, auto-repair\)'/,
        'and the rollout splits on that heading' );
    like( slurp($CHK), qr/'ROUTING CHECK SKIPPED: the site root did not answer'/,
        'the check says the site root did not answer in the words the rollout keeps as a finding' );
    like( $u, qr/\*'ROUTING CHECK SKIPPED:'\*/, 'which the rollout reads as a deploy finding' );
};

# --- the fixture ---------------------------------------------------------------
my $N     = 32;
my $priv  = "$T/home/$me/web/site05.example/public_html-lazysite-private/sites";
my $FAULT_DENIED = 'site05.example';
my $FAULT_ROOT   = 'site12.example';
my $NOANSWER     = 'ROUTING CHECK SKIPPED: the site root did not answer';
make_path($priv);

my @sites = map { sprintf 'site%02d.example', $_ } 1 .. $N;
my %doc;
for my $d (@sites) {
    $doc{$d} = "$T/home/$me/web/$d/public_html";
    make_path("$doc{$d}/lazysite");
}

# The standing warnings, in the check's words. Counts and lists differ by site so
# the fleet carries many distinct messages, as the real one did.
sub standing {
    my ($i) = @_;
    my $k = 1 + $i % 4;
    my @w = (
        "[ warn ] $k public page(s) have no description: " . join( ', ', map {"/page$_"} 1 .. $k ),
        "[ warn ] " . ( 1 + $i % 3 ) . " public page(s) have no title: /about, /contact",
        "[ warn ] pages share a title: \"Home\" is the title of /index and /home" . ( $i % 2 ? ', /start' : '' ),
        "[ warn ] the data table 'members' names no domain, so a copy of this site shares its rows",
        "[ warn ] " . ( 1 + $i % 2 ) . ' page(s) bind a data table with db: and also use | html: /members - db: values are escaped for you from 0.13.0',
        '[ warn ] this site has an account called "manager" - the shared role account is not a person',
        '[ warn ] docs/getting-started.md shadows the engine\'s own manual page',
        "[ warn ] sites/$i is not declared in lazysite.conf, so its pages are not served as a site",
        '[ warn ] the app names no icons (app_icon_192, app_icon_512), so the manifest has none and a browser may not offer to install it',
        ( $i == $N - 1 ? () : '[ warn ] trusted_proxies is only safe when the front end appends the client\'s address to X-Forwarded-For; probe it' ),
    );
    return @w;
}

# The six messages of one cause (the filing's first real fault): the installer's
# walk, a move beneath the same directory, and four of the check's walks.
my @denied_steps = (
    "ADDRESS PROFILES: could not read 1 directory as $me: $priv (Permission denied) - so it could not check that directory for visitor.in_list or visitor.in_any calls, which is owned by 'root'; run the upgrade again as root or as that owner (SM1345, SM1380)",
    "EXTENSIONS: could not move $priv/ext to $priv/ext.d (Permission denied) - nothing reads it there",
);
my @denied_checks = map {
    "[ warn ] $_ could not read 1 directory as $me: $priv (Permission denied) - nothing below it was looked at, so this result covers the rest of the site only"
} ( 'the page title check', 'the db: template check', 'the engine-docs shadow check', 'the data table check' );

# What each phase prints for one site: deploy (install steps, then the final
# check under its heading), repair (before and after), probe, check.
my %extra;    # site => [ extra standing warnings ], set by a scenario
sub warns_for {
    my ($d) = @_;
    my ($i) = grep { $sites[$_] eq $d } 0 .. $#sites;
    my @w = standing($i);
    push @w, @denied_checks if $d eq $FAULT_DENIED;
    push @w, "[ warn ] $NOANSWER" if $d eq $FAULT_ROOT;
    push @w, @{ $extra{$d} || [] };
    return @w;
}

sub write_fixture {
    my ($fix) = @_;
    for my $sub (qw(deploy repair probe check)) { make_path("$fix/$sub") }
    for my $d (@sites) {
        my @w = warns_for($d);
        my ($i) = grep { $sites[$_] eq $d } 0 .. $#sites;
        my @steps = ( '==> installing lazysite 0.17.2', '  Preserved:  2 (operator-edited)', '     deliberate, not a missing step, and there is no default login:' );
        push @steps, @denied_steps if $d eq $FAULT_DENIED;
        spit( "$fix/deploy/$d.txt", join( '', map {"$_\n"} @steps, '==> verifying install (permissions + health, auto-repair)', map {"  $_"} @w ) . "  $d: ok\n" );
        spit( "$fix/repair/$d.txt", join( '', "== $d\n", map {"  $_\n"} @w ) . "  -> nothing to repair. Left for you to decide, not a fault:\n" . join( '', map {"     $_\n"} @w ) . "\n0 clean, 0 repaired, 1 awaiting your decision, 0 need a human.\n" );
        # Eleven sites answer with the check's cache verdict, nineteen with the pass.
        spit( "$fix/probe/$d.txt", $i < 11 ? "  $d: cache residue, clears itself (nothing reaches past the gate)\n\n1 verified, 0 exposed, 0 not confirmed.\n" : "  $d: front end honours the rule\n\n1 verified, 0 exposed, 0 not confirmed.\n" );
        spit( "$fix/check/$d.txt", scalar(@w) . " warnings\n" . ( 40 - @w ) . ' ok, ' . scalar(@w) . " warning(s), 0 failure(s)\n" );
    }
    spit( "$fix/lzs.pl", "my (\$verb,\$x,\$d) = \@ARGV; open my \$f, '<', \"$fix/\$verb/\$d.txt\" or exit 9; print <\$f>; exit 0;\n" );
    spit( "$fix/deploy.sh", "cat \"$fix/deploy/\$2.txt\"\n" );
    return;
}

sub harness {
    my ( $fix, $verbose ) = @_;
    my $fleet = join "\n", map {
        my $d = $_;
        "USERS+=( '$me' ); DOMAINS+=( '$d' ); DOCS+=( '$doc{$d}' ); VERS+=( '0.17.1' )"
    } @sites;
    return join "\n", 'set -u', "VERBOSE=$verbose", "export LAZYSITE_FINDINGS_DIR='$fix/out'",
        "LZS='$fix/lzs.pl'", "DEPLOY='$fix/deploy.sh'", "STAGE=/stage", "NEWVER=0.17.2", "STAGED_REV=''",
        "USERS=(); DOMAINS=(); DOCS=(); VERS=(); OUT_OF_SCOPE=(); EXC_D=(); EXC_V=(); FORCED=(); PROXY_FAILED=(); DRY_FOUND=(); DRY_FAILED=(); TPL_FAILURES=0",
        $fleet,
        $part{lazysite_dir}, $part{helpers}, $part{probe_site}, $part{check_verdict},
        'vhost_state() { echo current; }', 'xff_exposure() { :; }',
        'set -e', $part{deploy_loop}, $part{health}, $part{summary}, $part{verdict};
}

# Run the rollout once over the fixture; the fleet's state under $T persists.
sub rollout {
    my ( $verbose, $fix ) = @_;
    $fix //= "$T/fix";
    make_path("$fix/out");
    write_fixture($fix);
    spit( "$fix/run.sh", harness( $fix, $verbose ) );
    my $out = qx(bash '$fix/run.sh' 2>&1);
    return ( $out, $? >> 8 );
}

# The lines after the summary table: after the last row, whatever they are.
sub after_table {
    my ($out) = @_;
    my @l = split /\n/, $out, -1;
    pop @l if @l && $l[-1] eq '';
    my ($last) = grep { $l[$_] =~ /^  site\d\d\.example\s+0\.17\.1\s+0\.17\.2\s/ } reverse 0 .. $#l;
    return () unless defined $last;
    return @l[ $last + 1 .. $#l ];
}

# The standing pairs the fixture carries: each distinct check message, per site,
# apart from the two designated deploy findings.
sub expected_standing {
    my $n = 0;
    for my $d (@sites) {
        my %seen;
        $n++ for grep { !$seen{$_}++ && !/\Q$NOANSWER\E/ } warns_for($d);
    }
    return $n;
}

# --- 1. the first rollout: no record anywhere, so every warning is standing ----
subtest 'the 32-site fleet with two real faults: within the budget, both faults present, one standing line' => sub {
    my ( $out, $rc ) = rollout(0);
    is( $rc, 0, 'the rollout exits 0 (nothing in the fixture marks the fleet for a human)' ) or diag $out;
    my @after = after_table($out);
    ok( @after, 'the report after the summary table was found' ) or diag $out;
    cmp_ok( scalar @after, '<=', $BUDGET, "the report after the summary table is within $BUDGET lines" )
        or diag( "got " . scalar(@after) . " lines:\n" . join( "\n", @after ) );
    my $rep = join "\n", @after;

    like( $rep, qr/\Q$priv\E is owned by \Q$me\E and the upgrade could not read or move under it \(Permission denied\) - run the upgrade again as root or as \Q$me\E/,
        'fault 1: the refused permission, as one line naming the directory, its owner and the fix' )
        or diag $rep;
    my @perm = grep { /Permission denied/ } @after;
    is( scalar @perm, 1, 'six messages, one cause: ONE line' ) or diag $rep;
    like( $rep, qr/sites: \Q$FAULT_DENIED\E/, 'and it names the site' );

    like( $rep, qr/\Q$NOANSWER\E/, 'fault 2: the site root that did not answer' ) or diag $rep;
    like( $rep, qr/sites: \Q$FAULT_ROOT\E/, 'and it names the site' );

    my $want = expected_standing();
    like( $rep, qr/^  \Q$want\E standing check warnings on \Q$N\E sites - unchanged since the last rollout; full list: (\S+)/m,
        "the standing warnings are one line, with their count ($want) and the file" )
        or diag $rep;
    like( $rep, qr/\(\Q$N\E sites with no earlier rollout record: counted as standing\)/,
        'and it says no site had an earlier record, so none could have changed' );
    unlike( $rep, qr/have no description|have no title|account called|trusted_proxies|app names no icons|share a title/,
        'no standing warning is listed' ) or diag $rep;

    my ($file) = $rep =~ /full list: (\S+)/;
    my $full = defined $file ? slurp($file) : undef;
    ok( defined $full, 'the full-list file exists' ) or return;
    like( $full, qr/^site01\.example\tstanding\t\[ warn \] 1 public page\(s\) have no description/m, 'it holds the standing warnings' );
    like( $full, qr/^\Q$FAULT_DENIED\E\tdeploy\tADDRESS PROFILES: could not read 1 director/m, 'and the original lines of the fault, not only the one that stands for them' );
    like( $full, qr/\Q$FAULT_ROOT\E\tdeploy\t\[ warn \] \Q$NOANSWER\E/, 'and the other' );

    diag( "the report after the table is " . scalar(@after) . " lines:\n" . join( "\n", map {"  | $_"} @after ) ) if $ENV{N842_SHOW};
};

# --- 2. the record: the next rollout reports only what CHANGED ----------------
subtest 'the next rollout reports a check finding that changed, and only that' => sub {
    my $rec = "$doc{'site01.example'}/lazysite/.rollout-check-findings";
    ok( -f $rec, 'each site now holds its record in its own engine tree, beside the install state' ) or return;
    like( slurp($rec), qr/\A# lazysite rollout record: .*\n.*have no description/s, 'a header, then the check findings seen' );
    is( ( stat $rec )[4], $>, 'written as the site\'s own user' );

    # The same fleet again: nothing changed.
    my ( $out, $rc ) = rollout(0);
    my @after = after_table($out);
    like( join( "\n", @after ), qr/standing check warnings on \Q$N\E sites - unchanged since the last rollout/, 'the standing line stands' );
    unlike( join( "\n", @after ), qr/no earlier rollout record/, 'with every site now having a record' );

    # One new warning on one site, and a fifth walk naming the same directory.
    $extra{'site07.example'}     = ['[ warn ] 2 public page(s) link to /gone, which does not exist'];
    $extra{$FAULT_DENIED}        = ['[ warn ] the link check could not read 1 directory as ' . $me . ': ' . $priv . ' (Permission denied) - nothing below it was looked at, so this result covers the rest of the site only'];
    ( $out, $rc ) = rollout(0);
    @after = after_table($out);
    my $rep = join "\n", @after;
    cmp_ok( scalar @after, '<=', $BUDGET, 'still within the budget' ) or diag $rep;
    like( $rep, qr/\[1\] \[ warn \] 2 public page\(s\) link to \/gone, which does not exist\s+sites: site07\.example/,
        'the changed warning is a finding, on its site' ) or diag $rep;
    my @perm = grep { /Permission denied/ } @after;
    is( scalar @perm, 1, 'a fifth walk naming the directory is still the one cause' ) or diag $rep;
    my ($count) = $rep =~ /(\d+) standing check warnings/;
    is( $count, expected_standing() - 2, 'and what changed is not also counted as standing' );

    # A record without its header is a damaged store: said, with its remedy.
    my $bad = "$doc{'site09.example'}/lazysite/.rollout-check-findings";
    spit( $bad, "this is not the record\n" );
    ( $out, $rc ) = rollout(0);
    $rep = join "\n", after_table($out);
    like( $rep, qr/record of this site's check findings is damaged \(\Q$bad\E does not start with its header line\).*remove the file/,
        'a damaged record is named, with its remedy' ) or diag $rep;
    like( slurp($bad), qr/\A# lazysite rollout record/, 'and the next record replaces it' );
    %extra = ();
};

# --- 3. verbose: today's output ------------------------------------------------
subtest '--verbose keeps every finding, as it always did' => sub {
    my $fix = "$T/fixv";
    my ( $out, $rc ) = rollout( 1, $fix );
    like( $out, qr/==> verifying install \(permissions \+ health, auto-repair\)/, 'the transcript is printed' );
    like( $out, qr/have no description/, 'the check\'s own lines are in it' );
    unlike( $out, qr/standing check warnings on/, 'and there is no standing-warnings line: nothing is summarised' );
    unlike( $out, qr/==> findings/, 'and no findings block is made of what the transcript already printed' );
};

done_testing();
