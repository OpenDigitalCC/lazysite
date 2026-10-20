#!/usr/bin/perl
# SM1205: install.pl's health check runs BEFORE the deploy's permission pass and
# `lazysite check --fix`, so its exit 4 is not the deploy's verdict. The deploy
# printed it as "WARN: ... (exit 4);" plus a second line; the batch updater's
# findings filter keeps lines that begin WARN, so every site whose FINAL check
# passed reported "[1] WARN: install.pl installed the release ... (exit 4);" - the
# first line only, ending in a semicolon - and the release manager went looking for
# a failure that was not there.
#
# The deploy's verdict is the final check's. Driven here through the scripts' own
# text with stand-ins, as t/tools/107 does.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root    = repo_root();
my $updater = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $deploy  = "$root/installers/hestia/lazysite-hestia-deploy.sh";

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f; chmod 0755, $p }

my $u         = slurp($updater);
my $d         = slurp($deploy);
my ($helpers) = $u =~ /(^TBL_FMT=.*?^run_quiet\(\) \{.*?^\}$)/ms;
my ($irc)     = $d =~ /(^if \[ "\$IRC" = 3 \]; then\n.*?^fi$)/ms;
my ($final) = $d =~ /(^set \+e\nperl "\$DOM\/tools\/lazysite-check\.pl" --docroot "\$DOC" --cgibin "\$CGI" --fix\n.*?\z)/ms;
ok( $helpers && $irc && $final, 'found in the scripts' ) or BAIL_OUT('the scripts changed shape');

my $dir = site_tempdir();
( my $t = $dir ) =~ s{/site/public_html\z}{};
spit( "$t/install.pl", "exit \$ENV{INSTALL_RC};\n" );
mkdir "$t/dom";
mkdir "$t/dom/tools";
spit( "$t/dom/tools/lazysite-check.pl", "print \"check ran\\n\"; exit \$ENV{CHECK_RC};\n" );
spit( "$t/deploy.sh", "#!/bin/bash\nset -e\nDOMAIN=\$2; DOM='$t/dom'; DOC=/nowhere; CGI=/nowhere\n"
        . "set +e\nperl '$t/install.pl'\nIRC=\$?\nset -e\n$irc\n$final\nexit 0\n" );

# The updater's run_quiet around the deploy, then its findings report.
sub quiet_run {
    my ( $install, $check ) = @_;
    spit( "$t/q.sh",
        "#!/bin/bash\nset -u\nVERBOSE=0\n$helpers\n"
            . "INSTALL_RC=$install CHECK_RC=$check run_quiet 'deploy a.example' bash '$t/deploy.sh' u a.example\n"
            . "echo \"rc=\$?\"\nreport_findings\n" );
    my $out = `bash '$t/q.sh' 2>&1`;
    return $out;
}

my $out = quiet_run( 4, 0 );
like( $out, qr/^rc=0$/m, 'install-time 4, final check passes: the deploy succeeds' );
unlike( $out, qr/findings/, 'and the findings report is empty: the interim check is not a finding' );
unlike( $out, qr/exit 4/, 'and nothing about exit 4 reaches the report' );

$out = quiet_run( 4, 1 );
like( $out, qr/^rc=5$/m, 'install-time 4, final check still fails: exit 5' );
like( $out, qr/NOT SERVICEABLE: a\.example/, 'and the report names that failure' );
like( $out, qr/exit 4\); the final check/, 'with the interim line whole, nothing cut to a first line' );

# The deploy's own output keeps a plain progress line, on one line.
my $v = `INSTALL_RC=4 CHECK_RC=0 bash '$t/deploy.sh' u a.example 2>&1`;
like( $v, qr/^==> install\.pl's own health check named a failure before the permission pass and the repair \(exit 4\);[^\n]*final check below decides$/m,
    'the deploy\'s own output says the install-time check failed before the repair, on one line' );
like( $v, qr/^==> the install-time health check failure was cleared by the permission pass and the repair/m,
    'and that the repair made it pass' );

# No message the deploy prints for the interim 4 begins with a level marker.
my ($block) = $d =~ /(elif \[ "\$IRC" = 4 \]; then.*?\nelif)/s;
my @echoes = $block =~ /^\s*echo "([^"]*)"/mg;
ok( scalar @echoes, 'the interim branch prints something' );
unlike( $_, qr/^\s*(WARN|WARNING|ERROR|FAIL|FAILED|CRITICAL|EXPOSED)\b/, "no level marker: $_" ) for @echoes;

done_testing();
