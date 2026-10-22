#!/usr/bin/perl
# SM1236: every hint the rollout prints names a command that runs on THIS host,
# and every hint that sends an operator to v-rebuild-web-domain names the repair.
#
# THE 0.16.0 ROLLOUT (2026-10-22) said `lazysite check --domain D` (and
# `--fix`) in its findings and failure lines. A host deployed from the tarball
# has no `lazysite` on PATH - the .deb installs it, the tarball does not. The
# hints now name `lazysite` when it is on PATH and the release's CLI by path
# otherwise, and offer `repair` (check, --fix, check again) where they offered
# `check --fix`.
#
# And after it, a manual v-rebuild-web-domain reset three sites' docroots to
# 2751 and lazysite/git to 2775 (SM270); the repair fixed both. A hint naming
# the rebuild now names the repair after it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $UPD  = "$root/installers/hestia/lazysite-hestia-update-all.sh";
my $DEP  = "$root/installers/hestia/lazysite-hestia-deploy.sh";
my $dir  = tempdir( CLEANUP => 1 );

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }
sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }

my $u = slurp($UPD);
my %fn;
for my $n (qw(cli_cmd rebuild_hint)) {
    ( $fn{$n} ) = $u =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}

# A PATH with no `lazysite` on it, and one with a stand-in.
make_path("$dir/nolzs");
make_path("$dir/withlzs");
spit( "$dir/withlzs/lazysite", "#!/bin/sh\nexit 0\n" );
chmod 0755, "$dir/withlzs/lazysite";
my $basepath = join ':', grep { length && !-x "$_/lazysite" } split /:/, $ENV{PATH};

sub run_fn {
    my ( $path, $body ) = @_;
    spit( "$dir/t.sh", "set -u\nLZS=/stage/tools/lazysite-cli.pl\n$fn{cli_cmd}$fn{rebuild_hint}$body\n" );
    local $ENV{PATH} = $path;
    return scalar qx(/bin/bash '$dir/t.sh' 2>&1);
}

subtest 'the updater names the CLI as this host has it' => sub {
    is( run_fn( "$dir/nolzs:$basepath", 'cli_cmd' ), "perl /stage/tools/lazysite-cli.pl\n",
        'no lazysite on PATH: the release\'s CLI, by path' );
    is( run_fn( "$dir/withlzs:$basepath", 'cli_cmd' ), "lazysite\n",
        'lazysite on PATH: lazysite' );
    my $h = run_fn( "$dir/nolzs:$basepath", 'rebuild_hint "  rebuild them"' );
    like( $h, qr/v-rebuild-web-domain USER DOMAIN, then perl \/stage\/tools\/lazysite-cli\.pl repair --domain DOMAIN/,
        'a rebuild hint names the repair after it, runnable here' );
};

subtest 'no hint in the updater or the deploy names a command the host may lack' => sub {
    for my $f ( [ updater => $u ], [ deploy => slurp($DEP) ] ) {
        my @out = grep { !/^\s*#/ && /\b(?:echo|printf)\b|^\s*"/ } split /\n/, $f->[1];
        my @bare = grep { /(?<![\w\/-])lazysite (?:check|repair|probe|acl)\b/ } @out;
        is_deeply( \@bare, [], "$f->[0]: no printed hint says `lazysite check/repair` literally" )
            or diag explain \@bare;
        my @rebuild = grep { /v-rebuild-web-domain/ && !/"\$HESTIA\/bin/ } @out;
        my @norepair = grep { !/repair/ } @rebuild;
        # The deploy's two-line hint prints the repair on the line below it.
        @norepair = grep { $f->[0] ne 'deploy' || $f->[1] !~ /\Q$_\E\n[^\n]*\n?\s*echo "    \$LZS_CLI repair --domain/ } @norepair;
        is_deeply( \@norepair, [], "$f->[0]: every v-rebuild-web-domain hint names the repair" )
            or diag explain \@norepair;
    }
    like( $u, qr/rebuilt outside this rollout - now run: \$\(cli_cmd\) repair --domain/,
        'a domain --rebuild rebuilds but does not manage is told to run the repair' );
};

subtest 'the deploy says what to run, the way this host runs it' => sub {
    my $d = slurp($DEP);
    my ($pick) = $d =~ /(^# SM1236: the CLI as this host runs it.*?^fi\n)/ms;
    my ($final) = $d =~ /(^set \+e\nperl "\$DOM\/tools\/lazysite-check\.pl" --docroot "\$DOC" --cgibin "\$CGI" --fix\n.*?\z)/ms;
    ok( $pick && $final, 'the spelling and the final verdict are found' ) or return;
    make_path("$dir/dom/tools");
    spit( "$dir/dom/tools/lazysite-check.pl", "exit 1;\n" );
    spit( "$dir/d.sh", "STAGE=/stage; DOMAIN=a.example; DOM='$dir/dom'; DOC=/nowhere; CGI=/nowhere\n$pick$final" );
    local $ENV{PATH} = "$dir/nolzs:$basepath";
    delete local $ENV{LAZYSITE_CLI};
    my $out = qx(/bin/bash '$dir/d.sh' 2>&1);
    like( $out, qr{Run: perl /stage/tools/lazysite-cli\.pl check --domain a\.example}, 'tarball host: the CLI by path' )
        or diag $out;
    local $ENV{LAZYSITE_CLI} = 'perl /from/updater/lazysite-cli.pl';
    $out = qx(/bin/bash '$dir/d.sh' 2>&1);
    like( $out, qr{Run: perl /from/updater/lazysite-cli\.pl check}, 'the updater\'s spelling is used when given' );
};

subtest 'the CLI\'s own lines, and the tools it runs' => sub {
    my $cli = slurp("$root/tools/lazysite-cli.pl");
    like( $cli, qr/NOT serviceable - see its health "\n\s*\. 'check above \(' \. invoked_as\(\) \. " repair --domain \$s->\{name\}\)\\n"/,
        'NOT SERVICEABLE names the repair, spelled as the operator reached the CLI' );
    unlike( $cli, qr/lazysite check --domain \$s->\{name\} --fix/, 'and no longer `lazysite check --fix`' );

    # Outcome: the check's rebuild hint, reached through the CLI by path, names
    # the CLI by path - LAZYSITE_CLI carries the spelling to the tool.
    my $d = Cwd::realpath( site_tempdir() );
    make_path("$d/lazysite");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 10.0.0.1\n" );
    local $ENV{PATH} = "$dir/nolzs:$basepath";
    delete local $ENV{LAZYSITE_CLI};
    my $out = qx($^X \Q$root/tools/lazysite-cli.pl\E check --docroot \Q$d\E 2>&1);
    like( $out, qr{v-rebuild-web-domain USER DOMAIN followed by `perl \Q$root\E/tools/lazysite-cli\.pl repair --domain DOMAIN`},
        'the check\'s rebuild hint names the repair, by the path this host runs' )
        or diag $out;
    $out = qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1);
    like( $out, qr{followed by `perl \Q$root\E/tools/lazysite-cli\.pl repair}, 'run on its own, the CLI beside it' )
        or diag $out;

    for my $t (qw(lazysite-acl.pl lazysite-hestia-domain.pl)) {
        my $s = slurp("$root/tools/$t");
        like( $s, qr/sub cli_spelling/, "$t spells its hints through cli_spelling" );
        unlike( $s, qr/^\s*(?:print|\.)[^\n#]*["'][^"'\n]*\blazysite (?:check|acl|repair)\b(?!:)/m,
            "$t prints no literal `lazysite check/acl/repair`" );
    }
    like( slurp("$root/tools/lazysite-hestia-domain.pl"), qr/v-rebuild-web-domain USER DOMAIN\\n"\n(?:\s*#[^\n]*\n)?\s*\. '    ' \. cli_spelling\(\) \. " repair --domain DOMAIN/,
        'the hestia-domain rebuild hint names the repair' );
};

done_testing();
