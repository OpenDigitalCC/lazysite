#!/usr/bin/perl
# Q16f: EXIT 4 MEANT TWO THINGS ON THE ROLLOUT PATH.
#
# install.pl exits 4 for "installed, and the site is NOT serviceable" (SM933).
# lazysite-hestia-deploy.sh exits 4 for "skipped by the site's update channel",
# and passed install.pl's own 4 straight through. lazysite-hestia-update-all.sh
# read every 4 as the skip. On the 0.15.4 edge rollout a site that upgraded and
# failed its health check was listed "SKIPPED (stable site, edge release not
# installed)", the run counted 0 failed and exited 0, the summary said
# "check: 0 clean, 0 with warnings or failures" (a skipped site is not checked),
# and tools/lazysite-deploy.sh printed "Version 0.15.4 deployed".
#
# The codes now, each driven here through the scripts' own text:
#   install.pl   0 ok, 1 failed, 2 usage, 3 channel skip, 4 not serviceable
#   deploy       0 ok, 1 failed, 4 channel skip, 5 not serviceable (the check
#                still fails after the deploy's repair; install.pl's 4 is not
#                passed through - the permission pass and repair run first)
#   update-all   per site: updated / skipped (channel) / NOT SERVICEABLE /
#                FAILED; exit 1 a failed install, 2 a site that needs a human,
#                0 otherwise
#   lazysite-deploy.sh reads 2 as "deployed - FLEET HAS FINDINGS".
#
# Both scripts must run as root on a Hestia host, so the parts that decide are
# taken from their text and run with stand-ins, as t/tools/43 and 71 do.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root    = repo_root();
my $updater = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $deploy  = "$root/installers/hestia/lazysite-hestia-deploy.sh";
plan skip_all => 'the Hestia scripts are not here' unless -f $updater && -f $deploy;

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f; chmod 0755, $p }

my $u = slurp($updater);
my $d = slurp($deploy);

# --- the parts, from the scripts' own text ----------------------------------
my ($helpers) = $u =~ /(^TBL_FMT=.*?^run_quiet\(\) \{.*?^\}$)/ms;
my ($in_list) = $u =~ /(^in_list\(\) \{[^\n]*\}$)/m;
my ($loop)    = $u =~ /(^ok=0; SKIPPED=\(\);.*?^done$)/ms;
my ($lists) = $u =~ /(^\[ "\$\{#SKIPPED\[\@\]\}" -gt 0 \].*?"\$\{UNSERVICEABLE\[\*\]\}"$)/ms;
my ($summary) = $u =~ /(^_chk_clean=0; _chk_warn=0; _vh_rebuild=0\n.*?^\s*"\$_chk_clean" "\$_chk_warn"[^\n]*$)/ms;
my ($verdict) = $u =~ /(\n# SM344:.*)\z/s;
my ($irc)     = $d =~ /(^if \[ "\$IRC" = 3 \]; then\n.*?^fi$)/ms;
my ($final) = $d =~ /(^set \+e\nperl "\$DOM\/tools\/lazysite-check\.pl" --docroot "\$DOC" --cgibin "\$CGI" --fix\n.*?\z)/ms;
for ( [ helpers => $helpers ], [ in_list => $in_list ], [ 'deploy loop' => $loop ], [ 'the lists' => $lists ],
    [ summary => $summary ], [ verdict => $verdict ], [ "deploy's install verdict" => $irc ],
    [ "deploy's final check" => $final ] )
{
    ok( $_->[1], "found in the scripts: $_->[0]" ) or BAIL_OUT("the scripts changed shape: $_->[0]");
}

my $dir = site_tempdir();
( my $t = $dir ) =~ s{/site/public_html\z}{};

# A deploy built from the deploy script's own install verdict and final check:
# a stand-in install.pl exits $INSTALL_RC, a stand-in check exits $CHECK_RC.
spit( "$t/install.pl", "exit \$ENV{INSTALL_RC};\n" );
mkdir "$t/dom";
mkdir "$t/dom/tools";
spit( "$t/dom/tools/lazysite-check.pl", "print \"check ran\\n\"; exit \$ENV{CHECK_RC};\n" );
spit( "$t/deploy.sh", "#!/bin/bash\nset -e\nDOMAIN=\$2; DOM='$t/dom'; DOC=/nowhere; CGI=/nowhere\n"
        . "set +e\nperl '$t/install.pl'\nIRC=\$?\nset -e\n$irc\n$final\nexit 0\n" );

# The deploy alone: what each install.pl answer becomes.
sub deploy_rc {
    my ( $install, $check ) = @_;
    local $ENV{INSTALL_RC} = $install;
    local $ENV{CHECK_RC}   = $check;
    my $out = `bash '$t/deploy.sh' u site.example 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'the deploy gives each meaning of 4 its own code' => sub {
    my ( $rc, $out ) = deploy_rc( 0, 0 );
    is( $rc, 0, 'installed and healthy: 0' );
    ( $rc, $out ) = deploy_rc( 3, 0 );
    is( $rc, 4, 'skipped by the channel: 4' );
    unlike( $out, qr/check ran/, '...and nothing after it runs' );
    ( $rc, $out ) = deploy_rc( 4, 1 );
    is( $rc, 5, 'installed, not serviceable, still failing after the repair: 5, not the skip\'s 4' );
    like( $out, qr/check ran/,       '...and the permission pass and repair ran first' );
    like( $out, qr/NOT SERVICEABLE/, '...saying so' );
    ( $rc, $out ) = deploy_rc( 4, 0 );
    is( $rc, 0, 'install said not serviceable and the repair cleared it: 0' );
    like( $out, qr/cleared by the permission pass and the repair/, '...saying what happened' );
    ( $rc, $out ) = deploy_rc( 0, 1 );
    is( $rc, 5, 'installed healthy, then a failure the repair could not clear: 5' );
    ( $rc, $out ) = deploy_rc( 1, 0 );
    is( $rc, 1, 'the install failed: 1' );
};

# The updater's loop, lists, summary and verdict, over stand-in deploys.
sub rollout {
    my (%site) = @_;                # domain => deploy script to run for it
    my @doms = sort keys %site;
    spit( "$t/route.sh", "#!/bin/bash\ncase \"\$2\" in\n"
            . join( '', map { "  $_) exec $site{$_} \"\$\@\" ;;\n" } @doms )
            . "esac\nexit 99\n" );
    my $body = "set -u\nVERBOSE=0\nSTAGE=/nowhere\nDEPLOY='$t/route.sh'\nLZS='$t/cli.pl'\nNEWVER=9.9.9\nSTAGED_REV=x\n"
        . "OUT_OF_SCOPE=(); EXC_D=(); EXC_V=(); PROXY_FAILED=(); VERS=()\n"
        . "DOMAINS=(@doms)\nUSERS=(" . join( ' ', ('u') x @doms ) . ")\n"
        . "$in_list\n$helpers\n"
        . "sum_row() { printf 'ROW %s %s\\n' \"\$1\" \"\$6\"; }\n"
        . "vhost_state() { echo current; }\n"
        . "check_verdict() { echo '1 FAIL, 2 warn'; }\n"
        . "$loop\n$lists\n$summary\n$verdict\n";
    spit( "$t/cli.pl",     "1;\n" );
    spit( "$t/rollout.sh", $body );
    my $out = `bash '$t/rollout.sh' 2>&1`;
    return ( $? >> 8, $out );
}

spit( "$t/d-ok.sh", "#!/bin/bash\necho installed\nexit 0\n" );
spit( "$t/d-skip.sh", "#!/bin/bash\necho '==> upgrade SKIPPED: stable channel, edge build.'\nexit 4\n" );
spit( "$t/d-fail.sh", "#!/bin/bash\necho 'ERROR: install failed (exit 1)'\nexit 1\n" );
spit( "$t/d-unserv.sh", "#!/bin/bash\nINSTALL_RC=4 CHECK_RC=1 exec bash '$t/deploy.sh' \"\$\@\"\n" );

subtest 'the updater: a site that installed and is not serviceable needs a human' => sub {
    my ( $rc, $out ) = rollout( 'a.example' => "$t/d-ok.sh", 'b.example' => "$t/d-skip.sh", 'c.example' => "$t/d-unserv.sh" );
    like( $out, qr/^ROW a\.example updated$/m, 'the healthy site is updated' );
    like( $out, qr/^ROW b\.example skipped \(channel\)$/m, 'the channel skip is a skip' );
    like( $out, qr/^ROW c\.example NOT SERVICEABLE$/m, 'the unhealthy site is NOT SERVICEABLE, not a skip' );
    unlike( $out, qr/SKIPPED[^\n]*c\.example/, 'and is not listed with the skips' );
    like( $out, qr/^NOT SERVICEABLE \(installed[^\n]*: c\.example$/m, 'it is listed by name' );
    like( $out, qr/1 updated, 0 failed, 1 not serviceable, 1 skipped/, 'and counted' );
    like( $out, qr/check:\s+0 clean, 2 with warnings or failures/,
        'its check is counted with the updated site\'s (both report findings here)' );
    is( $rc, 2, 'the rollout exits 2 - a human is needed, a retry will not help' );
    like( $out, qr/1 SITE\(S\) NOT SERVICEABLE/, 'saying so' );
};

subtest 'the updater: skip and success alone exit 0' => sub {
    my ( $rc, $out ) = rollout( 'a.example' => "$t/d-ok.sh", 'b.example' => "$t/d-skip.sh" );
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( $out, qr/1 updated, 0 failed, 0 not serviceable, 1 skipped/, 'counted' );
};

subtest 'the updater: a failed install is still a failed rollout' => sub {
    my ( $rc, $out ) = rollout( 'a.example' => "$t/d-fail.sh", 'c.example' => "$t/d-unserv.sh" );
    like( $out, qr/^ROW a\.example FAILED \(status 1\)$/m, 'the failed install is FAILED' );
    is( $rc, 1, 'and a failure outranks a finding: exit 1, a retry is meaningful' );
};

subtest 'the watcher reads 2 as a deploy with findings' => sub {
    my $w = slurp("$root/tools/lazysite-deploy.sh");
    like( $w, qr/^\s*2\)\s*\n(?:\s*#[^\n]*\n)*\s*printf '\\nVersion %s deployed - FLEET HAS FINDINGS/m,
        'lazysite-deploy.sh prints findings for 2' );
};

done_testing();
