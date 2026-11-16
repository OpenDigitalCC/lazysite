#!/usr/bin/perl
# SM1458 R1 and R3, through the real check (the 0.17.0 field walk, T2.3): the address-rule
# walk advised "run the check as X, who owns the store files" while running as X, because it
# named the owner of the FIRST store file whatever it could not read. Here acls.json is the
# running user's and readable, and the profile store is root-owned and unreadable: the
# advice must name root (once), not the running user.
#
# Sabotage: pass no path to _run_as_remedy in the address-profile walk, or make
# Util::run_as_advice take the owner of the first store file, and the test fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;
plan skip_all => '/etc/shadow is not root-owned and unreadable here'
    if open( my $sh, '<', '/etc/shadow' ) || !-e '/etc/shadow';

my $root = repo_root();
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" );
spit( "$d/index.md", "---\ntitle: Home\nsubtitle: Home.\n---\nhi\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => { owner => 'x', addresses => ['office'] } } ) );
symlink '/etc/shadow', "$d/lazysite/auth/address-profiles.json" or die $!;

local $ENV{PATH} = '/usr/bin:/bin';
delete $ENV{LAZYSITE_CLI};
my $out = run_child( [ $^X, "$root/tools/lazysite-check.pl", '--docroot', $d ], stderr => 'discard' )->{out} // '';

my @lines = split /\n/, $out;
my ($i) = grep { $lines[$_] =~ /cannot read address-profiles\.json as \Q$me\E/ } 0 .. $#lines;
ok( defined $i, 'the address-profile walk warns that it cannot read the store' ) or diag $out;
my $advice = defined $i ? ( $lines[ $i + 1 ] // '' ) : '';
like( $advice, qr/-> run the check as root, who owns what it could not read \(sudo -u root perl \S*lazysite-cli\.pl check \.\.\.\)/,
    'and its advice names root, who owns the store, spelled with the full command' ) or diag $advice;
unlike( $advice, qr/run the check as \Q$me\E/, '  and not the user who is running it' );
unlike( $advice, qr/root[^(]*, or as root|\(sudo[^)]*\), or as root/, '  and says root once' );
my @named = grep {/run the check as \Q$me\E\b/} @lines;
is( scalar(@named), 0, 'no walk of the run tells the running user to run it as themselves' ) or diag join "\n", @named;

done_testing();
