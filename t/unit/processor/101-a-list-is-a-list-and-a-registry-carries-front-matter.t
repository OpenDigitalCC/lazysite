#!/usr/bin/perl
# P12/P13 (WORK-PLAN-0154, ruled 2026-10-12 "Full front matter + general
# lists").
#
# P13: a YAML list other than `tags` arrived as raw text - `categories:` with
# `- item` lines reached the scan as `- "Perl Foundation"`. Any block or flow
# list of scalars is now a list, in the scan object, the registry object and the
# page's own stash (page_<key>); the engine's own keys keep their own readings.
#
# P12: a registry object carried seven fields. It now carries the page's other
# front matter as a scan object does, and its tags, less the engine-private keys
# (_front_matter_private) - a registry is a static file served to anyone.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir run_processor);

my $d = site_tempdir();
setup_minimal_site($d);
make_path( "$d/post", "$d/lazysite/templates/registries" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $POST = <<'MD';
---
title: First
date: 2026-01-02
author: Ann
categories:
  - "Perl Foundation"
  - news
keywords: [grants, 'the fund', "x y"]
tags: [a, b]
links:
  - name: home
    url: /
empty: []
form: [contact]
payment: none
register:
  - posts.json
---
CATS=[% page_categories.join('|') %] KW=[% page_keywords.join('|') %] AUTHOR=[% page_author %]
MD
spit( "$d/post/first.md", $POST );

# A page held back by auth_groups (SM980/SM993: a signed-in reader is asked
# for). It names the same registry and category, so the scan and registry
# below show it is left out for an anonymous reader.
my $MEMBERS = <<'MD';
---
title: Members
categories:
  - news
auth_groups:
  - editors
register:
  - posts.json
---
held back
MD
spit( "$d/post/members.md", $MEMBERS );

load_processor($d);
my ($meta)    = main::parse_yaml_front_matter($POST);
my ($members) = main::parse_yaml_front_matter($MEMBERS);

subtest 'a block or flow list of scalars is a list' => sub {
    is_deeply( $meta->{categories}, [ 'Perl Foundation', 'news' ], 'a block list, quotes stripped' );
    is_deeply( $meta->{keywords}, [ 'grants', 'the fund', 'x y' ], 'a flow list, quotes stripped' );
    is_deeply( $meta->{tags},  [ 'a', 'b' ], 'tags as a flow list too' );
    is_deeply( $meta->{empty}, [],           'an empty flow list is an empty list' );
    ok( !ref $meta->{links}, 'a list of mappings is not a list of scalars: left as it was read' );
    is( $meta->{author}, 'Ann', 'a scalar is a scalar' );
};

subtest 'the engine\'s keys keep their own readings' => sub {
    ok( !ref $meta->{form}, 'form: [contact] is not made a list' );
    is( $meta->{form}, 'contact', '...and reads as the form sanitiser always read it' );
    is_deeply( $members->{auth_groups}, ['editors'], 'auth_groups keeps its own reader' );
    is( $meta->{payment}, 'none', 'payment is a scalar' );
    is_deeply( $meta->{register}, ['posts.json'], 'register keeps its own reader' );
};

subtest 'the page\'s own stash carries the list' => sub {
    my $o = run_processor( $d, '/post/first' ) // '';
    like( $o, qr/CATS=Perl Foundation\|news /, 'page_categories is a list' );
    like( $o, qr/KW=grants\|the fund\|x y /,   'page_keywords is a list' );
    like( $o, qr/AUTHOR=Ann/,                  'a scalar as before' );
};

subtest 'a scan object carries the list, and filter= matches an item' => sub {
    spit( "$d/scan.md", "---\ntitle: S\ntt_page_var:\n  posts: scan:/post/*.md filter=categories:news\n---\n"
            . "N=[% posts.size %] [% FOREACH p IN posts %]C=[% p.categories.join('|') %][% END %]\n" );
    my $o = run_processor( $d, '/scan' ) // '';
    like( $o, qr/N=1 C=Perl Foundation\|news/,
        'listed by an item of its list; the held-back page is not listed to an anonymous reader' );
};

subtest 'a registry object carries the page\'s front matter, less the engine-private keys' => sub {
    spit( "$d/lazysite/templates/registries/posts.json.tt",
        "[% FOREACH p IN pages %]KEYS=[% p.keys.sort.join(',') %]\n"
            . "AUTHOR=[% p.author %] CATS=[% p.categories.join('|') %] TAGS=[% p.tags.join('|') %]\n[% END %]" );
    my $o = run_processor( $d, '/posts.json' ) // '';
    like( $o, qr/AUTHOR=Ann /,                 'a custom scalar' );
    like( $o, qr/CATS=Perl Foundation\|news /, 'a custom list' );
    like( $o, qr/TAGS=a\|b/,                   'and the tags, as a list' );
    my @objects = $o =~ /^KEYS=/mg;
    is( scalar @objects, 1, 'one object: the page held back by auth_groups is not in the registry' );
    my ($keys) = $o =~ /KEYS=(\S+)/;
    ok( defined $keys, 'the object was rendered' ) or return;
    my %k = map { $_ => 1 } split /,/, $keys;
    ok( $k{$_}, "carries $_" ) for qw(url title date register meta_desc meta_title tags author categories keywords);
    ok( !$k{$_}, "does not publish $_" ) for qw(form payment);
};

done_testing();
