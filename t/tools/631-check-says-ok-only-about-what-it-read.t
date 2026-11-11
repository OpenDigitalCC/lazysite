#!/usr/bin/perl
# n818 (SM1440, field finding O-4 of the 0.16.11 pass): the check printed
# "[ ok ] every rule names its address profile in the slot its old list's kind meant"
# straight after warning that acls.json could not be read. An ok line says what was
# looked at; when part of what it covers was not read, it says it could not check, as
# SM1437 does for pages, naming the file and the user.
#
# Sabotage: drop the faults branch before either ok line in tools/lazysite-check.pl and
# the unreadable-store subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;

my $tool = repo_root() . '/tools/lazysite-check.pl';
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d = site_tempdir();
spit( "$d/lazysite/lazysite.conf", "site_name: T\ntrusted_proxies: 127.0.0.1\n" );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );
spit( "$d/lazysite/auth/address-lists.json.converted", encode_json( { office => { kind => 'allow', entries => [] } } ) );
spit( "$d/lazysite/auth/acls.json", encode_json( { '/intranet/' => { owner => 'x', addresses => ['office'] } } ) );
spit( "$d/p.md", "---\ntitle: P\naddresses: [office]\n---\nbody\n" );

sub run { return run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'inherit' )->{out} // '' }

my $OK_PROFILES = qr/\[\s*ok\s*\] every address profile a rule names is in the store/;
my $OK_SLOTS    = qr/\[\s*ok\s*\] every rule names its address profile in the slot its old list's kind meant/;

subtest 'a store that reads gives both ok lines' => sub {
    my $out = run();
    like( $out, $OK_PROFILES, 'the profiles are in the store' ) or diag $out;
    like( $out, $OK_SLOTS,    'and the slots match' );
};

subtest 'a store that cannot be read gives neither, and names the file and the user' => sub {
    chmod 0000, "$d/lazysite/auth/acls.json" or die $!;
    my $out = run();
    chmod 0660, "$d/lazysite/auth/acls.json";
    unlike( $out, $OK_PROFILES, 'no ok about the profiles' ) or diag $out;
    unlike( $out, $OK_SLOTS,    'no ok about the slots' );
    like( $out, qr/could not check that every address profile a rule names is in the store: acls\.json could not be read as '\Q$me\E'/,
        'the profile line says it could not check, naming the file and the user' );
    like( $out, qr/could not check whether every rule names its address profile in the slot.*acls\.json could not be read as '\Q$me\E' \(Permission denied; the file is owned by '\Q$me\E'\)/,
        'and so does the slot line, with the owner' );
};

done_testing();
