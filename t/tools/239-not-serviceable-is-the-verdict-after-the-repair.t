#!/usr/bin/perl
# SM1239: the rollout's NOT SERVICEABLE is the verdict of the check after the
# repair, not of the deploy's own check before it.
#
# THE 0.16.0 ROLLOUT (2026-10-22) reported sumaya.fund and opendigital.cc NOT
# SERVICEABLE and, in the same run, "repair: 32 clean, 0 need a human". A later
# `lazysite-cli.pl repair --domain` on each found 0 failures. NOT SERVICEABLE is
# the deploy's exit 5 - its final check, run straight after the install - and the
# summary kept it whatever the repair, which runs later on every site, found.
#
# Driven like t/tools/107: the updater's own deploy loop, repair loop, lists,
# summary and verdict, over stand-in deploys and a stand-in CLI.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit  { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f; chmod 0755, $p }

my $u = slurp("$root/installers/hestia/lazysite-hestia-update-all.sh");
my ($helpers) = $u =~ /(^TBL_FMT=.*?^run_quiet\(\) \{.*?^\}$)/ms;
my ($in_list) = $u =~ /(^in_list\(\) \{[^\n]*\}$)/m;
my ($loop)    = $u =~ /(^ok=0; SKIPPED=\(\);.*?^done$)/ms;
my ($repair)  = $u =~ /(^    _rep_clean=0; _rep_fixed=0; _rep_human=0\n.*?^    done$)/ms;
my ($lists)   = $u =~ /(^\[ "\$\{#SKIPPED\[\@\]\}" -gt 0 \].*?"\$\{UNSERVICEABLE\[\*\]\}"$)/ms;
my ($summary) = $u =~ /(^_chk_clean=0; _chk_warn=0; _vh_rebuild=0\n.*?^\s*"\$_chk_clean" "\$_chk_warn"[^\n]*$)/ms;
my ($verdict) = $u =~ /(\n# SM344:.*)\z/s;
for ( [ helpers => $helpers ], [ in_list => $in_list ], [ 'deploy loop' => $loop ], [ 'repair loop' => $repair ],
    [ lists => $lists ], [ summary => $summary ], [ verdict => $verdict ] )
{
    ok( $_->[1], "found in the updater: $_->[0]" ) or BAIL_OUT("the updater changed shape: $_->[0]");
}
ok( index( $u, $repair ) < index( $u, $lists ), 'the lists print after the repair has run' );

my $t = site_tempdir();
$t =~ s{/site/public_html\z}{};

# $site{domain} = [ deploy exit, repair exit ]
sub rollout {
    my (%site) = @_;
    my @doms = sort keys %site;
    spit( "$t/route.sh", "#!/bin/bash\ncase \"\$2\" in\n"
            . join( '', map {
                my $rc = $site{$_}[0];
                "  $_) echo 'deployed $_'; "
                    . ( $rc == 5 ? "echo 'NOT SERVICEABLE: $_ installed, and its health check still names a failure' >&2; " : '' )
                    . "exit $rc ;;\n"
            } @doms )
            . "esac\nexit 99\n" );
    spit( "$t/cli.pl", "my \%rc = (" . join( ', ', map {"'$_' => $site{$_}[1]"} @doms ) . ");\n"
            . "my (\$verb, undef, \$d) = \@ARGV;\nprint \"\$verb \$d\\n\";\nexit( \$rc{\$d} // 0 );\n" );
    my $body = "set -u\nVERBOSE=0\nSTAGE=/nowhere\nDEPLOY='$t/route.sh'\nLZS='$t/cli.pl'\nNEWVER=9.9.9\nSTAGED_REV=x\n"
        . "OUT_OF_SCOPE=(); EXC_D=(); EXC_V=(); PROXY_FAILED=(); VERS=()\n"
        . "DOMAINS=(@doms)\nUSERS=(" . join( ' ', ('u') x @doms ) . ")\n"
        . "$in_list\n$helpers\n"
        . "trap - EXIT\nFINDINGS_FILE='$t/findings'\n: > \"\$FINDINGS_FILE\"\n"
        . "sum_row() { printf 'ROW %s %s\\n' \"\$1\" \"\$6\"; }\n"
        . "vhost_state() { echo current; }\n"
        . "check_verdict() { echo clean; }\n"
        . "$loop\n$repair\n$lists\n$summary\n$verdict\n";
    spit( "$t/rollout.sh", $body );
    my $out = `bash '$t/rollout.sh' 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'the deploy\'s check failed, the repair after it passed: serviceable' => sub {
    my ( $rc, $out ) = rollout( 'a.example' => [ 0, 0 ], 'b.example' => [ 5, 0 ] );
    like( $out, qr/^ROW b\.example updated \(repaired\)$/m, 'the site is updated, not NOT SERVICEABLE' )
        or diag $out;
    unlike( $out, qr/^NOT SERVICEABLE \(installed/m, 'and is not listed as NOT SERVICEABLE' );
    like( $out, qr/2 updated, 0 failed, 0 not serviceable/, 'counted as updated' );
    like( slurp("$t/findings"), qr/b\.example\tNOTE: the deploy's final check named a failure \(its output is above\) and the repair after it left none/,
        'with a finding saying so' );
    like( $out, qr/--- b\.example: FAILED \(status 5\), full output ---/, 'the deploy\'s failure is still shown in full' );
    is( $rc, 0, 'and the rollout exits 0' ) or diag $out;
};

subtest 'the repair could not fix it: still NOT SERVICEABLE' => sub {
    my ( $rc, $out ) = rollout( 'a.example' => [ 0, 0 ], 'b.example' => [ 5, 1 ] );
    like( $out, qr/^ROW b\.example NOT SERVICEABLE$/m, 'NOT SERVICEABLE' ) or diag $out;
    like( $out, qr/^NOT SERVICEABLE \(installed[^\n]*: b\.example$/m, 'listed by name' );
    like( $out, qr/1 updated, 0 failed, 1 not serviceable/, 'counted' );
    is( $rc, 2, 'exit 2: a human is needed' );
};

subtest 'a failed install is untouched by a clean repair' => sub {
    my ( $rc, $out ) = rollout( 'b.example' => [ 1, 0 ] );
    like( $out, qr/^ROW b\.example FAILED \(status 1\)$/m, 'still FAILED' ) or diag $out;
    is( $rc, 1, 'exit 1' );
};

done_testing();
