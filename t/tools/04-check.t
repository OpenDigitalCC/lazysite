#!/usr/bin/perl
# lazysite-check (the install/permissions doctor): detects bad perms + secrets,
# and --fix repairs the chmod issues.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
ok( -f $script, 'tools/lazysite-check.pl present' );

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
my $cgi  = "$base/cgi-bin";
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", "$doc/lazysite/manager", $cgi );

# SM201: a real install ships the protected system-page defaults; the check verifies
# they exist so the auth/error routes cannot be 404'd by a deleted root copy.
make_path("$doc/lazysite/templates/system");
for my $sp (qw(login claim 402 403 404)) {
    open my $sf, '>', "$doc/lazysite/templates/system/$sp.md" or die $!;
    print {$sf} "---\ntitle: $sp\n---\n\n$sp\n";
    close $sf;
}

# the manager layout (checked when the manager is enabled)
open my $lt, '>', "$doc/lazysite/manager/layout.tt" or die $!;
print {$lt} "<html>[% content %]</html>\n"; close $lt;
chmod 0644, "$doc/lazysite/manager/layout.tt";

# a healthy-ish conf + a bootstrapped manager
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmanager: enabled\n";
open my $gsf, '>', "$doc/lazysite/auth/groups-settings.json" or die $!;
print {$gsf} '{"lazysite-admins":{"label":"Admins","manager":1,"ui":1}}';
close $gsf;
close $cf;
open my $gf, '>', "$doc/lazysite/auth/groups" or die $!;
print {$gf} "lazysite-admins: manager\n"; close $gf;
open my $uf, '>', "$doc/lazysite/auth/users" or die $!;
print {$uf} "manager:sha256iter:aa:1:bb\n"; close $uf;

# deliberate problems
open my $sf, '>', "$doc/lazysite/auth/.secret" or die $!;
print {$sf} "secret"; close $sf;
chmod 0644,  "$doc/lazysite/auth/.secret";    # world-readable -> FAIL
chmod 0755,  "$doc/lazysite/cache";           # not group-writable / no setgid -> FAIL
chmod 02770, "$doc/lazysite/auth";
for my $s (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
    open my $x, '>', "$cgi/$s" or die $!; print {$x} "#!/usr/bin/perl\n"; close $x;
    chmod 0755, "$cgi/$s";
}

# The test's files are owned by the test user's group (not www-data), so pass
# --group explicitly; otherwise the group check would (correctly) flag them.
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];
sub run_as_group { my $g = shift; qx($^X $script --docroot $doc --cgibin $cgi --group $g @_ 2>&1) }
sub run          { run_as_group( $gname, @_ ) }

# --- detection ---
{
    my $out = run();
    like( $out, qr/world-accessible/,             'flags the world-readable secret' );
    like( $out, qr{lazysite/cache.*cannot write}, 'flags the non-writable cache dir' );
    like( $out, qr/manager bootstrapped/,         'recognises a bootstrapped manager' );
    like( $out, qr/failure\(s\)/,                 'prints a summary' );
    isnt( $? >> 8, 0, 'non-zero exit when a check FAILs' );
}

# --- fix ---
{
    my $out = run('--fix');
    like( $out, qr/fixed: chmod 2775/, '--fix repairs the cache dir mode' );
    like( $out, qr/fixed: chmod 0660/, '--fix repairs the secret mode' );

    my $after = run();
    like( $after, qr/0 failure\(s\)/, 're-check is clean after --fix' );
    is( $? >> 8, 0, 'zero exit after repair' );
}

# --- missing manager bootstrap is a WARN, not a FAIL ---
{
    open my $c2, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$c2} "site_name: T\n"; close $c2;
    unlink "$doc/lazysite/auth/groups-settings.json";    # no group grants manager
    my $out = run();
    like( $out, qr/no group grants manager access/, 'warns when the manager is unconfigured' );
}

# --- a 0600 (owner-only) secret is flagged as unreadable by the www-data CGI ---
# (the live-500 cause: a secret owned by a non-www-data user with no group read)
{
    chmod 0600, "$doc/lazysite/auth/.secret";
    my $out = run();
    like( $out, qr/not readable by the CGI/,
        'flags an owner-only secret the CGI cannot read' );
    isnt( $? >> 8, 0, 'non-zero exit for an unreadable secret' );
}

# --- content provenance report (SM: "is this content likely ours?") ---
# shipped seed pages carry `provenance: lazysite-starter`; the doctor classifies
# .md content as lazysite (unmodified / customised) vs operator-authored.
{
    # shipped seed pages keep the stamp
    open my $ix, '<', "$root/starter/index.md" or die $!;
    my $idx = do { local $/; <$ix> }; close $ix;
    like( $idx, qr/^provenance:\s*lazysite-starter\s*$/m,
        'shipped starter/index.md carries the provenance stamp' );

    # unmodified stamped page, edited stamped page, operator page
    open my $a, '>', "$doc/index.md" or die $!;
    print {$a} "---\nprovenance: lazysite-starter\ntitle: Home\n---\n\nHi.\n"; close $a;
    open my $b, '>', "$doc/about.md" or die $!;
    print {$b} "---\nprovenance: lazysite-starter\ntitle: About\n---\n\nEDITED.\n"; close $b;
    open my $c, '>', "$doc/mypage.md" or die $!;
    print {$c} "---\ntitle: Mine\n---\n\nOperator content.\n"; close $c;

    require Digest::SHA;
    my $sha = sub {
        open my $h, '<:raw', $_[0] or return '';
        my $d = Digest::SHA->new(256); $d->addfile($h); return 'sha256:' . $d->hexdigest;
    };
    open my $st, '>', "$doc/lazysite/.install-state.json" or die $!;
    print {$st} '{"files":{"' . "$doc/index.md" . '":"' . $sha->("$doc/index.md")
        . '","' . "$doc/about.md" . '":"sha256:0000"}}';
    close $st;

    my $out = run();
    like( $out,
        qr/content provenance: 2 lazysite page\(s\) \[1 unmodified, 1 customised\], 1 operator-authored/,
        'classifies content by provenance stamp + state sha' );
    like( $out, qr/customised.*about\.md/,         'lists the customised lazysite page' );
    like( $out, qr/operator-authored.*mypage\.md/, 'lists the operator-authored page' );
}

# --- TT compile cache: unwritable dirs are flagged and --fix removes the tree ---
# (field-hit 2026-07-09: root-era cache/tt dirs the CGI could not write took
#  every page down to the fallback layout on TT 2.x, and to a 500 on TT 3.x)
SKIP: {
    skip 'root ignores directory modes', 3 if $> == 0;
    make_path("$doc/lazysite/cache/tt/deep");
    chmod 0555, "$doc/lazysite/cache/tt/deep";

    my $out = run();
    like( $out, qr{cache/tt has \d+ dir\(s\) the CGI .*? cannot.*?write}s,
        'unwritable compile-cache dir detected' );
    like( $out, qr{rm -rf .*cache/tt}, 'hint says to remove the cache tree' );

    run('--fix');
    ok( !-d "$doc/lazysite/cache/tt", '--fix removed the compile-cache tree' );
}

# --- post-fix re-report: --fix re-runs the checks, report shows the result ---
# (field feedback 2026-07-09/10: the report after --fix was the PRE-fix
#  snapshot, which read as "the fix did nothing". A fixed FAIL must appear as
#  ok in the SAME run's report.) Ownership/mode arithmetic, so root-safe.
{
    chmod 0644, "$doc/lazysite/auth/.secret";    # world-readable -> FAIL again
    my $out = run('--fix');
    like( $out, qr/fixed: chmod 0660/, '--fix repairs the secret (action line first)' );
    like( $out, qr/reflects the post-fix state/, 'report is marked as post-fix' );
    like( $out, qr{auth/\.secret readable by the CGI, not world-accessible},
        'the fixed FAIL appears as ok in the same run\'s report' );
    like( $out, qr/0 failure\(s\)/, 'post-fix report counts no failures' );
    is( $? >> 8, 0, 'exit status reflects the post-fix state' );
}

# --- no re-report when there was nothing to fix ------------------------------
{
    my $out = run('--fix');
    unlike( $out, qr/reflects the post-fix state/,
        'a --fix run with nothing to fix reports normally' );
}

# --- manager-layout probe (field-hit 2026-07-09): layout.tt must exist and be
#     readable by the CGI IDENTITY, not by whoever runs the check --------------
{
    # re-enable the manager (block above rewrote the conf without it)
    open my $c3, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$c3} "site_name: T\nmanager: enabled\n"; close $c3;
    chmod 0664, "$doc/lazysite/lazysite.conf";

    # missing -> FAIL with the fallback-chrome symptom named
    unlink "$doc/lazysite/manager/layout.tt" or die $!;
    my $out = run();
    like( $out, qr{lazysite/manager/layout\.tt missing}, 'missing manager layout is a FAIL' );
    like( $out, qr/fallback layout, stuck at Loading/, 'symptom named for a missing layout' );
    isnt( $? >> 8, 0, 'non-zero exit for a missing manager layout' );

    # 0640 with a foreign group: readable by root, NOT by the CGI -> FAIL
    open my $lt2, '>', "$doc/lazysite/manager/layout.tt" or die $!;
    print {$lt2} "<html>[% content %]</html>\n"; close $lt2;
    chmod 0640, "$doc/lazysite/manager/layout.tt";
    my ($othergrp) = grep { defined getgrnam($_) && $_ ne $gname } qw(nogroup daemon root);
SKIP: {
        skip 'no second group available to simulate a foreign group', 2
            unless defined $othergrp;
        my $wrong = run_as_group($othergrp);
        like( $wrong, qr{layout\.tt \(0640, .*not readable by\s+the CGI}s,
            'a 0640 wrong-group manager layout is flagged (root -r would pass it)' );
        like( $wrong, qr/fallback layout, stuck at Loading/,
            'symptom named for an unreadable layout' );
    }

    # healthy again
    chmod 0644, "$doc/lazysite/manager/layout.tt";
    my $ok = run();
    like( $ok, qr{\[\s*ok\s*\] lazysite/manager/layout\.tt present and readable},
        'a readable manager layout reports ok' );
}

# --- dir traversal: the CGI must cross lazysite/, manager/, auth/ ------------
# (all checks pass through these components; a missing group-execute is
#  invisible to a root -x test - the arithmetic check sees it, root or not)
{
    chmod 0700, "$doc/lazysite/manager";
    my $out = run();
    like( $out, qr{lazysite/manager/ \(0700, .*not traversable by the CGI}s,
        'a dir without group-execute is flagged as untraversable' );
    isnt( $? >> 8, 0, 'non-zero exit for an untraversable dir' );

    my $fix = run('--fix');
    like( $fix, qr/fixed: chmod 0710/, '--fix adds group-execute (keeps the rest)' );
    like( $fix, qr{lazysite/manager/ traversable by the CGI},
        'post-fix report shows the dir traversable in the same run' );
    is( $? >> 8, 0, 'zero exit after the traversal fix' );
}

# --- doctor convergence (field defect 2026-07-11, dito.tech) -----------------
# A single --fix run must leave NOTHING fixable behind: the old single apply
# pass could CREATE new findings (the root chown pass handed CGI-owned 0600
# secrets to the site user) and then only report them. --fix now iterates
# apply+recollect until stable. Non-root fixture: the exact field category
# mix that is mode-fixable (0600 secrets, unwritable cache/tt, 0644
# nav/audit, world-readable smtp); group-ownership repairs still need root
# and are the documented exclusion (reported with the chown command, never
# silently dropped).
subtest 'one --fix run converges: every fixable FAIL repaired and printed' => sub {
    my $b = tempdir( CLEANUP => 1 );
    my $d = "$b/public_html";
    make_path( "$d/lazysite/auth", "$d/lazysite/forms", "$d/lazysite/logs",
        "$d/lazysite/cache/tt/deep", "$d/lazysite/templates/system" );
    my $w = sub { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1] // "x\n"; close $fh };
    $w->("$d/lazysite/templates/system/$_.md") for qw(login claim 402 403 404); # SM201 defaults
    $w->( "$d/lazysite/lazysite.conf", "site_name: t\n" );
    $w->("$d/lazysite/auth/.secret");
    $w->("$d/lazysite/forms/.secret");
    $w->("$d/lazysite/forms/smtp.conf");
    $w->("$d/lazysite/nav.conf");
    $w->("$d/lazysite/logs/audit.log");
    chmod 0600, "$d/lazysite/auth/.secret", "$d/lazysite/forms/.secret";
    chmod 0666, "$d/lazysite/forms/smtp.conf";    # world bits
    chmod 0644, "$d/lazysite/nav.conf", "$d/lazysite/logs/audit.log";
    chmod 0644, "$d/lazysite/lazysite.conf";
    chmod 0555, "$d/lazysite/cache/tt", "$d/lazysite/cache/tt/deep";    # CGI-unwritable

    my $grp = getgrgid( ( stat $d )[5] ) // ( stat $d )[5];
    my $fix = qx($^X $script --docroot $d --group $grp --fix 2>&1);

    like( $fix, qr/fixed: rm -rf .*cache\/tt/, 'tt cache purge printed its fixed: line' );
    like( $fix, qr/fixed: chmod 0660 .*auth\/\.secret/, 'auth secret fixed AND printed' );
    like( $fix, qr/fixed: chmod 0660 .*forms\/\.secret/, 'forms secret fixed AND printed' );
    like( $fix, qr/fixed: chmod 0660 .*smtp\.conf/,      'smtp.conf fixed AND printed' );
    like( $fix, qr/fixed: chmod 0664 .*nav\.conf/,       'nav.conf fixed AND printed' );
    like( $fix, qr/fixed: chmod 0664 .*audit\.log/,      'audit.log fixed AND printed' );
    like( $fix, qr/0 failure\(s\)/, 'the post-fix report of the SAME run shows 0 failures' );
    is( $? >> 8, 0, 'zero exit after the single --fix run' );

    is( ( ( stat "$d/lazysite/auth/.secret" )[2] & 07777 ), 0660,
        'auth secret really is 0660 on disk' );
    ok( !-e "$d/lazysite/cache/tt", 'tt cache really removed' );

    # The invariant itself: a second plain run finds nothing fixable left.
    my $again = qx($^X $script --docroot $d --group $grp 2>&1);
    like( $again, qr/0 failure\(s\)/, 'a second run reports 0 failures' );
    is( $? >> 8, 0, 'second run exits 0' );
};

# --- chown handover must never strip the CGI's access ------------------------
# The root-only chown pass replicates a CGI-owned path's owner bits onto the
# group before handing it to the site user (the field 500: www-data's 0600
# .secret became ispadmin's 0600). The pure function is probed via
# --handover-mode since the chown branch itself needs root.
subtest 'handover_mode: owner bits replicated onto the group' => sub {
    my %case = (
        '0600' => '0660',    # CGI-minted secret keeps CGI access via the group
        '0640' => '0660',
        '0755' => '0775',    # CGI-created tt-cache dir stays CGI-writable
        '0700' => '0770',
        '2770' => '2770',    # already group-complete: unchanged
        '0444' => '0444',    # nothing new to grant
    );
    for my $in ( sort keys %case ) {
        my $out = qx($^X $script --handover-mode $in);
        chomp $out;
        is( $out, $case{$in}, "handover_mode($in) -> $case{$in}" );
    }
};

# SM190 / SM200 lever 4: a remote service enabled with a bad/absent site_url is
# flagged (the .well-known docs would advertise broken endpoints - the outsourcify
# onboarding class of failure).
subtest 'OAuth/remote discovery coherence check (SM190/SM200)' => sub {
    my $b  = tempdir( CLEANUP => 1 );
    my $c  = "$b/lazysite";
    my $sp = sub { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh };
    make_path("$c/templates/system");
    $sp->( "$c/templates/system/$_.md", "x\n" ) for qw(login claim 402 403 404);

    my $w   = sub { $sp->( "$c/lazysite.conf", $_[0] ) };
    my $run = sub { qx($^X $script --docroot $b 2>&1) };

    $w->("site_name: t\noauth_enabled: enabled\n");    # remote service on, NO site_url
    like( $run->(), qr/site_url is UNSET.*discovery/s,
        'oauth on + no site_url -> FAIL naming the discovery breakage' );

    $w->("site_name: t\noauth_enabled: enabled\nsite_url: http://x.example\n"); # not https
    like( $run->(), qr/not https/, 'oauth on + http site_url -> WARN (https required)' );

    $w->("site_name: t\nmcp_enabled: enabled\nsite_url: https://x.example/\n"); # trailing slash
    like( $run->(), qr/trailing slash/, 'trailing-slash site_url -> WARN (double slash)' );

    $w->("site_name: t\noauth_enabled: enabled\nsite_url: https://x.example\n"); # coherent
    like( $run->(), qr/discovery: site_url .*is coherent/, 'a clean https site_url -> OK' );

    # The house-standard dynamic value resolves to https under TLS - it must NOT
    # be flagged "not https" (the 0.9.13 fleet-wide false positive).
    $w->("site_name: t\noauth_enabled: enabled\nsite_url: \${REQUEST_SCHEME}://\${SERVER_NAME}\n");
    my $dyn = $run->();
    unlike( $dyn, qr/not https/, 'dynamic ${REQUEST_SCHEME} site_url -> no "not https" warn' );
    like( $dyn, qr/discovery: site_url .*is coherent/, 'dynamic ${REQUEST_SCHEME} site_url -> OK' );

    # ...but a trailing slash on the dynamic form is still caught.
    $w->("site_name: t\noauth_enabled: enabled\nsite_url: \${REQUEST_SCHEME}://\${SERVER_NAME}/\n");
    like( $run->(), qr/trailing slash/, 'dynamic site_url with trailing slash -> WARN' );

    $w->("site_name: t\n");    # no remote service -> the check is silent
    unlike( $run->(), qr/discovery/, 'no remote service enabled -> no discovery finding' );
};

# --- SM286: content present in BOTH trees ----------------------------------
# The private store's one invariant is that a path lives in exactly one tree. A
# path in both is always the same fault in the same direction: the private copy
# is the one the engine governs, and the public one is served without asking the
# engine at all - SM283 restored for a single file.
#
# It cannot come from a completed move (move_in renames, and refuses an occupied
# destination rather than overwriting). It comes from a cross-device copy
# interrupted mid-way, a restore of an archive written before the content was
# protected, or an operator putting a file back by hand - none of which anything
# else in this tool would notice.
subtest 'a stray public copy of protected content is a FAIL' => sub {
    my $store = "$base/public_html-lazysite-private";
    make_path("$store/members");

    open my $pf, '>', "$store/members/secret.md" or die $!;
    print {$pf} "GATED\n";
    close $pf;

    my $clean = run();
    like( $clean, qr/protected content is held outside the document root/,
        'with the content only in the store, the check says so' );
    unlike( $clean, qr/ALSO present in the document root/,
        'and does not report a stray copy that is not there' );

    # Now put a copy back where the front end serves it.
    make_path("$doc/members");
    open my $sf, '>', "$doc/members/secret.md" or die $!;
    print {$sf} "GATED\n";
    close $sf;

    my $out = run();
    like( $out, qr/ALSO present in the document root/,
        'the stray copy is reported' );
    like( $out, qr/\bFAIL\b/, 'as a FAIL - the site is serving content it was told to protect' );
    like( $out, qr/members\/secret\.md/, 'naming the path so it can be acted on' );
    like( $out, qr/will not delete content for you/,
        'and says it did not repair it - which copy to keep is a content '
            . 'decision, not one a permissions tool should take' );

    unlink "$doc/members/secret.md";
};


# --- SM293: where the engine tree is, and a FAIL if it is in two places ------
subtest 'the engine tree layout is reported, and a half-migration FAILs' => sub {
    my $inside = run();
    like( $inside, qr/engine tree is inside the document root/,
        'an unmigrated site is reported as such - supported, not nagged about, '
            . 'because nagging every site every run teaches the reader to skip '
            . 'the section where the FAIL below lives' );
    unlike( $inside, qr/BOTH places/, 'and is not reported as half-migrated' );

    # Half-migrated: the engine reads the outside copy while the front end can
    # still serve the inside one, so the site behaves perfectly and publishes
    # its credentials. Invisible from outside, which is why it is a FAIL.
    my $ext = "$base/public_html-lazysite";
    make_path("$ext/auth");

    my $both = run();
    like( $both, qr/BOTH places/, 'a tree in both places is reported' );
    like( $both, qr/\bFAIL\b/,    'as a FAIL' );
    like( $both, qr/will not delete/, 'and says it did not repair it - these '
            . 'are the operator`s live credentials' );

    # Now the migrated shape: only the outside tree.
    my $stash = "$base/stashed-lazysite";
    rename "$doc/lazysite", $stash or die "rename: $!";
    my $out = run();
    like( $out, qr/held outside the document root/,
        'a migrated site is reported as needing no front-end rule at all' );
    unlike( $out, qr/BOTH places/, 'and is no longer half-migrated' );

    rename $stash, "$doc/lazysite" or die "rename back: $!";
    remove_tree($ext);
};


# --- SM293 step 3: registries left over from before they were served ---------
subtest 'a leftover generated registry in the docroot is reported' => sub {
    # They used to be written into the content root. A file left at the old path
    # is still resolved by the front end BEFORE the engine is consulted, so it
    # keeps being served and nothing regenerates it - a sitemap frozen on the day
    # of the upgrade, quietly.
    make_path("$doc/lazysite/templates/registries");
    open my $t, '>', "$doc/lazysite/templates/registries/sitemap.xml.tt" or die $!;
    print {$t} "<urlset/>\n";
    close $t;

    my $clean = run();
    unlike( $clean, qr/still in the document root/,
        'nothing reported when no leftover is present' );

    open my $old, '>', "$doc/sitemap.xml" or die $!;
    print {$old} "<urlset>STALE</urlset>\n";
    close $old;

    my $out = run();
    like( $out, qr/still in the document root/, 'the leftover is reported' );
    like( $out, qr/sitemap\.xml/,               'and named' );
    # The report prints ' warn ' lowercase (FAIL is upper) - asserting /WARN/
    # matched nothing and looked like the finding was absent.
    like( $out, qr/\[ warn \].*still in the document root/,
        'as a warning - a stale sitemap is an SEO problem, not a disclosure' );
    like( $out, qr/If you DID write your own, leave it/,
        'and it does not tell an operator to delete a file they authored' );

    ok( -f "$doc/sitemap.xml", 'and it was not deleted' );
    unlink "$doc/sitemap.xml";
};

done_testing();
