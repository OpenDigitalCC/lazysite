#!/usr/bin/perl
# SM1249 (#379 part 1): lazysite-hestia-list.sh lists the sites on EVERY
# lazysite template, not only lazysite-app.
#
# It defaulted to --tpl lazysite-app, so on a host whose sites use the other
# templates - lazysite-cgi / lazysite-fcgi with the lazysite-proxy nginx proxy
# template in front - it reported 0 sites. The batch updater, which deploys the
# tarball flow, keeps lazysite-app by asking for it.
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
my $R      = tempdir( CLEANUP => 1 );

sub spit { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }

make_path("$R/hestia/users/web1");
my %tpl = (
    'app.example'    => "TPL='lazysite-app' PROXY_TPL='default'",
    'cgi.example'    => "TPL='lazysite-cgi' PROXY_TPL='lazysite-proxy'",
    'fcgi.example'   => "TPL='lazysite-fcgi' PROXY_TPL='lazysite-proxy'",
    'old.example'    => "TPL='lazysite' PROXY_TPL='default'",
    'proxy.example'  => "TPL='default' PROXY_TPL='lazysite-proxy'",
    'plain.example'  => "TPL='default' PROXY_TPL='default'",
);
spit( "$R/hestia/users/web1/web.conf",
    join '', map {"DOMAIN='$_' IP='10.0.0.1' $tpl{$_} SUSPENDED='no' TIME='0'\n"} sort keys %tpl );
make_path("$R/home/web1/web/$_/public_html") for keys %tpl;

sub run_lister {
    my (@args) = @_;
    local $ENV{LAZYSITE_HESTIA_USERS} = "$R/hestia/users";
    local $ENV{LAZYSITE_HOME_BASE}    = "$R/home";
    my $cmd = join ' ', map {qq('$_')} ( $LISTER, @args );
    return scalar qx(bash $cmd 2>&1);
}

subtest 'every lazysite template is a lazysite site' => sub {
    my $out = run_lister( '--plain', '--template-only' );
    my @d = sort map { ( split /\t/ )[1] } grep {length} split /\n/, $out;
    is_deeply( \@d, [qw(app.example cgi.example fcgi.example old.example proxy.example)],
        'lazysite-app, -cgi, -fcgi, the older lazysite, and lazysite-proxy in front of a stock web template' )
        or diag $out;
};

subtest 'the report names the template' => sub {
    my $out = run_lister();
    like( $out, qr/lazysite sites on this host: 5 /, 'five, not one' ) or diag $out;
    like( $out, qr/cgi\.example .*tpl=lazysite-cgi/, 'with its web template' );
    unlike( $out, qr/plain\.example/, 'and a stock domain is not one' );
};

subtest '--tpl narrows to one, as a web or a proxy template' => sub {
    my @app = grep {length} split /\n/, run_lister( '--plain', '--template-only', '--tpl', 'lazysite-app' );
    is( scalar @app, 1, '--tpl lazysite-app: the one site on it' );
    like( $app[0] // '', qr/\tapp\.example\t/, 'app.example' );
    my $p = run_lister( '--plain', '--template-only', '--tpl', 'lazysite-proxy' );
    my @p = sort map { ( split /\t/ )[1] } grep {length} split /\n/, $p;
    is_deeply( \@p, [qw(cgi.example fcgi.example proxy.example)], '--tpl lazysite-proxy: the proxy template' );
};

subtest 'the updater keeps the tarball flow\'s scope' => sub {
    open my $fh, '<', "$ROOT/installers/hestia/lazysite-hestia-update-all.sh" or die $!;
    my $ua = do { local $/; <$fh> };
    like( $ua, qr/bash "\$LISTER" --plain --template-only --tpl lazysite-app\)/,
        'it deploys only lazysite-app domains, as it always has' );
};

done_testing();
