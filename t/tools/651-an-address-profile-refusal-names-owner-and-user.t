#!/usr/bin/perl
# n825 (SM1447, finding Y1/B3 of the 0.16.12 pass): `lazysite acl set --addresses office`
# on a store this user cannot read refused with "Whether the address profiles this rule
# names exist cannot be told: lazysite/auth/address-profiles.json could not be read.
# Nothing was changed." It named neither the owner of the file nor the user to run as.
# It now says who ran, who owns the file and the command's user, and keeps "Nothing was
# changed". Through a web door it names no unix user (ruling 243).
#
# Sabotage: drop the $note from Files::_address_profile_refusal (or the third value
# address_profiles_missing returns) and the CLI subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;

my $root = repo_root();
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( {} ) );
spit( "$d/open/public.md",          "PUBLIC\n" );
my $store = "$d/lazysite/auth/address-profiles.json";
spit( $store, encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );

subtest 'the CLI names the user it ran as, the owner, and the user to run as' => sub {
    chmod 0000, $store or die $!;
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-acl.pl", 'set', 'open/public.md', '--docroot', $d,
            '--actor', 'op', '--read', 'op', '--addresses', 'office' ] );
    chmod 0660, $store;
    my $out = $r->{out} . $r->{err};
    isnt( $r->{status} >> 8, 0, 'it refuses' );
    like( $out, qr/address-profiles\.json could not be read\. This ran as unix user '\Q$me\E', which cannot read lazysite\/auth\/address-profiles\.json/,
        'naming the file and the user it ran as' ) or diag $out;
    like( $out, qr/That user owns it|owned by '/, 'and who owns the file' );
    like( $out, qr/Nothing was changed/, 'and keeps "Nothing was changed"' );
};

subtest 'a web door names no unix user' => sub {
    chmod 0000, $store or die $!;
    local $ENV{GATEWAY_INTERFACE} = 'CGI/1.1';
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-acl.pl", 'set', 'open/public.md', '--docroot', $d,
            '--actor', 'op', '--read', 'op', '--addresses', 'office' ] );
    chmod 0660, $store;
    my $out = $r->{out} . $r->{err};
    unlike( $out, qr/unix user '\Q$me\E'|sudo -u/, 'no unix user name, no sudo' ) or diag $out;
};

done_testing();
