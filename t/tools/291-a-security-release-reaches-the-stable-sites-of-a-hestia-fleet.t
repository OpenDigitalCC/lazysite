#!/usr/bin/perl
# SM1307 (ruling 41b): A SECURITY RELEASE REACHES THE STABLE SITES OF A HESTIA FLEET.
#
# 0.16.2 is cut marked security_critical so that it reaches every site, stable
# ones included. The CLI's `upgrade --all --force-security` does that for the
# sites in the registry - and a Hestia host has no registry, so it said "no
# sites registered" and exited 0. The Hestia updater, that fleet's path, scoped
# by update_channel alone: an edge build never reached a stable site, whatever
# the release declared.
#
# The updater takes --force-security now. It is refused for a payload whose
# manifest does not declare "security_critical": true, before a site is looked
# at; with it, a site whose channel refuses the build is put in scope - the
# decision is install.pl's (--channel-check --force-security), the same code
# the per-site deploy obeys - and named in the table and the findings. A site
# excluded from the update (a marker without the lazysite-app template) stays
# excluded. And `lazysite upgrade --all` on such a host says which command to
# run instead.
#
# The updater's discovery and scope blocks are run as they ship, over a stand-in
# lister and the REAL install.pl beside a staged manifest (as t/tools/43 stages
# it), so the channel decisions are the installer's own.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root    = repo_root();
my $updater = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $deploy  = "$root/installers/hestia/lazysite-hestia-deploy.sh";
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit  { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

# A stage: the real install.pl beside a manifest for an edge 9.9.9.
sub stage {
    my (%o) = @_;
    my $s = tempdir( CLEANUP => 1 );
    spit( "$s/release-manifest.json", encode_json( { version => '9.9.9', channel => 'edge', files => {},
                ( $o{security} ? ( security_critical => JSON::PP::true() ) : () ) } ) );
    spit( "$s/install.pl", slurp("$root/install.pl") );
    return $s;
}

# A site at 0.0.1 on the given channel.
sub site {
    my ( $base, $name, $channel ) = @_;
    my $d = "$base/$name/public_html";
    make_path("$d/lazysite");
    spit( "$d/lazysite/lazysite.conf",       "site_url: https://$name\nupdate_channel: $channel\n" );
    spit( "$d/lazysite/.install-state.json", encode_json( { version => '0.0.1', files => {} } ) );
    return $d;
}

subtest 'install.pl --force-security: forced only for a release that declares it' => sub {
    my $base = tempdir( CLEANUP => 1 );
    my $st   = site( $base, 's.example', 'stable' );
    my $check = sub {
        my ( $s, @a ) = @_;
        my $r = run_child( [ $^X, "$s/install.pl", '--channel-check', '--docroot', $st, @a ], stderr => 'merge' );
        return ( $r->{status} >> 8, $r->{out} );
    };
    my $sec = stage( security => 1 );
    my ( $rc, $out ) = $check->($sec);
    is( $rc, 3, 'without the flag a stable site refuses an edge build, security-critical or not' );
    ( $rc, $out ) = $check->( $sec, '--force-security' );
    is( $rc, 0, 'with it, a security-critical build is accepted' ) or diag $out;
    like( $out, qr/--force-security overrides it \(the release declares security_critical\)/, 'and says it was forced' );

    ( $rc, $out ) = $check->( stage(), '--force-security' );
    is( $rc, 2, 'the same flag against a payload that does not declare it is refused' ) or diag $out;
    like( $out, qr/--force-security refused: payload 9\.9\.9 \(channel: edge\) does not declare "security_critical": true/,
        'naming the declaration it lacks' );
};

subtest 'the updater refuses --force-security for a payload that does not declare it' => sub {
    my $r = run_child( [ 'bash', $updater, '--force-security', stage() ], stderr => 'merge' );
    is( $r->{status} >> 8, 2, 'exit 2' ) or diag $r->{out};
    like( $r->{out}, qr/--force-security refused: .*release-manifest\.json does not declare/, 'saying why' );
    like( $r->{out}, qr/nothing was touched/, 'before anything else - the root check has not run yet' );
    unlike( $r->{out}, qr/must run as root/, 'so it is not mistaken for a permissions problem' );

    $r = run_child( [ 'bash', $updater, '--force-security', stage( security => 1 ) ], stderr => 'merge' );
    unlike( $r->{out}, qr/--force-security refused/, 'a security-critical payload passes the check' );
};

# The discovery and scope blocks as they ship, with the helpers that touch
# Hestia stood in. Prints what each array holds.
my $u = slurp($updater);
my ($scope) = $u =~ /(^USERS=\(\); DOMAINS=\(\); DOCS=\(\); VERS=\(\); EXCLUDED=\(\)\n.*?)^\[ "\$LIST" = 1 \] && exit 0$/ms;
ok( $scope, 'the discovery and scope blocks are found in the updater' ) or BAIL_OUT('the updater changed shape');

sub fleet {
    my (%o) = @_;
    my $t    = tempdir( CLEANUP => 1 );
    my $base = "$t/home";
    my %doc  = map { $_->[0] => site( $base, @$_ ) }
        ( [ 'a.example', 'edge' ], [ 's.example', 'stable' ], [ 'x.example', 'stable' ] );
    my $s = stage( security => $o{security} );
    make_path("$s/installers/hestia");
    # x.example carries a marker and is off the lazysite-app template: excluded.
    spit( "$s/installers/hestia/lazysite-hestia-list.sh",
        "for a in \"\$\@\"; do [ \"\$a\" = --template-only ] && T=1; done\n"
            . "printf 'u\\ta.example\\t%s\\n' '$doc{'a.example'}'\n"
            . "printf 'u\\ts.example\\t%s\\n' '$doc{'s.example'}'\n"
            . "[ -n \"\${T:-}\" ] || printf 'u\\tx.example\\t%s\\n' '$doc{'x.example'}'\n" );
    my $body = "set -u\nSTAGE='$s'\nFORCE_SECURITY=" . ( $o{flag} ? 1 : 0 ) . "\nLIST=0\nFINDINGS_FILE='$t/findings'\n: > \"\$FINDINGS_FILE\"\n"
        . "lazysite_dir() { printf '%s\\n' \"\$1/lazysite\"; }\n"
        . "ver_of() { case \"\$1\" in *release-manifest.json) echo 9.9.9 ;; *) echo 0.0.1 ;; esac; }\nengine_state() { echo inside; }\nvhost_state() { echo current; }\n"
        . "template_rev() { echo r; }\ntable_head() { :; }\n"
        . "table_row() { printf 'ROW %s %s\\n' \"\$1\" \"\$7\"; }\n"
        . $scope
        . "echo \"IN=\${IN_DOMAINS[*]}\"\necho \"OUT=\${OUT_OF_SCOPE[*]}\"\n"
        . "echo \"EXC=\${EXC_D[*]}\"\necho \"FORCED=\${FORCED[*]}\"\n";
    spit( "$t/scope.sh", $body );
    my $r = run_child( [ 'bash', "$t/scope.sh" ], stderr => 'merge' );
    return ( $r->{out}, slurp("$t/findings") );
}

# Unchanged behaviour cannot fail on code that never changed it, so each half
# that says "nothing moves" is held against the run where the flag DOES move a
# site: the flag, and only the flag on a payload that declares it, changes scope.
subtest 'without the flag, scope is unchanged - the flag alone moves a site' => sub {
    my ($out) = fleet( security => 1 );
    like( $out, qr/^IN=a\.example$/m,  'the edge site is in scope' ) or diag $out;
    like( $out, qr/^OUT=s\.example$/m, 'the stable site is out of scope, a security-critical build or not' );
    like( $out, qr/^EXC=x\.example$/m, 'the excluded site is excluded' );
    like( $out, qr/^FORCED=$/m,        'and nothing is forced' );
    my ($with) = fleet( security => 1, flag => 1 );
    like( $with, qr/^IN=a\.example s\.example$/m, 'the same fleet with the flag: the stable site moves in' ) or diag $with;
};

subtest 'with it, a stable site is forced in under a security-critical payload' => sub {
    my ( $out, $findings ) = fleet( security => 1, flag => 1 );
    like( $out, qr/^IN=a\.example s\.example$/m, 'the stable site is in scope' ) or diag $out;
    like( $out, qr/^OUT=$/m,                     'nothing is left out of scope' );
    like( $out, qr/^FORCED=s\.example$/m,        'and it is the one forced' );
    like( $out, qr/^ROW s\.example in scope \(forced: security release\)$/m, 'the table says so' );
    like( $out, qr/Forced in \(--force-security; the release declares security_critical\): s\.example/,
        'and names it under the table' );
    like( $findings, qr/^s\.example\tNOTE: forced in by --force-security: its update_channel \(stable\) refuses this '9\.9\.9' build/m,
        'with a finding saying why' );
    like( $out, qr/^EXC=x\.example$/m, 'an excluded site stays excluded' );
    unlike( $out, qr/^IN=.*x\.example/m, 'and is not deployed to' );
};

subtest 'the scope decision is install.pl\'s: a payload that does not declare it forces nothing' => sub {
    my ($out) = fleet( flag => 1 );
    like( $out, qr/^OUT=s\.example$/m, 'the stable site stays out of scope' ) or diag $out;
    like( $out, qr/^FORCED=$/m,        'nothing is forced' );
    my ($with) = fleet( flag => 1, security => 1 );
    like( $with, qr/^FORCED=s\.example$/m, 'where the payload declaring it forces the stable site in' ) or diag $with;
};

subtest 'the per-site deploy carries the override to install.pl' => sub {
    my $d = slurp($deploy);
    like( $d, qr/\[ "\$\{LAZYSITE_FORCE_SECURITY:-\}" = 1 \] && FORCE_ARGS=\(--force-security\)/, 'from the updater\'s export' );
    like( $d, qr/install\.pl" --channel-check --docroot "\$DOC" "\$\{FORCE_ARGS\[\@\]\}"/, 'to the channel check' );
    like( $d, qr/install\.pl" --mode "\$MODE" [^\n]*"\$\{FORCE_ARGS\[\@\]\}"/, 'and to the upgrade' );
    like( $u, qr/\[ "\$FORCE_SECURITY" = 1 \] && export LAZYSITE_FORCE_SECURITY=1/, 'which the updater exports for its deploys' );
};

subtest 'upgrade --all on a Hestia host with no registry names the updater' => sub {
    my $reg = tempdir( CLEANUP => 1 );
    my $hu  = tempdir( CLEANUP => 1 );
    local $ENV{LAZYSITE_REGISTRY_DIR}  = $reg;
    local $ENV{LAZYSITE_HESTIA_USERS} = $hu;
    my $r = run_child( [ $^X, "$root/tools/lazysite-cli.pl", 'upgrade', '--all' ], stderr => 'merge' );
    is( $r->{status} >> 8, 1, 'not exit 0: the fleet was not upgraded' ) or diag $r->{out};
    like( $r->{out}, qr/this is a Hestia host/, 'it says what kind of host this is' );
    like( $r->{out}, qr/lazysite-hestia-update-all\.sh/, 'names the updater' );
    like( $r->{out}, qr/--force-security/, 'and the flag a security release needs' );
};

done_testing();
