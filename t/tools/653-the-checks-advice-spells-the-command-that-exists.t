#!/usr/bin/perl
# n825 (SM1447, O-3 of the 0.16.12 addendum): the check's warnings said "sudo lazysite
# check ..." and "sudo -u USER lazysite check ...", but on a tarball install no `lazysite`
# command exists, while the trusted_proxies warning on the same run spelled the CLI by path.
# Every piece of advice spells the command through cli_spelling().
#
# The test puts no `lazysite` on PATH (so cli_spelling gives "perl .../lazysite-cli.pl"),
# makes the check meet unreadable parts of every kind it advises about, and asserts no
# advice line carries a bare `lazysite` command, and that one carries the path spelling.
#
# Sabotage: put a bare "sudo lazysite check" back in any remedy and the test fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;

my $root = repo_root();
my $tool = "$root/tools/lazysite-check.pl";

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" );
spit( "$d/index.md", "---\ntitle: Home\nsubtitle: Home.\n---\nhi\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => { owner => 'x', addresses => ['office'] } } ) );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [] } } ) );
my $priv = "$d-lazysite-private";
make_path("$priv/a");
chmod 0000, "$priv/a", "$d/lazysite/auth/acls.json", "$d/lazysite/auth/address-profiles.json" or die $!;

local $ENV{PATH} = '/usr/bin:/bin';
delete $ENV{LAZYSITE_CLI};
my $out = run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'discard' )->{out} // '';
chmod 0755, "$priv/a";
chmod 0660, "$d/lazysite/auth/acls.json", "$d/lazysite/auth/address-profiles.json";

my @advice = grep {/->/} split /\n/, $out;
cmp_ok( scalar(@advice), '>', 3, 'the run produced advice to look at' ) or diag $out;
my @bare = grep { /(?:sudo(?: -u \S+)?|run|use|with) +lazysite +\w|\(lazysite +\w|`lazysite +\w/ } @advice;
is( scalar(@bare), 0, 'no advice line spells a bare `lazysite` command' ) or diag join "\n", @bare;
like( $out, qr/sudo -u \S+ perl \S*lazysite-cli\.pl check \.\.\./, 'the remedy spells the CLI by path, as the proxy warning does' ) or diag $out;

done_testing();
