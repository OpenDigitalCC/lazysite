#!/usr/bin/perl
# lazysite-hestia-list.sh: Hestia-authoritative discovery of the lazysite
# sites on a host. A domain is a lazysite site when Hestia's own registry
# (users/<user>/web.conf) declares the lazysite-app web template; the install
# marker is unioned in as a cross-check, so template/marker mismatches are
# flagged instead of silently skipped. Driven here against a fabricated
# Hestia layout via the LAZYSITE_HESTIA_USERS / LAZYSITE_HOME_BASE overrides.
# Also: lazysite-hestia-update-all.sh discovers via this lister when present.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT   = repo_root();
my $LISTER = "$ROOT/installers/hestia/lazysite-hestia-list.sh";
ok( -f $LISTER, 'lazysite-hestia-list.sh ships in installers/hestia' );

# --- Fixture: fabricated Hestia host ----------------------------------------
# cafe: template + marker (channel beta). firm: template, SUSPENDED, never
# installed. plain: a non-lazysite domain. lost: marker but template changed.
my $R = tempdir( CLEANUP => 1 );
make_path("$R/hestia/users/agency");
make_path("$R/hestia/users/other");
make_path("$R/home/agency/web/cafe.example/public_html/lazysite");
make_path("$R/home/agency/web/firm.example/public_html/lazysite");
make_path("$R/home/other/web/plain.example/public_html");
make_path("$R/home/other/web/lost.example/public_html/lazysite");

sub _write {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $body;
    close $fh;
}

_write( "$R/hestia/users/agency/web.conf",
    "DOMAIN='cafe.example' IP='10.0.0.1' TPL='lazysite-app' SUSPENDED='no' TIME='0'\n"
        . "DOMAIN='firm.example' IP='10.0.0.1' TPL='lazysite-app' SUSPENDED='yes' TIME='0'\n" );
_write( "$R/hestia/users/other/web.conf",
    "DOMAIN='plain.example' IP='10.0.0.1' TPL='default' SUSPENDED='no' TIME='0'\n"
        . "DOMAIN='lost.example' IP='10.0.0.1' TPL='default' SUSPENDED='no' TIME='0'\n" );

_write( "$R/home/agency/web/cafe.example/public_html/lazysite/.install-state.json",
    '{"version":"0.7.13"}' );
_write( "$R/home/agency/web/cafe.example/public_html/lazysite/lazysite.conf",
    "update_channel: beta\n" );
_write( "$R/home/other/web/lost.example/public_html/lazysite/.install-state.json",
    '{"version":"0.7.11"}' );

sub run_lister {
    my (@args) = @_;
    local %ENV = %ENV;
    $ENV{LAZYSITE_HESTIA_USERS} = "$R/hestia/users";
    $ENV{LAZYSITE_HOME_BASE}    = "$R/home";
    my $cmd = join ' ', map { qq('$_') } ( $LISTER, @args );
    return scalar qx(bash $cmd 2>&1);
}

# --- human report ------------------------------------------------------------
{
    my $out = run_lister();
    like( $out, qr/lazysite sites on this host: 3/, 'counts the union (2 template + 1 marker-only)' );
    like( $out, qr/cafe\.example .*0\.7\.13 .*channel=beta/x, 'template+marker site: version and channel read' );
    like( $out, qr/firm\.example .*channel=all .*SUSPENDED\ NO-INSTALL-MARKER/x,
        'template-only site: suspended + never-installed flagged' );
    like( $out, qr/lost\.example .*0\.7\.11 .*NO-TEMPLATE/x,
        'marker-only site: template mismatch flagged, not silently skipped' );
    unlike( $out, qr/plain\.example/, 'a non-lazysite domain is excluded' );
}

# --- machine output (--plain) -------------------------------------------------
{
    my $out   = run_lister('--plain');
    my @lines = grep { length } split /\n/, $out;
    is( scalar @lines, 3, '--plain: one line per site, no header' );
    like( $lines[0], qr/^agency\tcafe\.example\t\Q$R\E\/home\/agency\/web\/cafe\.example\/public_html$/,
        '--plain: user<TAB>domain<TAB>docroot' );
    unlike( $out, qr/SUSPENDED|NO-/, '--plain: no flags (script-consumable)' );
}

# --- template-only: the template is the sole authority ------------------------
# The marker-only domain (lost.example) must NOT appear; only the two
# template-declared domains do. This is what a bulk update must discover so it
# never re-deploys over a domain moved off the lazysite-app template.
{
    my $out   = run_lister( '--plain', '--template-only' );
    my @lines = grep { length } split /\n/, $out;
    is( scalar @lines, 2, '--plain --template-only: template-declared sites only' );
    like( $out,   qr/cafe\.example/, 'template-only: template+marker site kept' );
    like( $out,   qr/firm\.example/, 'template-only: template-only site kept' );
    unlike( $out, qr/lost\.example/, 'template-only: marker-without-template domain dropped' );

    my $rep = run_lister('--template-only');
    like( $rep, qr/host: 2\s+\(template: \S+; template-declared only\)/,
        'template-only report: count + mode banner' );
    unlike( $rep, qr/lost\.example/, 'template-only report: excludes the marker-only domain' );
}

# --- update-all discovers template-authoritatively via the lister -------------
{
    open my $fh, '<', "$ROOT/installers/hestia/lazysite-hestia-update-all.sh" or die $!;
    my $ua = do { local $/; <$fh> };
    close $fh;
    like( $ua, qr/lazysite-hestia-list\.sh/, 'update-all references the lister' );
    like( $ua, qr/--plain --template-only/,
        'update-all discovers by template, not the marker union' );
    like( $ua, qr/EXCLUDED/,
        'update-all surfaces marker-only domains it deliberately skipped' );
    like( $ua, qr/for state in .*\.install-state\.json/,
        'update-all keeps the marker-glob fallback for an older STAGE' );
}

done_testing();
