#!/usr/bin/perl
# lazysite-check (the install/permissions doctor): detects bad perms + secrets,
# and --fix repairs the chmod issues.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
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
chmod 0644, "$doc/lazysite/auth/.secret";   # world-readable -> FAIL
chmod 0755, "$doc/lazysite/cache";          # not group-writable / no setgid -> FAIL
chmod 02770, "$doc/lazysite/auth";
for my $s (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
    open my $x, '>', "$cgi/$s" or die $!; print {$x} "#!/usr/bin/perl\n"; close $x;
    chmod 0755, "$cgi/$s";
}

# The test's files are owned by the test user's group (not www-data), so pass
# --group explicitly; otherwise the group check would (correctly) flag them.
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];
sub run_as_group { my $g = shift; qx($^X $script --docroot $doc --cgibin $cgi --group $g @_ 2>&1) }
sub run { run_as_group( $gname, @_ ) }

# --- detection ---
{
    my $out = run();
    like( $out, qr/world-accessible/,            'flags the world-readable secret' );
    like( $out, qr{lazysite/cache.*cannot write}, 'flags the non-writable cache dir' );
    like( $out, qr/manager bootstrapped/,        'recognises a bootstrapped manager' );
    like( $out, qr/failure\(s\)/,                'prints a summary' );
    isnt( $? >> 8, 0,                            'non-zero exit when a check FAILs' );
}

# --- fix ---
{
    my $out = run('--fix');
    like( $out, qr/fixed: chmod 2775/, '--fix repairs the cache dir mode' );
    like( $out, qr/fixed: chmod 0660/, '--fix repairs the secret mode' );

    my $after = run();
    like( $after, qr/0 failure\(s\)/, 're-check is clean after --fix' );
    is( $? >> 8, 0,                   'zero exit after repair' );
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

done_testing();
