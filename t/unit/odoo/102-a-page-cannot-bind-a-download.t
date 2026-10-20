#!/usr/bin/perl
# SM1225: a page binding (`tt_page_var: x: odoo:ID`) that names a binding with
# `answer: download` would put the base64 document in the page. It is refused where
# page bindings are checked: at save (Validate) naming the binding, and at render, which
# gives the page nothing and logs why. A page naming a JSON binding is unchanged.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo     ();
use Lazysite::Validate ();

my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
bind( $d, id => 'quote', operation => 'shop.document', modes => 'public', answer => 'download' );
bind( $d, id => 'plain', operation => 'shop.document', modes => 'public' );
load_processor($d);
$Lazysite::Odoo::TRANSPORT = $fake;

sub page { my ($id) = @_; return "---\ntitle: T\ntt_page_var:\n  x: odoo:$id\n---\nbody\n" }

subtest 'save' => sub {
    my $r = Lazysite::Validate::validate_content( content => page('quote'), docroot => $d );
    ok( !$r->{valid}, 'a page naming a download binding is not valid' ) or diag explain $r;
    my ($i) = grep { $_->{kind} eq 'odoo-binding-is-a-download' } @{ $r->{issues} };
    ok( $i, 'with its own kind' );
    like( $i->{message} // '', qr/odoo:quote.*answer: download.*Link to the Odoo endpoint/s, 'naming the binding and saying to link' );
    $r = Lazysite::Validate::validate_content( content => page('plain'), docroot => $d );
    ok( !( grep { $_->{kind} eq 'odoo-binding-is-a-download' } @{ $r->{issues} } ), 'a json binding is not flagged' );
};

subtest 'render' => sub {
    my ( $log, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:quote' } ) } );
    is( $v{x}, '', 'the page gets nothing' );
    like( $log, qr/answers a download/, 'and the log says why' );
    unlike( $log . ( $v{x} // '' ), qr/content_base64|JVBER|%PDF/, 'no document bytes' );
    ( $log, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:plain' } ) } );
    ok( ref $v{x} eq 'HASH', 'a json binding renders its report as before' ) or diag explain \%v;
};

done_testing();
