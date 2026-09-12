#!/usr/bin/perl
# SM861: a theme name the caller gave is either used or refused - never edited.
#
# `action_theme_copy` did both of the things a name handler should not do:
#
#     $from =~ s/[^a-zA-Z0-9_-]//g if defined $from;
#     $to   =~ s/[^a-zA-Z0-9_-]//g if defined $to;
#     $to = lc( $to // '' );
#
# Every character outside the allowed set was STRIPPED without a word - from
# `$from` too, so "Theme 'X' not found" could name a theme the caller never
# typed - and `$to` alone was lower-cased, while `$from` was not.
#
# HOW THAT SURFACED IN THE FIELD. A tester copied `lumen` to
# `lumen-1312E-backup-20260911T045513Z`, got a second, lower-case theme, and it
# did not collide with the mixed-case theme already there. Their `exists`
# control only worked by copying onto the folded name twice. Mixed case is valid
# everywhere else in this module - `theme_config_issues` accepts
# [A-Za-z0-9_-]+, the theme listing lists mixed-case directories, and WebDAV
# creates them - so copy and rename were the only surfaces that could not
# address half the names the store permits.
#
# RULED 2026-09-12: refuse, do not mutate. Consistent with the rest of the
# module, which already refuses (theme_config_issues, the layout/theme guard).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();

my $docroot = tempdir( CLEANUP => 1 );
my $lz      = "$docroot/lazysite";
my $themes  = "$lz/layouts/base/themes";
make_path("$themes/Lumen");
make_path("$themes/plain");
make_path("$lz/auth");
open my $cf, '>', "$lz/lazysite.conf" or die $!;
print {$cf} "site_name: T\nlayout: base\ntheme: plain\n";
close $cf;

open my $tj, '>', "$themes/Lumen/theme.json" or die $!;
print {$tj} '{"name":"Lumen","layouts":["base"]}';
close $tj;

# BOTH, as t/unit/manager/102 does. With only DOCROOT set, LAZYSITE_DIR is
# undef and the module builds paths from the empty string - it tried to mkdir
# /auth, which fails as a permission error and reads like a broken test rather
# than a missing fixture.
$Lazysite::Manager::Themes::DOCROOT      = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR = $lz;

subtest 'a name outside the allowed set is refused, naming what is allowed' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'Lumen', 'My Theme!' );
    ok( !$r->{ok}, 'the copy is refused' );
    is( $r->{kind}, 'validation', 'as a validation refusal' );
    like( $r->{error}, qr/\QMy Theme!\E/,
        'the message quotes the name the caller actually gave' )
        or diag( 'It used to strip the space and the bang, create "MyTheme", '
            . 'and report success - so the caller got a theme under a name '
            . 'they never asked for and had no way to learn.' );
    like( $r->{error}, qr/\[A-Za-z0-9_-\]/, 'and says what is allowed' );
    ok( !-d "$themes/MyTheme", 'and nothing was created under the edited name' );
};

subtest 'mixed case is preserved, because mixed case is valid' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'Lumen', 'Lumen-Backup' );
    ok( $r->{ok}, 'the copy succeeds' ) or diag( explain $r );
    ok( -d "$themes/Lumen-Backup",
        'the theme exists under the name that was asked for' )
        or diag( 'The name was lower-cased, so the copy landed at '
            . '"lumen-backup" - a different theme from the one requested, and '
            . 'one that does not collide with an existing mixed-case name.' );
    ok( !-d "$themes/lumen-backup", 'and not under a folded one' );
};

subtest 'the source name is not edited either' => sub {
    # "Lumen!" must be refused as invalid, NOT stripped to "Lumen" and copied.
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'Lumen!', 'safe-name' );
    ok( !$r->{ok}, 'a malformed source is refused' );
    is( $r->{kind}, 'validation', 'as validation, not not-found' )
        or diag( 'Stripping $from meant a bad source name silently became a '
            . 'good one. When it did not exist, the not-found message named '
            . 'the STRIPPED name - a theme the caller never typed.' );
    ok( !-d "$themes/safe-name", 'and no copy was made' );
};

subtest 'rename refuses and preserves case in the same way' => sub {
    my $bad = Lazysite::Manager::Themes::action_theme_rename( 'Lumen', 'no good' );
    ok( !$bad->{ok}, 'a malformed new name is refused' );
    is( $bad->{kind}, 'validation', 'as a validation refusal' );
    ok( -d "$themes/Lumen", 'and the theme is untouched' );
};

subtest 'delete names the theme the caller named' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_delete('Lumen!');
    ok( !$r->{ok}, 'a malformed name is refused' );
    is( $r->{kind}, 'validation', 'as validation' )
        or diag( 'It stripped the bang and went on to act on "Lumen" - a '
            . 'different theme from the one named, and a destructive verb.' );
    ok( -d "$themes/Lumen", 'and the real theme survives' );
};

done_testing();
