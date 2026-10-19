#!/usr/bin/perl
# SM1196: Hestia's installed copy of lazysite's templates follows the release.
#
# THE FIELD REPORT (edge, 2026-10-19, F-6 re-test in inbox/2026-10-19-test-plan-
# 01510-results.md): after `v-rebuild-web-domain` the vhost still passed the
# client's X-Forwarded-For through, and
#   grep -n "X-Forwarded-For" /usr/local/hestia/data/templates/web/nginx/lazysite-proxy.*tpl
# found NO match: Hestia's installed copy predates SM929 (0.15.2), so every
# rebuild re-rendered the old one. The copy is a one-off manual step; upgrades
# refresh /usr/share/lazysite-hestia/templates and nothing refreshed Hestia's.
#
# OUTCOME tests on fixture directories: the updater's helpers are extracted and
# run against a fabricated template tree; no Hestia command runs and no real
# Hestia directory is read or written.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $ROOT = repo_root();
my $UPD  = "$ROOT/installers/hestia/lazysite-hestia-update-all.sh";
my $DOM  = "$ROOT/tools/lazysite-hestia-domain.pl";
my $R    = site_tempdir();

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

my $src   = slurp($UPD);
my @names = qw(in_list refresh_template domain_uses_template domains_on_template);
my %fn;
for my $n (@names) {
    ( $fn{$n} ) = $n eq 'in_list' ? $src =~ /^(in_list\(\) \{[^\n]*\n)/m : $src =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}

# The release's copy (proxy sets X-Forwarded-For from the peer) and Hestia's old
# installed copy (SM929 absent).
my $NEWPROXY = "# lazysite-template-rev: 2026-10-01\nproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n";
my $OLDPROXY = "# lazysite-template-rev: 2026-09-11\nproxy_pass http://127.0.0.1:8080;\n";

my ( $n, $fresh ) = ( 0, undef );

# A fresh fixture host per case: release dir, Hestia web + nginx template dirs,
# Hestia's per-user registry.
sub host {
    my (%o) = @_;
    my $h = "$R/h" . ++$n;
    make_path( "$h/rel", "$h/apache2/php-fpm", "$h/nginx", "$h/users/u1" );
    spit( "$h/rel/lazysite-proxy.tpl",  $NEWPROXY );
    spit( "$h/rel/lazysite-proxy.stpl", $NEWPROXY );
    spit( "$h/rel/lazysite-cgi.tpl",    "# lazysite-template-rev: 2026-10-01\ncgi new\n" );
    spit( "$h/rel/lazysite-cgi.stpl",   "# lazysite-template-rev: 2026-10-01\ncgi new\n" );
    spit( "$h/nginx/lazysite-proxy.tpl",  $o{proxy} // $OLDPROXY );
    spit( "$h/nginx/lazysite-proxy.stpl", $o{proxy} // $OLDPROXY );
    spit( "$h/users/u1/web.conf",
        "DOMAIN='old.example' IP='10.0.0.1' TPL='lazysite-app' PROXY_TPL='lazysite-proxy' SUSPENDED='no'\n"
            . "DOMAIN='plain.example' IP='10.0.0.1' TPL='default' PROXY_TPL='default' SUSPENDED='no'\n"
            . "DOMAIN='cgi.example' IP='10.0.0.1' TPL='lazysite-cgi' PROXY_TPL='default' SUSPENDED='no'\n" );
    return $h;
}

sub run_bash {
    my ( $h, $body ) = @_;
    spit( "$h/t.sh",
        "set -u\nshopt -s nullglob\nTPL_SRC='$h/rel'\nTPL_STAMP=20261019120000\nTPL_NEW=0\nTPL_FAILURES=0\nTPL_CHANGED=()\n"
            . "USERS_DIR='$h/users'\n"
            . join( '', map { $fn{$_} } @names ) . $body );
    return scalar qx(bash '$h/t.sh' 2>&1);
}

subtest 'an installed proxy template without the X-Forwarded-For line is refreshed, backup kept, reported' => sub {
    my $h   = host();
    my $out = run_bash( $h,
        "refresh_template '$h/nginx' lazysite-proxy tpl stpl\n"
            . "echo \"failures=\$TPL_FAILURES changed=\${TPL_CHANGED[*]:-}\"\n" );
    unlike( slurp("$h/nginx/lazysite-proxy.tpl"), qr/\A\Q$OLDPROXY\E\z/, 'the old copy is gone' );
    is( slurp("$h/nginx/lazysite-proxy.tpl"),  $NEWPROXY, '.tpl is the release copy' );
    is( slurp("$h/nginx/lazysite-proxy.stpl"), $NEWPROXY, '.stpl is the release copy' );
    like( slurp("$h/nginx/lazysite-proxy.tpl"), qr/X-Forwarded-For/, 'and it sets X-Forwarded-For' );
    my @bak = glob("$h/nginx/lazysite-proxy.tpl.*");
    is( scalar @bak, 1, 'one backup of the old .tpl beside it' ) or diag $out;
    is( slurp( $bak[0] ), $OLDPROXY, 'holding the old content' ) if @bak;
    unlike( $bak[0] // '', qr/\.s?tpl\z/, 'named so Hestia does not offer it as a template' );
    my @offered = grep { /\.s?tpl\z/ } map { s{.*/}{}r } glob("$h/nginx/*");
    is_deeply( [ sort @offered ], [qw(lazysite-proxy.stpl lazysite-proxy.tpl)], 'Hestia sees only the two templates' );
    like( $out, qr/refreshed.*lazysite-proxy\.tpl/, 'reported' ) or diag $out;
    like( $out, qr/failures=0 changed=lazysite-proxy/, 'recorded as changed, no failure' ) or diag $out;
};

subtest 'an identical copy is left untouched and nothing is reported' => sub {
    my $h   = host( proxy => $NEWPROXY );
    my $out = run_bash( $h,
        "refresh_template '$h/nginx' lazysite-proxy tpl stpl\n"
            . "echo \"failures=\$TPL_FAILURES changed=\${TPL_CHANGED[*]:-}\"\n" );
    is( $out, "failures=0 changed=\n", 'no report' ) or diag $out;
    is( scalar( () = glob("$h/nginx/*") ), 2, 'no backup made' );
};

subtest 'a template that is not installed is left alone unless installing was asked for' => sub {
    my $h = host();
    unlink glob("$h/apache2/php-fpm/*");
    my $out = run_bash( $h, "refresh_template '$h/apache2/php-fpm' lazysite-cgi tpl stpl\necho done\n" );
    is( $out, "done\n", 'nothing reported' ) or diag $out;
    ok( !-e "$h/apache2/php-fpm/lazysite-cgi.tpl", 'and nothing installed' );
    $out = run_bash( $h, "TPL_NEW=1\nrefresh_template '$h/apache2/php-fpm' lazysite-cgi tpl stpl\n" );
    ok( -e "$h/apache2/php-fpm/lazysite-cgi.tpl", 'installed when asked (--templates)' );
};

subtest 'a refresh that cannot write is a FAILURE line and is counted' => sub {
    plan skip_all => 'root can write anywhere' if $> == 0;
    my $h = host();
    chmod 0555, "$h/nginx";
    my $out = run_bash( $h,
        "refresh_template '$h/nginx' lazysite-proxy tpl stpl\necho \"failures=\$TPL_FAILURES changed=\${TPL_CHANGED[*]:-}\"\n" );
    chmod 0755, "$h/nginx";
    like( $out, qr/FAILURE: .*lazysite-proxy\.tpl/, 'a FAILURE line naming the file' ) or diag $out;
    like( $out, qr/failures=[1-9]/, 'counted for the exit status' );
    unlike( $out, qr/changed=\S/, 'not recorded as refreshed' );
    is( slurp("$h/nginx/lazysite-proxy.tpl"), $OLDPROXY, 'the old copy is unchanged' );
};

subtest 'the domains using a refreshed template are found, from Hestia\'s own registry' => sub {
    my $h   = host();
    my $out = run_bash( $h, "domains_on_template lazysite-proxy\necho --\ndomains_on_template lazysite-cgi\n" );
    like( $out, qr/\Au1\/old\.example\n--\nu1\/cgi\.example\n\z/, 'proxy: old; web: cgi; the default-template domain never' ) or diag $out;
};

subtest 'the order is refresh, then rebuild, then the rendered-file check' => sub {
    my $call    = index( $src, "refresh_template \"\$PROXYTPLDIR\"" );
    my $rebuild = index( $src, 'v-rebuild-web-domain" "$u" "$d"' );
    my $check   = index( $src, "\n    record_xff_exposure \"\${USERS[\$i]}\"" );
    ok( $call > 0 && $rebuild > 0 && $check > 0, 'all three steps are in the script' );
    ok( $call < $rebuild && $rebuild < $check, 'in that order' );
    like( $src, qr/TPL_FAILURES:-0\}" -gt 0 \]/, 'a failed refresh fails the rollout' );
};

# --- the domain tool's hint ---------------------------------------------------
{
    my @subs;
    for my $s (qw(template_hint proxy_template_hint template_state)) {
        my ($body) = slurp($DOM) =~ /^(sub \Q$s\E \{\n.*?^\})/ms;
        push @subs, $body if $body;
    }

    sub hint {
        my ( $h, $call ) = @_;
        my $code = "use strict; use warnings; no warnings 'redefine'; use File::Compare ();\n"
            . "my \$TPL_BASE = '$h'; my \$TPL_SRC_DIR = '$h/rel';\n"
            . join( "\n", @subs ) . "\n$call;\n1;";
        my $out = '';
        {
            open my $fh, '>', \$out or die;
            local *STDOUT = $fh;
            eval $code or $out .= "ERR: $@";
        }
        return $out;
    }

    subtest 'the domain tool names a STALE proxy template, not only a missing one' => sub {
        my $h = host();
        make_path("$h/nginx");
        my $o = hint( $h, 'proxy_template_hint()' );
        like( $o, qr/STALE|differs from this release/i, 'stale named' ) or diag $o;
        like( $o, qr{cp /usr/share/lazysite-hestia/templates/lazysite-proxy\.\* }, 'with the copy command' );
        like( $o, qr/rebuild/, 'and the rebuild' );
        my $c = host( proxy => $NEWPROXY );
        is( hint( $c, 'proxy_template_hint()' ), '', 'a current copy says nothing' );
        my $m = host();
        unlink glob("$m/nginx/*");
        like( hint( $m, 'proxy_template_hint()' ), qr/not installed/, 'a missing one is still named' );
    };

    subtest 'and a STALE web template' => sub {
        my $h = host();
        spit( "$h/apache2/php-fpm/lazysite-cgi.tpl",  "# old\n" );
        spit( "$h/apache2/php-fpm/lazysite-cgi.stpl", "# lazysite-template-rev: 2026-10-01\ncgi new\n" );
        my $o = hint( $h, "template_hint('lazysite-cgi')" );
        like( $o, qr/STALE|differs from this release/i, 'stale named (one of the pair differs)' ) or diag $o;
        like( $o, qr{cp /usr/share/lazysite-hestia/templates/lazysite-cgi\.\* }, 'with the copy command' );
    };
}

done_testing;
