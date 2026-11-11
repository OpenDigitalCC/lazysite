#!/usr/bin/perl
# n818 (SM1440, field findings O-3 and O-6 of the 0.16.11 pass): on a Hestia host the
# unix user that can read lazysite/auth/ is the owner of the store (the one the CGI
# runs as), not the login user, and the refusals named neither.
#
#   - `lazysite acl set` as root said "sudo -u SITEUSER", a placeholder; it now names
#     the owner of lazysite/auth/acls.json and spells the command with it.
#   - `acl set` and `address-profile-delete` on a store this user cannot read said
#     "a fault on the host" / "repair the file"; they now say which unix user ran, and
#     who owns the file, and keep "Nothing was changed".
#
# Sabotage: restore the placeholder in tools/lazysite-acl.pl, or drop unreadable_note
# from acls_write_refusal / AddressProfiles::fault_note from the profile refusal, and
# the matching subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root = repo_root();
my $acl  = "$root/tools/lazysite-acl.pl";
my $usr  = "$root/tools/lazysite-users.pl";
my ($me) = getpwuid($>);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( {} ) );
spit( "$d/open/public.md",          "PUBLIC\n" );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );
run_child( [ $^X, $usr, '--docroot', $d, 'setup-sysop', '--user', 'op', 'secretpw1234' ], stderr => 'inherit' );

subtest 'the root refusal names the owner of the auth store, not a placeholder' => sub {
    local $ENV{LAZYSITE_CLI_FAKE_ROOT} = 1;
    my $r   = run_child( [ $^X, "-I$root/lib", $acl, 'set', 'open/public.md', '--docroot', $d, '--actor', 'op', '--read', 'op' ] );
    my $out = $r->{out} . $r->{err};
    isnt( $r->{status} >> 8, 0, 'it refuses' );
    like( $out, qr/sudo -u \Q$me\E /, "and spells the command with the owner, $me" ) or diag $out;
    unlike( $out, qr/SITEUSER/, 'no placeholder is left' );
};

subtest 'acl set on a store this user cannot read says who ran and who owns it' => sub {
    chmod 0000, "$d/lazysite/auth/acls.json" or die $!;
    my $r   = run_child( [ $^X, "-I$root/lib", $acl, 'set', 'open/public.md', '--docroot', $d, '--actor', 'op', '--read', 'op' ] );
    my $out = $r->{out} . $r->{err};
    chmod 0660, "$d/lazysite/auth/acls.json";
    isnt( $r->{status} >> 8, 0, 'it refuses' );
    like( $out, qr/Nothing was changed/, 'and keeps "Nothing was changed"' ) or diag $out;
    like( $out, qr/This ran as unix user '\Q$me\E', which cannot read lazysite\/auth\/acls\.json/, 'naming the user it ran as' );
    like( $out, qr/That user owns it|owned by '/, 'and who owns the file' );
};

subtest 'address-profile-delete on a store this user cannot read says the same' => sub {
    my $f = "$d/lazysite/auth/address-profiles.json";
    chmod 0000, $f or die $!;
    my $out = run_child( [ $^X, $usr, '--docroot', $d, '--api' ], stdin => encode_json( { action => 'address-profile-delete', name => 'office', actor => 'op' } ) )->{out} // '';
    chmod 0660, $f;
    like( $out, qr/could not be read, so nothing is written over it/, 'it refuses, as before' ) or diag $out;
    like( $out, qr/This ran as unix user '\Q$me\E', which cannot read lazysite\/auth\/address-profiles\.json/, 'and names the user it ran as' );
};

subtest 'a file another user owns is named with its owner and the command' => sub {
    plan skip_all => 'no unreadable root-owned file here' if -r '/etc/shadow' || !-e '/etc/shadow';
    require Lazysite::Util;
    my $n = Lazysite::Util::unreadable_note('/etc/shadow');
    like( $n, qr/It is owned by 'root': run the command as 'root' \(sudo -u root \.\.\.\)/, 'owner named, command spelled' ) or diag $n;
};

done_testing();
