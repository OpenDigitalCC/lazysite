#!/usr/bin/perl
# SM262: an automated caller may remove a theme IT created, and nothing else.
#
# An agent holding manage_themes could call create_theme and had no way to remove
# the result, so every experiment it ran was permanent and only the operator
# could clear it - create-without-delete makes agents into litter generators. A
# zz-guard-theme sat on a live instance for exactly this reason.
#
# The grant is the narrowest that solves it. `created_by` is written by
# create_theme and is kept SEPARATE from `author`: author is a descriptive
# theme.json field a theme may carry and edit, and conflating a description with
# an authorisation would let a theme rewrite its own permissions. A theme with no
# created_by predates the field or arrived another way, and is never removable
# this way - so an agent gains no authority over anything that existed before it.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path("$d/lazysite/layouts/base/themes");
open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} '[% content %]';
close $lt;
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nlayout: base\n";
close $cf;

$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";

sub as_user {
    my ( $user, $code ) = @_;
    local $Lazysite::Manager::Themes::auth_user = $user;
    return $code->();
}

# A theme created through the tool, by 'agent'.
{
    my $r = as_user( 'agent',
        sub {
            Lazysite::Manager::Themes::action_create_theme(
                { layout => 'base', name => 'mine', config => {} } );
        } );
    ok( $r->{ok}, 'create_theme creates' ) or diag( $r->{error} // '' );

    open my $fh, '<', "$d/lazysite/layouts/base/themes/mine/theme.json" or die $!;
    my $meta = decode_json( do { local $/; <$fh> } );
    close $fh;
    is( $meta->{created_by}, 'agent', 'created_by records the creating account' );
    is( $meta->{author}, 'agent', 'author is still written, separately' );
}

# A theme that predates the field: no created_by at all.
{
    make_path("$d/lazysite/layouts/base/themes/inherited");
    open my $tj, '>', "$d/lazysite/layouts/base/themes/inherited/theme.json" or die $!;
    print {$tj} '{"name":"inherited","version":"1.0.0","layouts":["base"],"config":{}}';
    close $tj;
}

# --- the creator may remove their own ---------------------------------------
{
    my $r = Lazysite::Manager::Themes::action_theme_delete( 'mine',
        { restrict_to_creator => 1, user => 'agent' } );
    ok( $r->{ok}, 'the creator deletes their own theme' ) or diag( $r->{error} // '' );
    ok( !-d "$d/lazysite/layouts/base/themes/mine", 'and it is gone' );
}

# --- someone else may not ----------------------------------------------------
{
    as_user( 'agent',
        sub {
            Lazysite::Manager::Themes::action_create_theme(
                { layout => 'base', name => 'theirs', config => {} } );
        } );

    my $r = Lazysite::Manager::Themes::action_theme_delete( 'theirs',
        { restrict_to_creator => 1, user => 'someone-else' } );
    ok( !$r->{ok}, "another account cannot remove it" );
    is( $r->{kind}, 'not-yours', 'reported as not-yours' );
    like( $r->{error}, qr/created by this account/, 'and says why' );
    ok( -d "$d/lazysite/layouts/base/themes/theirs", 'the theme survives' );
}

# --- a theme with no created_by is never removable this way -----------------
# The safe reading of an absent field: an agent gains nothing over what existed
# before it arrived.
{
    my $r = Lazysite::Manager::Themes::action_theme_delete( 'inherited',
        { restrict_to_creator => 1, user => 'agent' } );
    ok( !$r->{ok}, 'a theme with no created_by is refused' );
    is( $r->{kind}, 'not-yours', 'same refusal' );
    ok( -d "$d/lazysite/layouts/base/themes/inherited", 'and survives' );
}

# --- an empty acting user cannot match an empty created_by ------------------
# Guarding the obvious hole: "" eq "" must not authorise anything.
{
    my $r = Lazysite::Manager::Themes::action_theme_delete( 'inherited',
        { restrict_to_creator => 1, user => '' } );
    ok( !$r->{ok}, 'an empty user matches nothing, not even an absent created_by' );
    ok( -d "$d/lazysite/layouts/base/themes/inherited", 'and survives' );
}

# --- unrestricted (the manager UI, a human) still deletes anything ----------
# The cookie-session path is what the UI-only rule was protecting, and it keeps
# its behaviour.
{
    my $r = Lazysite::Manager::Themes::action_theme_delete('inherited');
    ok( $r->{ok}, 'an unrestricted call removes a theme it did not create' )
        or diag( $r->{error} // '' );
    ok( !-d "$d/lazysite/layouts/base/themes/inherited", 'and it is gone' );
}

# --- the active-theme and in-use guards still come FIRST --------------------
# The new rule must not become a way round SM234's protection.
{
    as_user( 'agent',
        sub {
            Lazysite::Manager::Themes::action_create_theme(
                { layout => 'base', name => 'live', config => {} } );
        } );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\nlayout: base\ntheme: live\n";
    close $c;

    my $r = Lazysite::Manager::Themes::action_theme_delete( 'live',
        { restrict_to_creator => 1, user => 'agent' } );
    ok( !$r->{ok}, 'the ACTIVE theme is refused even to its creator' );
    like( $r->{error}, qr/active/i, 'named as the active-theme guard' );
    ok( -d "$d/lazysite/layouts/base/themes/live", 'and survives' );
}

done_testing();
