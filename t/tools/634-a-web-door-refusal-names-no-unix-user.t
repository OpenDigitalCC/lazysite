#!/usr/bin/perl
# n818 (SM1440, ruling 243): a refusal shown through a web door (the manager API, MCP)
# names no unix user. On an unreadable store it says "the web server's user" and "the
# owner of the file", with the advice to run the command on the host as that owner. The
# CLI keeps naming the users (t/tools/630).
#
# A web door is a process answering a request: REQUEST_METHOD is set (the manager API
# runs the users tool with that environment, and the access-rule writer runs in it).
#
# Sabotage: make Lazysite::Util::web_door always false and every subtest here fails.
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
my $usr  = "$root/tools/lazysite-users.pl";
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf",  "site_name: T\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( {} ) );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );
run_child( [ $^X, $usr, '--docroot', $d, 'setup-sysop', '--user', 'op', 'secretpw1234' ], stderr => 'inherit' );

sub no_user_named {
    my ( $text, $what ) = @_;
    unlike( $text, qr/\Q$me\E/, "$what: the unix user's name ($me) is not in it" ) or diag $text;
    unlike( $text, qr/sudo -u|unix user '/, "$what: no sudo line and no 'unix user' naming" );
    like( $text, qr/web server's user/, "$what: it says the web server's user" );
}

subtest 'the users tool, as the manager API runs it, names no unix user' => sub {
    my $f = "$d/lazysite/auth/address-profiles.json";
    chmod 0000, $f or die $!;
    local $ENV{REQUEST_METHOD} = 'POST';
    my $out = run_child( [ $^X, $usr, '--docroot', $d, '--api' ], stdin => encode_json( { action => 'address-profile-delete', name => 'office', actor => 'op' } ) )->{out} // '';
    chmod 0660, $f;
    like( $out, qr/could not be read, so nothing is written over it/, 'it refuses, as before' ) or diag $out;
    no_user_named( $out, 'address-profile-delete' );
    like( $out, qr/owner of the file/, 'and the owner is "the owner of the file"' );
};

subtest 'the access-rule refusal names no unix user' => sub {
    require Lazysite::Auth::Acl;
    no warnings "once";
    local $Lazysite::Auth::Acl::DOCROOT = $d;
    local $ENV{REQUEST_METHOD} = 'POST';
    chmod 0000, "$d/lazysite/auth/acls.json" or die $!;
    my $no = Lazysite::Auth::Acl::acls_write_refusal();
    chmod 0660, "$d/lazysite/auth/acls.json";
    ok( $no && !$no->{ok}, 'it refuses' ) or diag explain $no;
    no_user_named( $no->{error} // '', 'acls_write_refusal' );
    like( $no->{error} // '', qr/Nothing was changed/, 'and keeps "Nothing was changed"' );
};

subtest 'the same refusal on the CLI still names the user' => sub {
    my $f = "$d/lazysite/auth/address-profiles.json";
    chmod 0000, $f or die $!;
    my $out = run_child( [ $^X, $usr, '--docroot', $d, '--api' ], stdin => encode_json( { action => 'address-profile-delete', name => 'office', actor => 'op' } ) )->{out} // '';
    chmod 0660, $f;
    like( $out, qr/unix user '\Q$me\E'/, 'no request environment: the user is named' ) or diag $out;
};

done_testing();
