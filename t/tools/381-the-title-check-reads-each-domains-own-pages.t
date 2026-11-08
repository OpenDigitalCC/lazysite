#!/usr/bin/perl
# n785 (SM1357 follow-up): `lazysite check`'s shared-title and missing-description
# checks read EACH DOMAIN'S OWN PAGE SET - the one its sitemap and llms.txt list
# (ruling 174, the processor's _public_page_set_listing) - not the whole docroot.
#
# On a deploy with a second domain under sites/, the check called `index.md` and
# `sites/<domain>/index.md` one shared title. Held here:
#
#   * two domains with the same titles give no warning;
#   * two pages of one domain with the same title give one, under that domain;
#   * a missing description is reported under its domain;
#   * a folder ruling 171 leaves out (under sites/, undeclared) is not counted,
#     and an alias with no content root of its own adds nothing.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $d = site_tempdir();
make_path( "$d/lazysite/$_" ) for qw(auth cache logs manager);
spit( "$d/lazysite/lazysite.conf", "site_name: A\nsite_url: https://a.example\n"
        . "alias_hosts: b.example, c.example\nalias.b.example.content_root: sites/b\n" );
# The primary domain.
spit( "$d/index.md",   "---\ntitle: Home\nsubtitle: Welcome to A\n---\nH\n" );
spit( "$d/contact.md", "---\ntitle: Contact\nsubtitle: Write to A\n---\nC\n" );
spit( "$d/twin-a.md",  "---\ntitle: Twin\nsubtitle: one\n---\nA\n" );
spit( "$d/twin-b.md",  "---\ntitle: twin\nmeta_desc: two\n---\nB\n" );
# b.example: the same titles as the primary's, and one page with no description.
spit( "$d/sites/b/index.md",   "---\ntitle: Home\nsubtitle: Welcome to B\n---\nH\n" );
spit( "$d/sites/b/contact.md", "---\ntitle: Contact\nsubtitle: Write to B\n---\nC\n" );
spit( "$d/sites/b/about.md",   "---\ntitle: About\n---\nA\n" );
# Ruling 171: another site's folder, undeclared - not the primary's pages.
spit( "$d/sites/old/index.md", "---\ntitle: Twin\n---\nO\n" );

my $out = qx($^X \Q$script\E --docroot \Q$d\E 2>&1);

unlike( $out, qr/title\(s\) are shared[^\n]*(?:contact|sites\/b|\/ and)/,
    'two domains with the same titles: no warning' ) or diag $out;
like( $out, qr/a\.example: 1 title\(s\) are shared by more than one public page: \/twin-a and \/twin-b - /,
    'two pages of one domain with the same title: one warning, under the domain' );
like( $out, qr/b\.example: 1 public page\(s\) have no description: \/about - /,
    'a missing description is reported under its domain' );
unlike( $out, qr/a\.example: [^\n]*no description/, 'and not under the other' );
unlike( $out, qr/(?:shared|no description)[^\n]*old/, 'a folder ruling 171 leaves out is not counted' );
unlike( $out, qr/c\.example/, 'an alias with no content root of its own adds nothing' );

done_testing();
