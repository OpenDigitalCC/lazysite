#!/usr/bin/perl
# N13-41..43: the Hestia rollout reports where each site's engine tree is,
# whether its vhost carries this release's template, and what lazysite check
# says - and the scripts behind it find a moved engine tree.
#
# THE OPERATOR'S ASK: the three things to confirm before promoting a release -
# is any site migrated, is each site clean, does each vhost need a rebuild - are
# answered in the table the deploy already prints, not by commands run by hand.
#
# WHAT BUILDING IT FOUND (SM850, the shell half): the Hestia scripts built
# <docroot>/lazysite by hand. On a site whose engine tree moved to
# <docroot>-lazysite (SM293) the lister read its version as "-", its channel as
# the default and its install marker as missing; the updater's table showed "?"
# and "(unset)"; and the per-site deploy took it for a FIRST-TIME install on
# every upgrade - re-applying the Hestia template, rebuilding the vhost and
# re-running the manager's first-run setup - while its permission sweep and
# secret lockdown touched a directory that was not there.
#
# Reproduced before the change: every assertion on the migrated site failed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT    = repo_root();
my $LISTER  = "$ROOT/installers/hestia/lazysite-hestia-list.sh";
my $UPDATER = "$ROOT/installers/hestia/lazysite-hestia-update-all.sh";
my $DEPLOY  = "$ROOT/installers/hestia/lazysite-hestia-deploy.sh";
my $R       = tempdir( CLEANUP => 1 );

sub spit { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

# --- the lister, end to end ---------------------------------------------------
make_path("$R/hestia/users/agency");
spit( "$R/hestia/users/agency/web.conf",
    join '', map { "DOMAIN='$_' IP='10.0.0.1' TPL='lazysite-app' SUSPENDED='no' TIME='0'\n" }
        qw(inside.example moved.example both.example) );
for my $d (qw(inside.example moved.example both.example)) {
    make_path("$R/home/agency/web/$d/public_html");
}
my %tree = (
    'inside.example' => ['public_html/lazysite'],
    'moved.example'  => ['public_html-lazysite'],
    'both.example'   => [ 'public_html/lazysite', 'public_html-lazysite' ],
);
for my $d ( sort keys %tree ) {
    for my $t ( @{ $tree{$d} } ) {
        my $lz = "$R/home/agency/web/$d/$t";
        make_path("$lz/auth");
        spit( "$lz/.install-state.json", '{"version":"0.13.12"}' );
        spit( "$lz/lazysite.conf",       "update_channel: beta\n" );
    }
}

my $list = do {
    local %ENV = %ENV;
    @ENV{qw(LAZYSITE_HESTIA_USERS LAZYSITE_HOME_BASE)} = ( "$R/hestia/users", "$R/home" );
    scalar qx(bash '$LISTER' 2>&1);
};
my ($moved) = $list =~ /^(\s*moved\.example\b.*)$/m;
ok( $moved, 'the lister lists the migrated site' ) or diag $list;
like( $moved // '', qr/0\.13\.12/,    'with its version, read from the moved tree' );
like( $moved // '', qr/channel=beta/, 'and its channel' );
unlike( $moved // '', qr/NO-INSTALL-MARKER/, 'and its install marker is found where it now lives' );
like( $moved // '', qr/engine=outside/, 'and it is flagged as migrated' );
like( $list, qr/^\s*both\.example\b.*ENGINE-IN-BOTH-PLACES/m, 'a tree in both places is the fault it is' );
unlike( ( $list =~ /^(\s*inside\.example\b.*)$/m )[0] // '', qr/engine=/,
    'and an ordinary site says nothing about it' );

# --- the updater's helpers, driven ------------------------------------------
my $src   = slurp($UPDATER);
my @names = qw(lazysite_dir engine_state template_rev vhost_state check_verdict);
my %fn;
for my $n (@names) {
    ( $fn{$n} ) = $src =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" );
}

sub run_bash {
    my ($body) = @_;
    my $f = "$R/t.sh";
    spit( $f, "set -u\nHOME_BASE='$R/home'\n" . join( '', map { $fn{$_} // '' } @names ) . $body );
    return scalar qx(bash '$f' 2>&1);
}

subtest 'ENGINE: where each tree is' => sub {
    my $out = run_bash( join '', map { "engine_state '$R/home/agency/web/$_/public_html'\n" }
            qw(inside.example moved.example both.example nosuch.example) );
    is_deeply( [ split /\n/, $out ], [qw(inside outside BOTH none)], 'inside, outside, BOTH, none' );
};

subtest 'VHOST: does the rendered vhost carry this release\'s template' => sub {
    my $conf = "$R/home/agency/conf/web";
    make_path( "$conf/current.example", "$conf/old.example", "$conf/stock-proxy.example" );
    spit( "$conf/current.example/apache2.ssl.conf", "# lazysite-template-rev: 2026-09-11\n<VirtualHost>\n" );
    spit( "$conf/current.example/nginx.ssl.conf", "# lazysite-template-rev: 2026-09-11\nserver {}\n" );
    spit( "$conf/old.example/apache2.ssl.conf",         "<VirtualHost>\n" );
    spit( "$conf/stock-proxy.example/apache2.ssl.conf", "# lazysite-template-rev: 2026-09-11\n" );
    spit( "$conf/stock-proxy.example/nginx.ssl.conf", "server { # hestia default }\n" );
    my $out = run_bash( join '', map { "vhost_state agency $_ 2026-09-11\n" }
            qw(current.example old.example stock-proxy.example unrendered.example) );
    is_deeply( [ split /\n/, $out ], [ 'current', 'rebuild', 'current', '-' ],
        'current, rebuild (rendered before the marker), a stock proxy not held against it, none rendered' );
};

subtest 'CHECK: lazysite check, as a verdict' => sub {
    my %cases = (
        "40 ok, 0 warning(s), 0 failure(s)"           => 'clean',
        "38 ok, 2 warning(s), 0 failure(s)  (re-run)" => '2 warn',
        "37 ok, 2 warning(s), 1 failure(s)"           => '1 FAIL, 2 warn',
        "no summary at all"                           => '?',
    );
    for my $line ( sort keys %cases ) {
        spit( "$R/cli.pl", "print qq{lazysite-check\\n[ ok ] x\\n\\n$line\\n};\n" );
        my $out = run_bash("LZS='$R/cli.pl'\ncheck_verdict some.example\n");
        chomp $out;
        is( $out, $cases{$line}, "'$line' reads as '$cases{$line}'" );
    }
};

# --- the per-site deploy and the table, wired -------------------------------
my $dep = slurp($DEPLOY);
like( $dep, qr/^STATE_FILE="\$LZ\/\.install-state\.json"$/m,
    'the deploy looks for the install marker in the engine tree, wherever it is' )
    or diag( 'Otherwise every upgrade of a migrated site is a first-time install: the '
        . 'Hestia template re-applied and the vhost rebuilt, every time.' );
like( $dep, qr/^if \[ ! -f "\$LZ\/auth\/groups-settings\.json" \]; then$/m,
    'and the first-run setup runs once, not on every deploy of a migrated site' );
like( $dep, qr/\[ -f "\$LZ\/\$sec" \] && chmod 660 "\$LZ\/\$sec"/, 'the secrets are locked where they are' );
like( $dep, qr/if \[ "\$LZ" = "\$DOC-lazysite" \]; then\n\s*chown -RP/, 'and a moved tree is swept like the docroot' );

like( $src, qr/table_head\(\) \{ printf "\$TBL_FMT" DOMAIN USER VERSION CHANNEL ENGINE VHOST SCOPE; \}/,
    'the first table carries ENGINE and VHOST' );
like( $src, qr/sum_head\(\) \{ printf "\$SUM_FMT" DOMAIN FROM TO CHECK VHOST RESULT; \}/,
    'and the summary CHECK and VHOST' );

done_testing();
