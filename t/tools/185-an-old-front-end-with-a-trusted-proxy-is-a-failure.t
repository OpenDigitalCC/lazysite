#!/usr/bin/perl
# SM1194: a site that trusts its front end's X-Forwarded-For (trusted_proxies)
# behind a front end rendered BEFORE SM929 is a security failure, not a note.
#
# THE FIELD REPORT (test plan 0.15.10 results, F-6): "with trusted_proxies:
# 10.2.30.177 set on edge, a request sent with X-Forwarded-For: 192.0.2.55 is
# seen as 192.0.2.55" - every address-keyed control took the visitor's word.
# Edge's vhost was rendered from the template before SM929 (d93390469), which
# set no X-Forwarded-For, so nginx passed the client's header through. The
# rollout said only "1 site(s) render an older template".
#
# These are OUTCOME tests: the rollout's helpers are extracted from the script
# and run against fixture files; no Hestia command runs and no vhost is touched.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $ROOT = repo_root();
my $UPD  = "$ROOT/installers/hestia/lazysite-hestia-update-all.sh";
my $CHK  = "$ROOT/tools/lazysite-check.pl";
my $R    = site_tempdir();

sub spit { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

my $src   = slurp($UPD);
my @names = qw(lazysite_dir template_rev vhost_xff_state site_trusts_forwarded xff_exposure
    xff_reason record_xff_exposure xff_summary_line group_findings report_findings);
my %fn;
for my $n (@names) {
    ( $fn{$n} ) = $src =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}

sub run_bash {
    my ($body) = @_;
    spit( "$R/t.sh",
        "set -u\nHOME_BASE='$R/home'\nFINDINGS_FILE='$R/findings'\n: > \"\$FINDINGS_FILE\"\n"
            . join( '', map { $fn{$_} } @names ) . $body );
    return scalar qx(bash '$R/t.sh' 2>&1);
}

# One fixture site: its rendered nginx vhost and its lazysite.conf.
my $OLD = "# lazysite-template-rev: 2026-09-11\nserver {\n    location / {\n"
    . "        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host \$host;\n    }\n}\n";
my $PASS = $OLD =~ s/(proxy_set_header Host[^\n]*\n)/$1        proxy_set_header X-Forwarded-For \$http_x_forwarded_for;\n/r;
my $NEW  = "# lazysite-template-rev: 2026-10-01\nserver {\n    location / {\n"
    . "        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host \$host;\n"
    . "        # proxy_set_header X-Forwarded-For \$http_x_forwarded_for;\n"
    . "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n    }\n}\n";

sub site {
    my ( $d, $vhost, $conf ) = @_;
    make_path( "$R/home/u/conf/web/$d", "$R/home/u/web/$d/public_html/lazysite" );
    spit( "$R/home/u/conf/web/$d/nginx.ssl.conf", $vhost );
    spit( "$R/home/u/web/$d/public_html/lazysite/lazysite.conf", $conf );
    return "$R/home/u/web/$d/public_html";
}

my $TRUST = "site_name: T\ntrusted_proxies: 10.2.30.177\n";
my %doc = (
    'old-trust.example'  => site( 'old-trust.example',  $OLD,  $TRUST ),
    'pass-trust.example' => site( 'pass-trust.example', $PASS, $TRUST ),
    'old-plain.example'  => site( 'old-plain.example',  $OLD,  "site_name: T\n" ),
    'old-none.example'   => site( 'old-none.example',   $OLD,  "trusted_proxies: none\n" ),
    'new-trust.example'  => site( 'new-trust.example',  $NEW,  $TRUST ),
);

subtest 'a pre-SM929 rendering with trusted_proxies set is a FAILURE, with the reason' => sub {
    my $out = run_bash("xff_exposure u old-trust.example '$doc{'old-trust.example'}'\n");
    like( $out, qr/FAILURE/, 'a failure line' ) or diag $out;
    like( $out, qr/old-trust\.example/, 'naming the site' );
    like( $out, qr/passes the client's X-Forwarded-For through, so trusted_proxies lets any visitor choose their address/,
        'with the reason' );
    like( $out, qr/rebuild the vhost.*probe/s, 'and the fix: rebuild, then probe' );
};

subtest 'a rendering that passes the client header through is the same failure' => sub {
    like( run_bash("xff_exposure u pass-trust.example '$doc{'pass-trust.example'}'\n"),
        qr/FAILURE.*pass-trust\.example/s, 'set to $http_x_forwarded_for is not an append' );
};

subtest 'without trusted_proxies, or with none, nothing is a failure' => sub {
    is( run_bash("xff_exposure u old-plain.example '$doc{'old-plain.example'}'\n"), '', 'unset' );
    is( run_bash("xff_exposure u old-none.example '$doc{'old-none.example'}'\n"),   '', 'none' );
};

subtest 'a current rendering with trusted_proxies says nothing' => sub {
    is( run_bash("xff_exposure u new-trust.example '$doc{'new-trust.example'}'\n"), '',
        'the commented-out pass-through line does not count' );
};

subtest 'the findings and the summary carry it' => sub {
    my $out = run_bash(
        "record_xff_exposure u old-trust.example '$doc{'old-trust.example'}'\n"
            . "record_xff_exposure u new-trust.example '$doc{'new-trust.example'}'\n"
            . "report_findings\nxff_summary_line 1\n" );
    like( $out, qr/findings.*FAILURE.*passes the client's X-Forwarded-For through.*old-trust\.example/s,
        'a finding naming the site' ) or diag $out;
    unlike( $out, qr/new-trust\.example/, 'and not the safe one' );
    like( $out, qr/vhost:.*1 site\(s\).*FAILURE/, 'and a summary line counting it' );
};

subtest 'lazysite check warns whenever trusted_proxies is set, and says how to probe' => sub {
    my $doc = site_tempdir();
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
    spit( "$doc/lazysite/lazysite.conf", $TRUST );
    my $out = qx($^X \Q$CHK\E --docroot \Q$doc\E 2>&1);
    $out =~ s/\s+/ /g;
    like( $out, qr/trusted_proxies is only safe when the front end appends the client's address to X-Forwarded-For \(lazysite's templates since 0\.15\.2\/SM929\); probe it: a request with X-Forwarded-For: 192\.0\.2\.55 must not be seen as 192\.0\.2\.55/,
        'the warning' ) or diag $out;
    spit( "$doc/lazysite/lazysite.conf", "trusted_proxies: none\n" );
    $out = qx($^X \Q$CHK\E --docroot \Q$doc\E 2>&1);
    unlike( $out, qr/only safe when the front end appends/, 'not for none' );
};

done_testing;
