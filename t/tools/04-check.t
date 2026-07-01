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
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", $cgi );

# a healthy-ish conf + a bootstrapped manager
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmanager: enabled\nmanager_groups: lazysite-admins\n";
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
sub run { qx($^X $script --docroot $doc --cgibin $cgi --group $gname @_ 2>&1) }

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
    print {$c2} "site_name: T\n"; close $c2;   # no manager_groups
    my $out = run();
    like( $out, qr/manager_groups not set/, 'warns when the manager is unconfigured' );
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

done_testing();
