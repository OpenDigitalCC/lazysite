#!/usr/bin/perl
# SM1378 (ruling 133, triage T-31): a layout's `requires.lazysite` is read, and
# installing or activating it on an older engine WARNS - never refuses.
#
# The layouts catalogue writes `"requires": { "lazysite": "0.15.11" }` in every
# layout.json, the lowest release whose variables and filters the template
# uses. The engine read it nowhere, so a layout installed on an older engine
# said ok:1 and then failed or degraded at render time. SM337 set the pattern
# this follows: say the consequence, do it anyway.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site repo_root site_tempdir);
use lib repo_root() . '/lib';

require Lazysite::Manager::Themes;
require Lazysite::Manager::Layouts;
require Lazysite::Manager::Domains;
require Lazysite::Manager::Files;

my $docroot = site_tempdir();
setup_test_site($docroot);
my $lz = "$docroot/lazysite";
no warnings 'once';
$Lazysite::Manager::Themes::DOCROOT       = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR  = $lz;
$Lazysite::Manager::Themes::auth_user     = 'tester';
$Lazysite::Manager::Common::DOCROOT       = $docroot;
$Lazysite::Manager::Layouts::DOCROOT      = $docroot;
$Lazysite::Manager::Domains::DOCROOT      = $docroot;
$Lazysite::Manager::Files::DOCROOT        = $docroot;
$Lazysite::Manager::Files::LOCK_DIR       = "$lz/locks";
use warnings 'once';

sub spit {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
}

sub engine { spit( "$lz/.install-state.json", qq({"version":"$_[0]"}\n) ) }

# A layout directory whose layout.json declares $requires (a raw JSON value, or
# undef for no requires block). The template renders nav, so SM337's own note
# stays out of the way unless a test asks for it.
sub layout_at {
    my ( $dir, $requires, $body ) = @_;
    make_path($dir);
    spit( "$dir/layout.tt", $body // "<nav>[% nav %]</nav>[% content %]\n" );
    spit( "$dir/layout.json",
        '{"name":"x","version":"1.0"'
            . ( defined $requires ? qq(,"requires":{"lazysite":$requires}) : '' )
            . "}\n" );
    return $dir;
}

my $req = \&Lazysite::Manager::Themes::layout_engine_requirement;

subtest 'the reader: older warns, equal or newer does not' => sub {
    my $d = layout_at( "$docroot/src/needs", '"0.15.11"' );
    engine('0.15.3');
    my ( $want, $note ) = $req->( $d, $lz, 'needs' );
    is( $want, '0.15.11', 'the declared version is read' );
    like( $note, qr/'needs' requires lazysite 0\.15\.11 and this site runs 0\.15\.3/,
        'an older engine is named, numerically (0.15.3 < 0.15.11, not as text)' );
    like( $note, qr/not a refusal/, 'and it says it is a note' );

    for my $v (qw(0.15.11 0.15.12 0.16.0 1.0.0)) {
        engine($v);
        ( undef, $note ) = $req->( $d, $lz, 'needs' );
        ok( !defined $note, "engine $v is new enough: nothing said" );
    }
    engine('0.14.99');
    ( undef, $note ) = $req->( $d, $lz, 'needs' );
    ok( defined $note, 'a lower minor warns too' );
};

subtest 'nothing to compare, nothing said; a bad declaration is named' => sub {
    engine('0.15.3');
    my ( $want, $note ) = $req->( layout_at( "$docroot/src/plain", undef ), $lz );
    ok( !defined $want && !defined $note, 'a layout that declares nothing' );

    unlink "$lz/.install-state.json";
    ( $want, $note ) = $req->( layout_at( "$docroot/src/needs2", '"9.0.0"' ), $lz );
    is( $want, '9.0.0', 'with no install state the requirement is still read' );
    ok( !defined $note, 'but there is no engine version to compare it with' );

    engine('0.15.3');
    ( $want, $note ) = $req->( layout_at( "$docroot/src/bad", '"latest"' ), $lz, 'bad' );
    like( $note, qr/'bad' declares requires\.lazysite 'latest', which is not a version/,
        'a value that is not a version is said' );
};

subtest 'install warns, and installs' => sub {
    engine('0.15.3');
    my $src = layout_at( "$docroot/src/newer", '"0.15.11"' );
    my $r = Lazysite::Manager::Layouts::_install_layout_from_dir( $src, 'newer',
        'test', 'tester' );
    ok( $r->{ok}, 'the install succeeds - a warning, never a refusal' ) or diag explain $r;
    is( $r->{action}, 'installed', 'and installs' );
    ok( -f "$lz/layouts/newer/layout.tt", 'the files are there' );
    like( $r->{warning} // '', qr/'newer' requires lazysite 0\.15\.11/,
        'the reply names the engine it needs, under the release\'s own name' );
    is_deeply( $r->{requires}, { lazysite => '0.15.11' }, 'and carries it' );

    $r = Lazysite::Manager::Layouts::_install_layout_from_dir( $src, 'newer', 'test',
        'tester' );
    is( $r->{action}, 'already_installed', 'a repeat is a no-op' );
    like( $r->{warning} // '', qr/requires lazysite/, 'and still says so' );

    engine('0.16.4');
    $r = Lazysite::Manager::Layouts::_install_layout_from_dir(
        layout_at( "$docroot/src/fine", '"0.15.11"' ), 'fine', 'test', 'tester' );
    ok( $r->{ok} && !exists $r->{warning}, 'a new-enough engine installs without a word' );
};

subtest 'activate warns, and activates' => sub {
    engine('0.15.3');
    my $r = Lazysite::Manager::Themes::action_layout_activate('newer');
    ok( $r->{ok}, 'activation succeeds' ) or diag explain $r;
    like( $r->{warning} // '', qr/'newer' requires lazysite 0\.15\.11 and this site runs 0\.15\.3/,
        'and warns' );
    is_deeply( $r->{requires}, { lazysite => '0.15.11' }, 'carrying the requirement' );

    # Beside SM337's note, not instead of it.
    layout_at( "$lz/layouts/shownav", '"0.15.11"', "[% content %]\n" );
    $r = Lazysite::Manager::Themes::action_layout_activate('shownav');
    ok( $r->{ok}, 'a showcase that needs a newer engine activates' );
    like( $r->{warning}, qr/does not render the site's navigation/, 'SM337 note kept' );
    like( $r->{warning}, qr/requires lazysite 0\.15\.11/, 'and the engine note beside it' );

    engine('0.16.4');
    $r = Lazysite::Manager::Themes::action_layout_activate('newer');
    ok( $r->{ok} && !defined $r->{warning}, 'a new-enough engine: no warning' );
};

subtest 'binding a layout to a domain warns the same way' => sub {
    engine('0.15.3');
    my $a = Lazysite::Manager::Domains::domain_add( 'example.test',
        content_root => 'sites/example' );
    ok( $a->{ok}, 'a domain to bind' ) or diag explain $a;
    my $r = Lazysite::Manager::Domains::domain_set( 'example.test', 'layout', 'newer' );
    ok( $r->{ok}, 'the binding is written' ) or diag explain $r;
    ok( ( grep { /'newer' requires lazysite 0\.15\.11/ } @{ $r->{warnings} || [] } ),
        'and its warnings name the engine the layout needs' )
        or diag explain $r;
};

done_testing();
