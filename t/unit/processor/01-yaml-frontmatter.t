#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- basic front matter ---
{
    my $md = "---\ntitle: Test Page\nsubtitle: A subtitle\n---\nContent here.\n";
    my ( $meta, $body ) = main::parse_yaml_front_matter($md);
    is( $meta->{title},    'Test Page',      'title parsed' );
    is( $meta->{subtitle}, 'A subtitle',     'subtitle parsed' );
    is( $body,             "Content here.\n",'body extracted' );
}

# --- register list ---
{
    my $md = "---\ntitle: Test\nregister:\n  - sitemap.xml\n  - llms.txt\n---\n";
    my ( $meta, $body ) = main::parse_yaml_front_matter($md);
    is_deeply( $meta->{register}, [ 'sitemap.xml', 'llms.txt' ], 'register list parsed' );
}

# --- tt_page_var block ---
{
    my $md = "---\ntitle: Test\ntt_page_var:\n  version: 1.0\n  beta: true\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is( $meta->{tt_page_var}{version}, '1.0', 'tt_page_var scalar' );
    is( $meta->{tt_page_var}{beta},    'true','tt_page_var second key' );
}

# --- tags list ---
{
    my $md = "---\ntitle: Test\ntags:\n  - authoring\n  - api\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is_deeply( $meta->{tags}, [ 'authoring', 'api' ], 'tags list parsed' );
}

# --- auth keys ---
{
    my $md = "---\ntitle: Test\nauth: required\nauth_groups:\n  - admins\n  - editors\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is( $meta->{auth}, 'required', 'auth key parsed' );
    is_deeply( $meta->{auth_groups}, [ 'admins', 'editors' ], 'auth_groups parsed' );
}

# --- query_params list ---
{
    my $md = "---\ntitle: Test\nquery_params:\n  - q\n  - page\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is_deeply( $meta->{query_params}, [ 'q', 'page' ], 'query_params parsed' );
}

# --- payment front matter ---
{
    my $md = "---\ntitle: Test\npayment: required\npayment_amount: 0.01\npayment_currency: USD\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is( $meta->{payment},          'required', 'payment key parsed' );
    is( $meta->{payment_amount},   '0.01',     'payment_amount parsed' );
    is( $meta->{payment_currency}, 'USD',      'payment_currency parsed' );
}

# --- no front matter ---
{
    my $md = "Just content, no front matter.\n";
    my ( $meta, $body ) = main::parse_yaml_front_matter($md);
    is( $meta->{title}, undef, 'no title when no front matter' );
    is( $body, $md, 'body returned unchanged when no front matter' );
}

# --- empty body ---
{
    my $md = "---\ntitle: Test\n---\n";
    my ( $meta, $body ) = main::parse_yaml_front_matter($md);
    is( $body, '', 'empty body' );
}

# --- TT directives stripped from scalar values ---
{
    my $md = "---\ntitle: [% malicious %]\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    unlike( $meta->{title}, qr/\[%/, 'TT opening stripped from front matter' );
    unlike( $meta->{title}, qr/%\]/, 'TT closing stripped from front matter' );
}

# --- auth invalid value normalised to 'none' ---
{
    my $md = "---\ntitle: Test\nauth: bogus\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    is( $meta->{auth}, 'none', 'invalid auth value normalised to none' );
}

# --- form name sanitised ---
{
    my $md = "---\ntitle: Test\nform: contact/evil\n---\n";
    my ( $meta ) = main::parse_yaml_front_matter($md);
    unlike( $meta->{form}, qr{/}, 'form name loses slash' );
}

done_testing();
