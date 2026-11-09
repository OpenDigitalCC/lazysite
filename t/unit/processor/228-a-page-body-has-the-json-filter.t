#!/usr/bin/perl
# n785 (T-114, the 0.16.8 edge results): `[% page_url_raw | json %]` in a PAGE
# BODY left the whole body unprocessed - the directive shown as written - and
# write_file said nothing. The `json` filter was a layout's and a component's
# only, and a filter the body render does not have fails the whole body at
# render, where the engine falls back to the raw source.
#
#   * a page body has `| json` (render.pm _tt_engine), the same _json_filter;
#   * the body's filter list and Lazysite::Manager::Common's @PAGE_BODY_FILTERS,
#     which the save-time check reads, are the same list;
#   * a filter a page body does not have - in a branch that runs or not - is an
#     issue, named with its line: refused on save (page_parse_refusal, the one
#     write path for the editor, the control API and MCP) and reported by
#     validate_page (Lazysite::Validate::validate_content).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(run_processor setup_test_site site_tempdir repo_root);
use Lazysite::Manager::Common ();
use Lazysite::Validate qw(validate_content);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

subtest 'a page body has | json' => sub {
    my $d = site_tempdir();
    setup_test_site($d);
    spit( "$d/lazysite/lazysite.conf", "site_name: Test\nsite_url: https://site.test\nlayout: test\n" );
    spit( "$d/zz-json.md", "---\ntitle: J\n---\nBefore [% site_name %].\n\n"
            . qq{<script type="application/ld+json">{"url":[% page_url_raw | json %]}</script>\n} );
    my $out = run_processor( $d, '/zz-json' );
    unlike( $out, qr/\[%/, 'no directive is left as written' ) or diag $out;
    like( $out, qr/Before Test\./, 'the rest of the body renders' );
    like( $out, qr/\{"url":"https:\/\/site\.test\/zz-json"\}/, 'the address is a JSON string' );
};

subtest 'the body filter list is the one the save check reads' => sub {
    open my $fh, '<', repo_root() . '/lazysite-processor/render.pm' or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($engine) = $src =~ /sub _tt_engine \{(.*?)\n\}/s;
    my ($filters) = ( $engine // '' ) =~ /FILTERS\s*=>\s*\{([^}]*)\}/;
    my @keys = sort( ( $filters // '' ) =~ /(\w+)\s*=>/g );
    is_deeply( \@keys, [ sort @Lazysite::Manager::Common::PAGE_BODY_FILTERS ], 'render.pm and @PAGE_BODY_FILTERS agree' );
};

subtest 'a filter a body does not have is named, on save and by validate' => sub {
    my $page = "---\ntitle: M\n---\nIntro.\n\n[% IF never %]\n[% x | markdown %]\n[% END %]\n[% y | json %] [% z | html %]\n";
    my @i = Lazysite::Manager::Common::page_parse_issues( ( split /---\n/, $page, 3 )[2], 3 );
    is( scalar @i, 1, 'one issue: markdown (json and html are a body\'s)' );
    like( $i[0]{message} // '', qr/the filter `markdown`, which a page body does not have/, 'it names the filter' );
    is( $i[0]{line}, 7, 'at its file line, in a branch that never runs' );

    my @r = Lazysite::Manager::Common::page_parse_refusal( 'zz.md', $page );
    ok( @r, 'the save is refused' );
    like( $r[1] // '', qr/markdown: filter not found/, 'and the refusal names the error' );

    my $v = validate_content( content => $page );
    ok( !$v->{valid}, 'validate_page says the page is not valid' );
    ok( ( grep { ( $_->{message} // '' ) =~ /`markdown`/ } @{ $v->{issues} } ), 'and names the filter' );

    my $ok = "---\ntitle: J\n---\n[% page_url_raw | json %] [% u | url_safe %] [% t | truncate(5) %]\n";
    ok( !Lazysite::Manager::Common::page_parse_refusal( 'ok.md', $ok ), 'a body using only its own filters is accepted' );
};

done_testing();
