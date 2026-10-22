#!/usr/bin/perl
# SM1238 (#378): the SM296 dry run names what has not moved, and the Hestia
# updater runs it on every site with --reapply-acls-dry-run.
#
# THE 0.16.0 RELEASE NOTES, ON UPGRADE step 2: run
#   sudo -u <site user> perl <stage>/tools/lazysite-acl.pl reapply --docroot D --actor local
# on each site; 'A line "NOT MOVED: <path>" names content whose access rule is
# stored but whose files are still in the document root ... A site with no such
# line is settled.' The dry run printed no such line - it listed every rule - so
# every site read as settled, and the step had to be run by hand on every site
# of a fleet. --reapply-acls only applies, and its output is filtered.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use JSON::PP ();
use File::Basename ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $ACL  = "$root/tools/lazysite-acl.pl";
my $UPD  = "$root/installers/hestia/lazysite-hestia-update-all.sh";

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

subtest 'the dry run names each rule whose files are still in the document root' => sub {
    my $d = Cwd::realpath( site_tempdir() );
    make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/members", "$d/drafts", "$d/editors", "$d/moved" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "alice:x\n" );
    spit( "$d/$_/page.md", "---\ntitle: P\n---\nbody\n" ) for qw(members drafts editors moved);
    spit( "$d/lazysite/auth/acls.json", JSON::PP->new->canonical->encode( {
                'members/' => { read  => ['alice'] },            # gated, still public
                'drafts/'  => { draft => 1 },                     # draft, still public
                'editors/' => { write => ['alice'] },            # write-only: moves nothing
                'moved/'   => { read  => ['alice'] },            # gated and moved
                '/'        => { read  => ['alice'] },            # site-wide: moves nothing
    } ) );
    # 'moved' is where the rule puts it: in the store, and not in the docroot.
    require Lazysite::Private;
    my $priv = Lazysite::Private::private_path( $d, 'moved' );
    make_path( File::Basename::dirname($priv) );
    rename "$d/moved", $priv or die "move: $!";

    my $out = qx($^X \Q$ACL\E reapply --docroot \Q$d\E --actor local 2>&1);
    is( $? >> 8, 0, 'a dry run exits 0' ) or diag $out;
    like( $out, qr/^NOT MOVED: members\/?$/m, 'a gated folder still in the docroot is NOT MOVED' )
        or diag $out;
    like( $out, qr/^NOT MOVED: drafts\/?$/m, 'and a draft one' );
    unlike( $out, qr/^NOT MOVED: (?:editors|moved|\/)/m,
        'not a write-only rule, a moved section or the site-wide rule' ) or diag $out;
    like( $out, qr/Nothing has changed/, 'and nothing changed' );
    ok( -d "$d/members", 'the content is where it was' );

    my $j = qx($^X \Q$ACL\E reapply --docroot \Q$d\E --actor local --json 2>&1);
    my $r = eval { JSON::PP::decode_json($j) } || {};
    is_deeply( [ sort map { s{/\z}{}r } @{ $r->{not_moved} || [] } ], [qw(drafts members)],
        '--json carries not_moved' ) or diag $j;
};

# --- the updater -------------------------------------------------------------
my $u = slurp($UPD);
my ($fn) = $u =~ /^(acl_dry_run_site\(\) \{\n.*?^\}\n)/ms;
ok( $fn, 'the updater defines acl_dry_run_site' ) or do { done_testing; exit };

my $t = Cwd::realpath( site_tempdir() );
sub dry {
    my ( $rc, $out ) = @_;
    spit( "$t/out.txt", $out );
    spit( "$t/acl.pl",  "open my \$f, '<', '$t/out.txt' or die; print <\$f>; exit $rc;\n" );
    spit( "$t/f", '' );
    # sudo is a stand-in that records who it ran as, then runs the command.
    spit( "$t/d.sh", "set -u\nVERBOSE=0\nACLTOOL='$t/acl.pl'\nFINDINGS_FILE='$t/f'\n"
            . "sudo() { echo \"AS \$2: \${*:3}\" > '$t/as'; shift 2; \"\$\@\"; }\n"
            . "$fn\nacl_dry_run_site a.example siteuser /home/siteuser/web/a.example/public_html\n"
            . "echo \"VERDICT=\$DRY_VERDICT\"\n" );
    my $shown = qx(bash '$t/d.sh' 2>&1);
    $shown .= slurp("$t/as") if -f "$t/as";
    return ( $shown, slurp("$t/f") );
}

subtest 'the updater runs it as the site user, without --apply, and keeps each NOT MOVED' => sub {
    my ( $shown, $f ) = dry( 0, "Would re-apply 2 rule(s) on D:\n  members/\n  docs/\n\nNOT MOVED: members/\n"
            . "  its rule is stored and its files are still in the document root; --apply moves them\n"
            . "NOT MOVED: docs/\n  its rule is stored ...\n\nNothing has changed.\n" );
    like( $shown, qr/^AS siteuser: perl \S+acl\.pl reapply --docroot \S+ --actor local$/m,
        'as the site\'s own user, and no --apply' ) or diag $shown;
    like( $shown, qr/VERDICT=found/, 'a site with a NOT MOVED line is a finding' );
    my @l = grep {length} split /\n/, $f;
    is( scalar @l, 2, 'one finding per NOT MOVED line' ) or diag $f;
    like( $l[0], qr/^a\.example\tNOT MOVED: members\/ - its access rule is stored and its files are still in the document root \(the SM296 state\)/,
        'labelled with the site, saying what it means' );

    ( $shown, $f ) = dry( 0, "Would re-apply 1 rule(s) on D:\n  members/\n\nNothing has changed.\n" );
    like( $shown, qr/VERDICT=settled/, 'no NOT MOVED line: settled' );
    is( $f, '', 'with nothing to report' );

    ( $shown, $f ) = dry( 1, "lazysite acl: cannot read acls.json\n" );
    like( $shown, qr/VERDICT=failed/, 'a dry run that failed is not "settled"' );
    like( $shown, qr/full output.*cannot read acls\.json/s, 'and its output is shown' );
};

subtest 'the flag, the sweep and the verdict' => sub {
    like( $u, qr/--reapply-acls-dry-run\) DO_REAPPLY_DRY=1 ;;/, 'the flag is parsed' );
    like( $u, qr/in_list "\$d" "\$\{SKIPPED\[\@\]\}" && continue\n\s*in_list "\$d" "\$\{FAILED\[\@\]\}"  && continue\n\s*dr="\$\{DOCS\[\$i\]\}"\n.*?acl_dry_run_site/s,
        'it sweeps the sites that upgraded, as the apply does' );
    like( $u, qr/\|\| \[ -n "\$\{DRY_FOUND\[\*\]:-\}" \] \|\| \[ -n "\$\{DRY_FAILED\[\*\]:-\}" \]; then\n\s*echo\n\s*echo "ROLLOUT SUCCEEDED, FLEET HAS FINDINGS/,
        'a NOT MOVED line makes the fleet a finding (exit 2)' );
};

done_testing();
