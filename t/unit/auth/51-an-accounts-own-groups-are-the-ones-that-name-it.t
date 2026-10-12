#!/usr/bin/perl
# SM1046: the groups a domain-add may name are the account's OWN - the groups
# that list it by name. A parent it inherits through nesting is not one: that
# group reaches further than the account's own (its other members and every
# group nested in it), so handing a new domain to it is not "its own group".
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper               qw(site_tempdir);
use Lazysite::Auth::Settings ();

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);
open my $fh, '>', "$auth/groups" or die $!;
print {$fh} "partners: alice, bob\nwriters: alice\nparent: partners\nothers: carol\n";
close $fh;

no warnings 'once';
local $Lazysite::Auth::Settings::AUTH_DIR = $auth;

is_deeply( [ Lazysite::Auth::Settings::direct_groups('alice') ], [qw(partners writers)],
    'the groups that name the account, sorted' );
ok( ( grep { $_ eq 'parent' } Lazysite::Auth::Settings::effective_groups('alice') ),
    'the nesting parent is in its effective groups' );
ok( !( grep { $_ eq 'parent' } Lazysite::Auth::Settings::direct_groups('alice') ),
    '...and not among its own' );
is_deeply( [ Lazysite::Auth::Settings::direct_groups('dave') ], [], 'an account in no group has none' );
is_deeply( [ Lazysite::Auth::Settings::direct_groups('') ], [], 'no account, no groups' );

done_testing;
