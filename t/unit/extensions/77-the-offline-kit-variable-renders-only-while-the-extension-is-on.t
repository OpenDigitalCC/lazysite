#!/usr/bin/perl
# SM1396 (ruling 53, X8 of SM1369): THE OFFLINE KIT IS AN EXTENSION, built on
# the hooks of X5 and nothing Odoo-specific in core.
#
# Through the real descriptor, the real index build and the real processor:
#
#   * off (not in the conf): [% app_offline_kit %] renders nothing, and the
#     kit's path is not found;
#   * on, with Odoo on: the variable renders the versioned script tag, the kit
#     is served from the extension's payload as a script, and the page carries
#     no second copy of it;
#   * it requires Odoo: enabling it while Odoo is off is refused by name, and
#     with Odoo turned off afterwards the variable renders nothing again;
#   * no shipped layout carries a script of its own for it (that stays the rule).
#
# Sabotage: make kit_tag answer the tag whatever the context and the off case
# still renders nothing - the variable exists only while the extension is on
# (the index names only enabled extensions); drop the enabled check from the
# processor's _extension_entries instead and the "Odoo off afterwards" case fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_processor index_extensions);
use Lazysite::Manager::Extensions qw(action_extension_enable);

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root = repo_root();

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }

sub site {
    my (%o) = @_;
    my $d = site_tempdir( extensions => 1 );
    make_path("$d/lazysite/layouts/plain");
    my $conf = "site_name: T\nlayout: plain\n";
    $conf .= "extensions:\n" . join( '', map { "  - extensions/$_.pl\n" } @{ $o{on} || [] } ) if $o{on};
    spit( "$d/lazysite/lazysite.conf", $conf );
    spit( "$d/lazysite/layouts/plain/layout.tt",
        '<!DOCTYPE html><html><head><title>[% page_title %]</title>[% app_offline_kit %]</head>'
            . '<body><p data-ls-app-banner hidden>You are offline</p><main>[% content %]</main></body></html>' );
    spit( "$d/page.md", "---\ntitle: P\n---\n\nWords.\n" );
    index_extensions($d) if $o{on};
    return $d;
}

subtest 'off: the variable renders nothing and the kit is not found' => sub {
    my $d    = site();
    my $html = run_processor( $d, '/page' );
    like( $html, qr{<title>P</title></head>}, 'nothing where the variable was' );
    unlike( $html, qr{app-offline}, 'and no script' );
    is( status_of( run_processor( $d, '/assets/app-offline-kit.js' ) ), 404, 'the kit\'s path is not found' );
};

subtest 'on, with Odoo: the tag renders and the kit is served from the payload' => sub {
    my $d    = site( on => [ 'odoo', 'app-offline' ] );
    my $html = run_processor( $d, '/page' );
    like( $html, qr{<title>P</title><script src="/assets/app-offline-kit\.js\?v=[^"]*" defer></script></head>},
        'the variable renders the versioned script tag' );
    my $n = () = $html =~ m{app-offline-kit\.js}g;
    is( $n, 1, 'once' );
    my $out = run_processor( $d, '/assets/app-offline-kit.js' );
    is( status_of($out), 200, 'the kit answers at its declared path' );
    like( $out, qr{^Content-Type: text/javascript}mi, '...as a script' );
    like( $out, qr/LazysiteAppOffline/, '...the kit itself, from extensions/app-offline/assets' );
    ok( !-e "$d/assets/app-offline-kit.js", 'and no copy of it is in the docroot' );
};

subtest 'it requires Odoo' => sub {
    my $d = site( on => ['odoo'] );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nlayout: plain\n" );
    index_extensions($d);
    local $Lazysite::Manager::Extensions::DOCROOT = $d;
    local @INC = grep { ref || !m{/extensions/[A-Za-z0-9_-]+/lib\z} } @INC;
    my $r = action_extension_enable('extensions/app-offline.pl');
    ok( !$r->{ok}, 'enabling it with Odoo off is refused' );
    like( $r->{error} // '', qr/requires the extension 'odoo'/, '...naming Odoo' );

    my $both = site( on => [ 'odoo', 'app-offline' ] );
    like( run_processor( $both, '/page' ), qr{app-offline-kit\.js}, 'on with Odoo: the tag' );
    spit( "$both/lazysite/lazysite.conf", "site_name: T\nlayout: plain\nextensions:\n  - extensions/app-offline.pl\n" );
    spit( "$both/other.md", "---\ntitle: O\n---\n\nOther words.\n" );    # a page the cache has not seen
    my $html = run_processor( $both, '/other' );
    unlike( $html, qr{app-offline}, 'Odoo turned off afterwards: the variable renders nothing' );
    is( status_of( run_processor( $both, '/assets/app-offline-kit.js' ) ), 404, '...and the kit is not served' );
};

subtest 'no layout ships a script for it' => sub {
    my @hits;
    for my $f ( glob("$root/starter/lazysite/layouts/*/layout.tt"), glob("$root/starter/lazysite/templates/layouts/*/layout.tt") ) {
        open my $fh, '<', $f or next;
        local $/;
        my $t = <$fh>;
        close $fh;
        push @hits, $f if $t =~ /app-offline|LazysiteAppOffline/;
    }
    is_deeply( \@hits, [], 'a layout renders [% app_offline_kit %] and carries the slots; the script is the engine\'s' );
};

done_testing;
