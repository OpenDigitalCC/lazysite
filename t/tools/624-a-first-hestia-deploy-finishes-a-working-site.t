#!/usr/bin/perl
#
# n807 / SM1427: A NEW HESTIA SITE IS ONE COMMAND, THE FIRST OPERATOR INCLUDED.
#
# The release manager (2026-11-10, a new site on a Hestia host, tarball 0.16.9) found
# the install "very fiddly - one step rather than chained to set first user": the
# registry line written by hand, a claim link with no host, a proxy template to apply
# separately, and a runbook naming a template a tarball host does not have.
# `lazysite-hestia-deploy.sh USER DOMAIN [STAGE_DIR] [--sysop NAME] [--channel C]`
# now finishes all of it.
#
# The script is root and drives Hestia, so this holds it two ways without either:
#   - the arguments are run through the real script (they are read before anything
#     else, so a refusal needs no root and no Hestia);
#   - the functions the first-time deploy calls are sourced from between the script's
#     own markers and run against stubs: a v-* command that logs its arguments, a sudo
#     that drops `-u USER`, and a registry directory under a temp dir. install.pl and
#     lazysite-users.pl run FOR REAL against a temp site.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

plan skip_all => 'running as root - the tools drop or refuse' if $> == 0;

my $root   = repo_root();
my $deploy = "$root/installers/hestia/lazysite-hestia-deploy.sh";
plan skip_all => 'the Hestia deploy is not here' unless -f $deploy;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }
sub spit  { my ( $p, $b, $m ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; chmod $m // 0644, $p; return }

# --- the arguments, through the real script ---------------------------------
sub deploy { my $o = qx(bash \Q$deploy\E @_ 2>&1); return ( $? >> 8, $o ) }
{
    my ( $rc, $out ) = deploy('');
    is( $rc, 2, 'no arguments: a usage refusal' );
    like( $out, qr/usage: .*USER DOMAIN \[STAGE_DIR\] \[--sysop NAME\] \[--channel /, 'the usage line shows --sysop and --channel' )
        or diag $out;
    ( $rc, $out ) = deploy('u d --channel bogus');
    is( $rc, 2, 'an unknown channel is refused before anything is touched' );
    like( $out, qr/--channel must be edge, beta, stable or certified/, 'and says what it takes' );
    ( $rc, $out ) = deploy('u d --sysop');
    is( $rc, 2, '--sysop with no name is refused' );
    ( $rc, $out ) = deploy("u d --sysop 'a b'");
    is( $rc, 2, 'a name the users tool would refuse is refused first' );
    ( $rc, $out ) = deploy('u d --nonsense');
    is( $rc, 2, 'an unknown option is refused' );
    like( $out, qr/unknown option '--nonsense'/, 'by name' );
    ( $rc, $out ) = deploy('u d --sysop sjm --channel stable');
    unlike( $out, qr/usage:|unknown option/, 'and the run goes on to its root check, not a usage refusal' );
    like( $out, qr/must run as root/, 'which is the next thing it asks' );
}

# --- the functions, against stubs --------------------------------------------
my $T = Cwd::realpath( tempdir( CLEANUP => 1 ) );
my $block = slurp($deploy);
$block =~ /^# n807: functions begin.*?\n(.*?)^# n807: functions end\n/ms or BAIL_OUT('the deploy lost its n807 function block');
spit( "$T/functions.sh", $1 );

make_path("$T/bin");
spit( "$T/bin/sudo", "#!/bin/bash\n[ \"\$1\" = -u ] && shift 2\nexec \"\$@\"\n", 0755 );

# A fake Hestia: the v-* command logs its arguments; the template is there or not.
sub hestia {
    my ($with_proxy) = @_;
    my $h = "$T/hestia" . ( $with_proxy ? 'P' : 'N' );
    make_path( "$h/bin", "$h/data/templates/web/nginx" );
    spit( "$h/bin/v-change-web-domain-proxy-tpl", "#!/bin/bash\necho \"proxy-tpl \$*\" >> '$T/calls.log'\n", 0755 );
    spit( "$h/data/templates/web/nginx/lazysite-proxy.tpl", "x\n" ) if $with_proxy;
    return $h;
}

# A site under a Hestia-shaped path, with the engine's tools beside it.
sub site {
    my ($name, $conf) = @_;
    my $dom = "$T/$name";
    make_path( "$dom/public_html/lazysite/auth", "$dom/public_html/lazysite/logs", "$dom/cgi-bin" );
    symlink "$root/tools", "$dom/tools";
    spit( "$dom/public_html/lazysite/lazysite.conf", $conf );
    return $dom;
}

sub run_fns {
    my ( $dom, $cmds, %env ) = @_;
    spit( "$T/harness.sh", "set -e\nsource '$T/functions.sh'\neval \"\$1\"\n" );
    local $ENV{PATH}                  = "$T/bin:$ENV{PATH}";
    local $ENV{U}                     = 'siteuser';
    local $ENV{DOMAIN}                = 'example.test';
    local $ENV{DOM}                   = $dom;
    local $ENV{DOC}                   = "$dom/public_html";
    local $ENV{CGI}                   = "$dom/cgi-bin";
    local $ENV{LZ}                    = "$dom/public_html/lazysite";
    local $ENV{STAGE}                 = $root;
    local $ENV{HESTIA}                = $env{hestia} // hestia(1);
    local $ENV{LZS_CLI}               = 'lazysite';
    local $ENV{CHANNEL}               = $env{channel} // '';
    local $ENV{SYSOP}                 = $env{sysop} // '';
    local $ENV{STAGE_ARG}             = '';
    local $ENV{LAZYSITE_REGISTRY_DIR} = "$T/registry";
    my $out = qx(bash '$T/harness.sh' \Q$cmds\E 2>&1);
    return ( $? >> 8, $out );
}

subtest 'the proxy template is applied when Hestia has it, and named when it does not' => sub {
    unlink "$T/calls.log";
    my ( $rc, $out ) = run_fns( site( 'p1', "site_name: T\n" ), 'apply_proxy_template', hestia => hestia(1) );
    is( $rc, 0, 'applies' ) or diag $out;
    like( slurp("$T/calls.log"), qr/^proxy-tpl siteuser example\.test lazysite-proxy$/m, 'through v-change-web-domain-proxy-tpl, with the lazysite-proxy template' );

    unlink "$T/calls.log";
    ( $rc, $out ) = run_fns( site( 'p2', "site_name: T\n" ), 'apply_proxy_template', hestia => hestia(0) );
    is( $rc, 0, 'a Hestia without the template is not a failure' ) or diag $out;
    ok( !-e "$T/calls.log", 'and nothing is applied' );
    like( $out, qr/lazysite-proxy is not installed in Hestia/, 'it says so' );
    like( $out, qr{cp \Q$root\E/installers/hestia/lazysite-proxy\.tpl \S+lazysite-proxy\.stpl \S+/data/templates/web/nginx/},
        'and names the command that copies it' );
};

subtest 'site_url becomes absolute through install.pl, and an absolute one is left alone' => sub {
    my $dom = site( 's1', "site_name: T\nsite_url: \${REQUEST_SCHEME}://\${SERVER_NAME}\n" );
    my ( $rc, $out ) = run_fns( $dom, 'set_site_url' );
    is( $rc, 0, 'runs' ) or diag $out;
    like( slurp("$dom/public_html/lazysite/lazysite.conf"), qr{^site_url: https://example\.test$}m, 'the template is replaced by https://DOMAIN' );

    $dom = site( 's2', "site_name: T\nsite_url: https://chosen.example\n" );
    ( $rc, $out ) = run_fns( $dom, 'set_site_url' );
    like( slurp("$dom/public_html/lazysite/lazysite.conf"), qr{^site_url: https://chosen\.example$}m, 'an absolute site_url is not touched' );
    like( $out, qr/already https:\/\/chosen\.example/, 'and the run says so' );

    $dom = site( 's3', "site_name: T\n" );
    ( $rc, $out ) = run_fns( $dom, 'set_site_url' );
    like( slurp("$dom/public_html/lazysite/lazysite.conf"), qr{^site_url: https://example\.test$}m, 'no site_url at all: set' );

    for my $bad ( 'https://${SERVER_NAME}', 'https://x.test/path', 'ftp://x.test', 'x.test' ) {
        my $o = qx($^X \Q$root\E/install.pl --site-url '$bad' --docroot \Q$dom/public_html\E 2>&1);
        is( $? >> 8, 2, "install.pl --site-url refuses '$bad'" ) or diag $o;
    }
};

subtest 'the registry entry is the CLI format, written once' => sub {
    my $dom = site( 'r1', "site_name: T\n" );
    my ( $rc, $out ) = run_fns( $dom, 'write_registry', channel => 'stable' );
    is( $rc, 0, 'runs' ) or diag $out;
    my $body = slurp("$T/registry/example.test");
    is( $body, "docroot=$dom/public_html\ncgibin=$dom/cgi-bin\nowner=siteuser\nchannel=stable\npolicy=manual\n",
        'docroot, cgibin, owner, channel and policy=manual' );

    # In the order and with the keys the CLI's own writer uses.
    my ($keys) = slurp("$root/tools/lazysite-cli.pl") =~ /qw\((docroot cgibin owner channel policy)\);/;
    is( join( ' ', map { /^(\w+)=/ ? $1 : () } split /\n/, $body ), $keys, 'in the CLI registry_record\'s order' );

    spit( "$T/registry/example.test", "docroot=/elsewhere\n" );
    ( $rc, $out ) = run_fns( $dom, 'write_registry' );
    is( slurp("$T/registry/example.test"), "docroot=/elsewhere\n", 'an existing entry is never overwritten' );

    unlink "$T/registry/example.test";
    ( $rc, $out ) = run_fns( $dom, 'write_registry' );
    like( slurp("$T/registry/example.test"), qr/^channel=edge$/m, 'the channel defaults to edge' );
};

subtest '--sysop: the claim link is a full URL, and a site with accounts is told' => sub {
    # No site_url in the conf: the tool prints a path only, the script makes it whole.
    my $dom = site( 'o1', "site_name: T\n" );
    my ( $rc, $out ) = run_fns( $dom, 'run_setup_sysop; print_summary', sysop => 'sjm' );
    is( $rc, 0, 'setup-sysop ran as the site user and the function returned' ) or diag $out;
    like( $out, qr{^    claim:     https://example\.test/claim\?u=sjm&c=\w+$}m, 'the summary holds the claim link as a full https://DOMAIN/claim?... URL' )
        or diag $out;
    unlike( $out, qr/no operator yet/, 'with no stray "no operator" notice' );
    like( $out, qr{^    site:      https://example\.test/$}m,           'the summary names the site' );
    like( $out, qr{^    manager:   https://example\.test/manager/$}m,    'the manager' );
    like( $out, qr{lazysite-proxy\.\*tpl},                              'and the trusted_proxies probe' );

    ( $rc, $out ) = run_fns( $dom, 'run_setup_sysop', sysop => 'other' );
    like( $out, qr/this site already has accounts\. setup-sysop makes 'other' an operator here too/, 'a second run on a site with accounts says what setup-sysop does there' )
        or diag $out;

    ( $rc, $out ) = run_fns( site( 'o2', "site_name: T\n" ), 'print_summary', hestia => hestia(1) );
    like( $out, qr/claim:     none - no sysop yet; rerun with:  \S+ siteuser example\.test --sysop NAME/, 'without --sysop the summary gives the one-line rerun' )
        or diag $out;
};

# --- where the script calls them ---------------------------------------------
subtest 'the script calls them in an order that finishes a site' => sub {
    my $d = slurp($deploy);
    my $at = sub { my $i = index( $d, $_[0], $_[1] // 0 ); $i };
    my $app   = $at->('v-change-web-domain-tpl" "$U" "$DOMAIN" lazysite-app yes');
    my $proxy = $at->( 'apply_proxy_template', $app );
    cmp_ok( $proxy, '>', $app, 'the proxy template follows lazysite-app, inside its first-time branch' );
    cmp_ok( $at->('elif'), '>', 0, 'the first-time branch has an else (an upgrade leaves the template alone)' );
    like( $d, qr{if \[ "\$MODE" = provision \]; then\s+set_site_url\s+set_site_channel\s+write_registry\s+fi\s+echo "==> permissions}s,
        'site_url, channel and registry are first-time only, before the permission pass' );
    my $check = $at->('NOT SERVICEABLE');
    my $sysop = $at->( 'run_setup_sysop || SYSOP_RC=1', $check );
    my $sum   = $at->( 'print_summary', $sysop );
    ok( $check > 0 && $sysop > $check && $sum > $sysop, 'setup-sysop runs after the health check (which exits 5 on a failure), then the summary' );
    like( $d, qr{if \[ ! -f "\$LZ/auth/groups-settings.json" \] && \[ -z "\$SYSOP" \]}, 'today\'s no-accounts message is for a deploy without --sysop' );
    like( $d, qr{sudo -u "\$U" perl "\$DOM/tools/lazysite-users.pl" --docroot "\$DOC" setup-sysop --user "\$SYSOP"}, 'and setup-sysop runs as the site user' );
};

done_testing();
