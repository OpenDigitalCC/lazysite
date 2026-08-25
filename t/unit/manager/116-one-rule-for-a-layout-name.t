#!/usr/bin/perl
# SM583: two parsers read the same conf key and disagreed about its value.
#
# _read_active_layout_and_theme matched \S+ and stripped the capture to
# [A-Za-z0-9_-]; Domains::_parse took the whole trimmed line. So
# `layout: my layout` was `my` to one reader and `my layout` to the other -
# one conf line, two answers, and neither of them what the operator wrote.
# The SM516 review proposed folding one onto the other as duplicate conf
# reading; the row was refused and filed instead, because unifying them would
# have picked a winner silently.
#
# THE DECISION IS REJECT, NOT TRUNCATE. Truncation was the worse behaviour and
# the one that looked like agreement: `my` is a layout nobody wrote, it may
# well exist on the instance, and the reader handed it back as the ACTIVE
# layout. Rejection says the site has no layout configured - true, already
# handled everywhere (it is the fresh-install state), and it leaves the
# operator's own text in the conf where they can see it.
#
# The rule is [A-Za-z0-9_-]+, which is not new: theme_config_issues,
# action_create_theme and the layout walkers already enforce it. What is new is
# that it is written down in one place - Domains::valid_presentation_name - and
# that both readers ask it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Themes  ();

sub fixture {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $conf;
    close $fh;
    $Lazysite::Manager::Domains::DOCROOT     = $d;
    $Lazysite::Manager::Themes::DOCROOT      = $d;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    return $d;
}

# The primary site's row, as every domain surface resolves it.
sub primary_row {
    my $r = Lazysite::Manager::Domains::domains_list();
    my ($p) = grep { $_->{is_primary} } @{ $r->{domains} || [] };
    return $p || {};
}

subtest 'one value with a space, read through both surfaces, gives one answer' => sub {
    fixture("site_name: T\nlayout: my layout\ntheme: some theme\n");

    my ( $layout, $theme )
        = Lazysite::Manager::Themes::_read_active_layout_and_theme();
    my $row = primary_row();

    is( $layout,        '',      'the active-pointer reader refuses it' );
    is( $row->{layout}, $layout, 'and the domain reader gives the SAME answer' )
        or diag( 'This is the filing: `layout: my layout` was `my` to one '
            . 'reader and `my layout` to the other, and an operator got a '
            . 'different answer depending on which surface they asked.' );

    is( $theme,        '',     'the same for theme' );
    is( $row->{theme}, $theme, 'and the same agreement' );
};

subtest 'the truncation is gone - no reader invents a name' => sub {
    # `my` may well be a real layout on the instance. Handing it back as the
    # ACTIVE layout is worse than saying nothing is configured, because it is
    # indistinguishable from a working answer.
    fixture("site_name: T\nlayout: my layout\n");
    my ($layout) = Lazysite::Manager::Themes::_read_active_layout_and_theme();
    isnt( $layout, 'my', 'the first word is not returned as the layout' );
    is( $layout, '', 'the value is refused outright' );
};

subtest 'a valid name is untouched by either reader' => sub {
    fixture("site_name: T\nlayout: base\ntheme: default18\n");
    my ( $layout, $theme )
        = Lazysite::Manager::Themes::_read_active_layout_and_theme();
    my $row = primary_row();
    is( $layout,        'base',      'the active reader keeps it' );
    is( $theme,         'default18', 'and the theme' );
    is( $row->{layout}, 'base',      'the domain reader agrees' );
    is( $row->{theme},  'default18', 'on both' );
};

subtest "an invalid per-domain override falls back, it does not truncate" => sub {
    # A domain whose override cannot be accepted is a domain with no override:
    # it inherits, exactly as if the line had never been written.
    fixture( "site_name: T\nlayout: base\n"
            . "alias_hosts: x.example\n"
            . "alias.x.example.content_root: sites/x\n"
            . "alias.x.example.layout: my layout\n" );
    my $r = Lazysite::Manager::Domains::domains_list();
    my ($x) = grep { ( $_->{host} // '' ) eq 'x.example' }
        @{ $r->{domains} || [] };
    ok( $x, 'the domain is listed' ) or return;
    is( $x->{layout},           'base', 'it resolves to the primary layout' );
    is( $x->{layout_inherited}, 1,      'and is reported as inherited' );
};

subtest 'the value cannot be written in the first place' => sub {
    # The read-side rule fails safe; this is where it fails LOUD. Refusing the
    # write is what keeps the conf free of values no reader will accept.
    fixture( "site_name: T\nalias_hosts: x.example\n"
            . "alias.x.example.content_root: sites/x\n" );

    my $bad = Lazysite::Manager::Domains::domain_set(
        'x.example', 'layout', 'my layout' );
    ok( !$bad->{ok}, 'refused' ) or diag explain $bad;
    is( $bad->{kind}, 'invalid', 'as an invalid value' );
    like( $bad->{error}, qr/\[A-Za-z0-9_-\]/,
        'and the message quotes the rule it is applying' );

    my $bad_theme = Lazysite::Manager::Domains::domain_set(
        'x.example', 'theme', 'two words' );
    ok( !$bad_theme->{ok}, 'theme too' );

    my $ok = Lazysite::Manager::Domains::domain_set(
        'x.example', 'layout', 'base' );
    ok( $ok->{ok}, 'a valid name is still accepted' ) or diag explain $ok;

    my $clear = Lazysite::Manager::Domains::domain_set(
        'x.example', 'layout', '' );
    ok( $clear->{ok}, 'and clearing the key still works' ) or diag explain $clear;
};

done_testing();
