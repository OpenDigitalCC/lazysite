#!/usr/bin/perl
# n825 (SM1447, field findings Y1 and B3 of the 0.16.12 pass): on a Hestia host
# lazysite/auth/ is ispadmin:www-data 2770, but acls.json and address-profiles.json are
# written by the CGI, so www-data owns them. The refusals named the owner of the
# DIRECTORY (ispadmin), the one user for whom the command then failed.
#
# The user to run as is the owner of the store FILES the command reads and writes. One
# helper, Lazysite::Util::store_run_as, serves acl, handlers, check and users.
#
# The test user cannot chown, so the owners are real and different without it: a symlink
# in the scratch tree to a root-owned file (/etc/passwd) stats as root-owned, the file
# beside it is the test user's, and the directory is the test user's. (The old code named
# the directory's owner, the test user.)
#
# Sabotage: put the old path_owner_name calls back in tools/lazysite-acl.pl,
# tools/lazysite-handlers.pl or tools/lazysite-check.pl (or drop the loop in
# Util::store_run_as) and the matching subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);
use Lazysite::Util ();

plan skip_all => 'running as root: every file is the same owner to it' if $> == 0;
plan skip_all => '/etc/passwd is not root-owned here' unless ( ( stat '/etc/passwd' )[4] // -1 ) == 0;

my $root = repo_root();
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

subtest 'store_run_as names the owner of the files, not of the directory' => sub {
    my $d = site_tempdir();
    spit( "$d/mine.json", '{}' );
    symlink '/etc/passwd', "$d/theirs.json" or die $!;

    my ( $u, $differ ) = Lazysite::Util::store_run_as( $d, qw(theirs.json) );
    is( $u, 'root', 'the one file is root-owned, so root is named, not the directory owner' );
    is( $differ, '', '  and nothing is said to differ' );

    ( $u, $differ ) = Lazysite::Util::store_run_as( $d, qw(mine.json absent.json) );
    is( $u, $me, 'a file that is absent is passed over' );

    ( $u, $differ ) = Lazysite::Util::store_run_as( $d, qw(absent.json) );
    is( $u, $me, 'where no file exists the directory owner is the fallback' );
    is( $differ, '', '  and nothing differs' );

    ( $u, $differ ) = Lazysite::Util::store_run_as( $d, qw(mine.json theirs.json) );
    is( $u, $me, 'where they differ the first existing file decides the name' );
    like( $differ, qr/different owners \($me owns mine\.json; root owns theirs\.json\)/, '  and each owner is named with its file' ) or diag $differ;

    ( $u, $differ ) = Lazysite::Util::store_run_as( "$d/no/such/dir", qw(x) );
    is( $u, 'SITEUSER', 'with nothing to stat the placeholder stays' ) if !-e "$d/no";
};

subtest 'acl set as root names the file owner, and says where the files differ' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/acls.json", encode_json( {} ) );
    symlink '/etc/passwd', "$d/lazysite/auth/address-profiles.json" or die $!;
    local $ENV{LAZYSITE_CLI_FAKE_ROOT} = 1;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-acl.pl", 'set', 'p.md', '--docroot', $d, '--read', 'x' ] );
    my $out = $r->{out} . $r->{err};
    isnt( $r->{status} >> 8, 0, 'it refuses' );
    like( $out, qr/sudo -u \Q$me\E /, "and spells the command with the owner of acls.json, $me" ) or diag $out;
    like( $out, qr/different owners \(\Q$me\E owns acls\.json; root owns address-profiles\.json\)/,
        'and says the two store files have different owners' ) or diag $out;
    unlike( $out, qr/who owns lazysite\/auth\//, 'and no longer says the directory is the owner' );
};

subtest 'handlers save as root names the owner of the files it writes' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/forms/schedule.conf", '' );
    symlink '/etc/passwd', "$d/lazysite/forms/handlers.conf" or die $!;
    local $ENV{LAZYSITE_CLI_FAKE_ROOT} = 1;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-handlers.pl", 'save', '--docroot', $d ] );
    my $out = $r->{out} . $r->{err};
    isnt( $r->{status} >> 8, 0, 'it refuses' );
    like( $out, qr/sudo -u root \.\.\./, 'and names root, who owns handlers.conf, not the directory owner' ) or diag $out;
    like( $out, qr/different owners \(root owns handlers\.conf; \Q$me\E owns schedule\.conf\)/, 'and says they differ' ) or diag $out;
};

subtest 'the check names the owner of the store files in its remedy' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" );
    spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [] } } ) );
    spit( "$d/lazysite/auth/address-lists.json.converted", encode_json( { office => { kind => 'allow', entries => [] } } ) );
    spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => { owner => 'x', addresses => ['office'] } } ) );
    spit( "$d/p.md", "---\ntitle: P\naddresses: [office]\n---\nbody\n" );
    chmod 0000, "$d/lazysite/auth/acls.json" or die $!;
    my $out = run_child( [ $^X, "$root/tools/lazysite-check.pl", '--docroot', $d ], stderr => 'inherit' )->{out} // '';
    chmod 0660, "$d/lazysite/auth/acls.json";
    like( $out, qr/run the check as root, or fix the permissions of what it could not read \(\S*acls\.json\): it is owned by \Q$me\E, who ran this check/,
        'the remedy does not send the running user to run it as themselves (SM1458)' ) or diag $out;
    unlike( $out, qr/sudo -u USER/, 'no placeholder is left' );
};

done_testing();
