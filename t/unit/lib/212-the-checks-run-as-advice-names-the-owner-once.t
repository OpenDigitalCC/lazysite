#!/usr/bin/perl
# SM1458 (the 0.17.0 field walk, T2.3 and T2.4): the advice a check walk gives for
# something it could not read, built by Lazysite::Util::run_as_advice and
# Lazysite::Util::store_run_as.
#
#   R1  the advice never sends the running user to run the check as themselves: it names
#       the owner of what could not be read; where all of it is the running user's own,
#       its permissions are the fault and it says so
#   R2  the command in the advice is spelled the one way every other advice line spells it
#       (cli_spelling), not a bare `lazysite`
#   R3  where the owner is root, root is said once, not "as root, who owns ..., or as root"
#
# The test user cannot chown, so owners are real and different without it: a symlink to a
# root-owned file (/etc/passwd) stats as root-owned (as t/tools/650 does).
#
# Sabotage: make run_as_advice use the first store file's owner (no skipping of the running
# user's own), drop the `$u eq 'root'` test, or put the bare `lazysite check` back in
# store_run_as, and the matching subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Util ();

plan skip_all => 'running as root: every file is the same owner to it' if $> == 0;
plan skip_all => '/etc/passwd is not root-owned here' unless ( ( stat '/etc/passwd' )[4] // -1 ) == 0;

my ($me) = getpwuid($>);
local $ENV{LAZYSITE_CLI} = 'perl /opt/site/tools/lazysite-cli.pl';

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
spit( "$auth/acls.json", '{}' );
spit( "$auth/mine.json", '{}' );
symlink '/etc/passwd', "$auth/theirs.json" or die $!;
symlink '/etc/passwd', "$auth/address-profiles.json" or die $!;

subtest 'R1: the running user is not named when what could not be read is another\'s' => sub {
    my $a = Lazysite::Util::run_as_advice( $auth, "$auth/theirs.json" );
    like( $a, qr/\Arun the check as root, who owns what it could not read /, 'one root-owned path: root is named' ) or diag $a;
    unlike( $a, qr/as \Q$me\E\b/, '  and not the running user' );

    $a = Lazysite::Util::run_as_advice( $auth, "$auth/mine.json", "$auth/theirs.json" );
    like( $a, qr/\Arun the check as root, who owns what it could not read /, 'a path of the running user\'s and a root-owned one: root is named' ) or diag $a;

    # No paths: the store files. acls.json (first) is the running user's; the profile store is root's.
    $a = Lazysite::Util::run_as_advice($auth);
    like( $a, qr/\Arun the check as root, who owns the store files /, 'the store files: the first file is the running user\'s, the owner named is root\'s' ) or diag $a;
};

subtest 'R1: all of it the running user\'s own is a permissions fault, naming nobody to run as' => sub {
    my $a = Lazysite::Util::run_as_advice( $auth, "$auth/mine.json" );
    unlike( $a, qr/run the check as \Q$me\E/, 'the running user is not told to run it as themselves' ) or diag $a;
    unlike( $a, qr/sudo -u/, '  and no sudo line is spelled' );
    like( $a, qr/fix the permissions of what it could not read \(\Q$auth\E\/mine\.json\): it is owned by \Q$me\E, who ran this check/,
        'it says the permissions are the fault' ) or diag $a;
};

subtest 'R3: where the owner is root, root is said once' => sub {
    my $a = Lazysite::Util::run_as_advice( $auth, "$auth/theirs.json" );
    is( () = $a =~ /\broot\b/g, 2, 'root appears as the user and in the sudo line, and nowhere else' ) or diag $a;
    unlike( $a, qr/, or as root/, 'no ", or as root" after naming root' ) or diag $a;
    like( $a, qr/\(sudo -u root perl \/opt\/site\/tools\/lazysite-cli\.pl check \.\.\.\)\z/, '  the sentence ends at the sudo line' ) or diag $a;
};

subtest 'R2: the command in the different-owners sentence is the full spelling' => sub {
    my ( $u, $differ ) = Lazysite::Util::store_run_as( $auth, qw(mine.json theirs.json) );
    like( $differ, qr/different owners/, 'the files differ' ) or diag $differ;
    like( $differ, qr/\(`perl \/opt\/site\/tools\/lazysite-cli\.pl check` names the fix\)/, 'the command is spelled as every other advice spells it' ) or diag $differ;
    unlike( $differ, qr/`lazysite check`/, '  not a bare `lazysite`' );
};

done_testing;
