#!/usr/bin/perl
# SM1045: a group exists when either store names it.
#
# Reported from sites.lazysite.io (0.15.4): groups created at /manager/groups
# were reported unknown by acl-set until each had a member.
# Lazysite::Auth::Settings::group_names read the groups file alone, and that
# file lists a group only once someone is in it, while the Groups page writes a
# new group to groups-settings.json. The known set is now the union of the two;
# a name in neither is still unknown.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper               qw(site_tempdir);
use JSON::PP                 ();
use Lazysite::Auth::Settings ();

my $d = site_tempdir();
make_path("$d/lazysite/auth");
my $auth = "$d/lazysite/auth";

sub put {
    my ( $file, $text ) = @_;
    open my $fh, '>', "$auth/$file" or die "$file: $!";
    print {$fh} $text;
    close $fh;
    return;
}

# `editors` exists only as a Groups-page record (no members); `authors` only as
# membership (no record); `both` in both stores.
put( 'groups-settings.json',
    JSON::PP::encode_json( { editors => { label => 'Editors' }, both => { label => 'Both' } } ) );
put( 'groups', "authors: alice\nboth: bob\n" );

{
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = $auth;
    my $g = Lazysite::Auth::Settings::group_names();

    ok( $g->{editors}, 'a group with a record and no members is a group (the reported case)' );
    ok( $g->{authors},            'a group with members and no record is a group' );
    ok( $g->{both},               'a group in both stores is a group' );
    ok( !$g->{'feedback-reader'}, 'a name in neither store is not a group' );
    is_deeply( [ sort keys %$g ], [qw(authors both editors)], 'and nothing else is' );
    is_deeply( [ sort keys %{ Lazysite::Auth::Settings::groups_with_members() } ],
        [qw(authors both)], 'groups_with_members answers membership alone' );
}

subtest 'either store absent: the other still answers' => sub {
    unlink "$auth/groups" or die $!;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = $auth;
    is_deeply( [ sort keys %{ Lazysite::Auth::Settings::group_names() } ],
        [qw(both editors)], 'no groups file: the settings store names the groups' );
    put( 'groups', "authors: alice\n" );
    unlink "$auth/groups-settings.json" or die $!;
    is_deeply( [ sort keys %{ Lazysite::Auth::Settings::group_names() } ],
        ['authors'], 'no settings store: membership names the groups' );
};

subtest 'no auth directory configured: no groups' => sub {
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = undef;
    is_deeply( Lazysite::Auth::Settings::group_names(), {}, 'an empty answer' );
};

done_testing;
