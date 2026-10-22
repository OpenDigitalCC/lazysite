#!/usr/bin/perl
# SM1265 (#379 part 2, ruled option B, 2026-10-22): --rebuild-exposed rebuilds
# ONLY the in-scope sites in the X-Forwarded-For pass-through FAILURE, inside the
# run and BEFORE the deploy, so the permission pass and the repair follow.
#
# The FAILURE (SM1194) is a vhost rendered before SM929 in front of a site that
# trusts forwarded addresses: any visitor chooses their address. The fix was
# --rebuild (every site) or a manual v-rebuild-web-domain, which resets the
# docroot permissions (SM270) unless a repair follows. The ruling: an opt-in flag
# for just these sites, logged, and named by the FAILURE when it was not given.
#
# The updater's own text is extracted and run against fixture vhosts and a
# stand-in v-rebuild-web-domain; no Hestia command runs.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $ROOT = repo_root();
my $UPD  = "$ROOT/installers/hestia/lazysite-hestia-update-all.sh";
my $R    = site_tempdir();

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

my $src = slurp($UPD);
my %fn;
my @names = qw(cli_cmd xff_fix_words lazysite_dir template_rev vhost_xff_state site_trust_kind
    xff_reason xff_exposure rebuild_exposed);
for my $n (@names) {
    ( $fn{$n} ) = $src =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}
my ($block) = $src =~ /(^# --- SM1265: rebuild only the exposed vhosts, BEFORE deploying -+\n.*?^fi\n)/ms;
ok( $block, 'the --rebuild-exposed step is found' ) or do { done_testing; exit };

my $OLD = "# lazysite-template-rev: 2026-09-11\nserver {\n    location / {\n"
    . "        proxy_pass http://127.0.0.1:8080;\n    }\n}\n";
my $NEW = "# lazysite-template-rev: 2026-10-20\nserver {\n    location / {\n"
    . "        proxy_pass http://127.0.0.1:8080;\n"
    . "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n    }\n}\n";

# exposed: old template + default trust. safe-old: old template, trusted_proxies:
# none - not exposed. current: new template + a trust list - not exposed.
my %conf = ( 'exposed.example' => "site_name: T\n", 'safe-old.example' => "trusted_proxies: none\n",
    'current.example' => "trusted_proxies: 10.0.0.1\n" );
my %vh = ( 'exposed.example' => $OLD, 'safe-old.example' => $OLD, 'current.example' => $NEW );
my @doms = sort keys %conf;

sub run_step {
    my ($flag) = @_;
    for my $d (@doms) {
        make_path( "$R/home/u/conf/web/$d", "$R/home/u/web/$d/public_html/lazysite" );
        spit( "$R/home/u/conf/web/$d/nginx.ssl.conf", $vh{$d} );
        spit( "$R/home/u/web/$d/public_html/lazysite/lazysite.conf", $conf{$d} );
    }
    # The stand-in rebuild renders the release's template, as Hestia would from
    # a refreshed copy, and records what it was asked to rebuild.
    make_path("$R/hestia/bin");
    unlink "$R/rebuilt";
    spit( "$R/hestia/bin/v-rebuild-web-domain",
        "#!/bin/bash\necho \"\$1 \$2\" >> '$R/rebuilt'\ncat '$R/new.conf' > '$R/home/'\"\$1\"'/conf/web/'\"\$2\"'/nginx.ssl.conf'\n" );
    chmod 0755, "$R/hestia/bin/v-rebuild-web-domain";
    spit( "$R/new.conf", $NEW );
    spit( "$R/findings", '' );
    spit( "$R/t.sh", "set -u\nHOME_BASE='$R/home'\nHESTIA='$R/hestia'\nFINDINGS_FILE='$R/findings'\n"
            . "LZS=/stage/tools/lazysite-cli.pl\nDO_REBUILD=0\nDO_REBUILD_EXPOSED=$flag\n"
            . "DOMAINS=(@doms)\nUSERS=(u u u)\nDOCS=(" . join( ' ', map {"'$R/home/u/web/$_/public_html'"} @doms ) . ")\n"
            . join( '', map { $fn{$_} } @names ) . $block
            . "for i in \"\${!DOMAINS[\@]}\"; do xff_exposure u \"\${DOMAINS[\$i]}\" \"\${DOCS[\$i]}\"; done\n" );
    my $out = qx(bash '$R/t.sh' 2>&1);
    my $rebuilt = -f "$R/rebuilt" ? slurp("$R/rebuilt") : '';
    return ( $out, $rebuilt, slurp("$R/findings") );
}

subtest 'with the flag: the exposed site is rebuilt, and only it' => sub {
    my ( $out, $rebuilt, $f ) = run_step(1);
    is( $rebuilt, "u exposed.example\n", 'v-rebuild-web-domain ran for the exposed site alone' )
        or diag $out;
    like( $out, qr/^\s*auto-rebuilt: exposed\.example /m, 'logged as auto-rebuilt' );
    like( $f, qr/^exposed\.example\tNOTE: auto-rebuilt by --rebuild-exposed/m, 'and among the findings' );
    unlike( $out, qr/FAILURE: exposed\.example/, 'after it the site is no longer exposed' ) or diag $out;
    unlike( $rebuilt, qr/safe-old/, 'a site on an old template that is not exposed is NOT rebuilt' );
};

subtest 'without the flag: nothing is rebuilt, and the FAILURE names the flag' => sub {
    my ( $out, $rebuilt ) = run_step(0);
    is( $rebuilt, '', 'no rebuild ran' );
    like( $out, qr/^FAILURE: exposed\.example: .*fix: re-run with --rebuild-exposed, which rebuilds only the exposed sites/m,
        'the FAILURE names --rebuild-exposed' ) or diag $out;
};

subtest 'it runs before the deploy, so the permission pass and the repair follow' => sub {
    my $at_step   = index( $src, '# --- SM1265: rebuild only the exposed vhosts' );
    my $at_refresh = index( $src, 'refresh_template "$TPLDIR" lazysite-app tpl stpl sh' );
    my $at_deploy = index( $src, 'ok=0; SKIPPED=(); FAILED=();' );
    my $at_repair = index( $src, 'run_quiet "repair ${DOMAINS[$i]}" perl "$LZS" repair --domain' );
    ok( $at_refresh > 0 && $at_step > $at_refresh, 'after Hestia\'s template copy is refreshed (SM1196)' );
    ok( $at_deploy > $at_step, 'before the deploy and its permission pass' );
    ok( $at_repair > $at_deploy, 'which the repair follows on every in-scope site' );
};

subtest 'refused alongside --list' => sub {
    my $out = qx(bash \Q$UPD\E --list --rebuild-exposed /nowhere 2>&1);
    is( $? >> 8, 2, 'exit 2' );
    like( $out, qr/--rebuild-exposed rebuilds vhosts and --list changes nothing/, 'saying why' );
};

done_testing();
