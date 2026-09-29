#!/usr/bin/perl
# SM825: the source alternate - `<page>.md` serves the page's markdown.
#
# `llms.txt` has linked to `<page>.md` since SM299, and measured before this was
# built, every one of those URLs answered with the page's HTML, byte-for-byte
# identical to the rendering. The one registry whose whole purpose is to hand a
# machine the prose without markup around it pointed every client at markup.
#
# THE INTERESTING QUESTION IS WHAT IS WITHHELD, which is why this file spends
# most of its assertions there. Front matter carries access-control facts:
# `auth:` is on 27 of the 64 shipped pages. RULED 2026-09-29: an ALLOWLIST of
# title, subtitle and description - the three keys the rendering already
# publishes - and the emitter BUILDS its front matter from that list rather than
# filtering the input, so a key added next year is withheld without anybody
# remembering to withhold it.
#
# Driven through the real request path on a site with an ACL store, the same rig
# t/unit/processor/74 uses for SM797's denylist - the two are about the same
# question from opposite ends, and this one must not reopen what that one closed.
use strict;
use warnings;
use Test::More;
use Encode ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

my $d = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($d);
make_path("$d/lazysite/auth");
open my $af, '>', "$d/lazysite/auth/acls.json" or die $!;
print {$af} "{}\n";
close $af;

sub put {
    my ( $rel, $body ) = @_;
    open my $fh, '>:utf8', "$d/$rel" or die "$rel: $!";
    print {$fh} $body;
    close $fh;
}

# A page carrying one of EVERY key the audit found a verbatim `.md` would
# publish for the first time, so the withholding assertions below are about a
# real shape rather than a convenient one.
put( 'open.md', <<'MD' );
---
title: "Open: a page"
subtitle: A live [% client_ip %] subtitle
description: What this page is
auth: none
auth_groups: SECRET-GROUP-NAME
query_params:
  - SECRET-PARAM
tt_page_var:
  p: SECRET-BINDING
payment_address: SECRET-PAYMENT-ADDRESS
form: SECRET-FORM-NAME
api: false
---

# The heading

THE-PROSE-ANYONE-MAY-READ
MD
put( 'gated.md', "---\ntitle: Gated\nauth: required\n---\n\nGATED-PROSE\n" );
put( 'bare.md',  "Just prose, no front matter at all.\n" );
# Non-ASCII written as EXPLICIT codepoints, never as literal characters in this
# file: without `use utf8` a literal `é` here is two Latin-1 characters, and the
# `:utf8` layer in put() then encodes each of them - a double-encoded fixture
# that fails against correct output and reads as an engine defect. It read that
# way on this file's first run.
put( 'accented.md',
    "---\ntitle: Caf\x{e9}\n---\n\nR\x{e9}sum\x{e9} of the caf\x{e9}.\n" );

sub fetch { return run_processor( $d, $_[0] ) // '' }

sub body_of {
    my ($r) = @_;
    $r =~ s/\A.*?\r?\n\r?\n//s;
    return $r;
}

subtest 'THE RIG CAN SEE THE DIFFERENCE AT ALL' => sub {
    # A "the secret is absent" check passes against an engine that serves
    # nothing, so prove the two URLs answer differently before asserting how.
    my $html = fetch('/open');
    my $md   = fetch('/open.md');
    like( $html, qr{Content-Type:\s*text/html}i, '/open is HTML' );
    like( $md, qr{Content-Type:\s*text/markdown}i, '/open.md is markdown' );
    isnt( $html, $md, 'and they are not the same answer' )
        or diag( 'Before SM825 these were byte-for-byte identical, which is the '
            . 'defect: llms.txt linked to .md and got HTML.' );
    like( body_of($md), qr/THE-PROSE-ANYONE-MAY-READ/, 'the prose is served' );
    like( body_of($md), qr/^# The heading$/m, 'as markdown, not as rendered HTML' );
    unlike( body_of($md), qr/<!DOCTYPE|<html/i, 'with no HTML anywhere in it' );
};

subtest 'THE ALLOWLIST: three keys travel' => sub {
    my $b = body_of( fetch('/open.md') );
    like( $b, qr/^title:\s*"Open: a page"$/m,
        'title, and QUOTED - a colon in a title is ordinary' )
        or diag( 'An unquoted value makes the alternate\'s YAML validity depend '
            . 'on the author\'s punctuation.' );
    like( $b, qr/^description:\s*"What this page is"$/m, 'description' );
    like( $b, qr/^subtitle:\s*"[^"]*subtitle"$/m,         'subtitle' );
    # The DECLARED order, because this is a document somebody may diff between
    # two requests; a hash order would churn.
    my @order = $b =~ /^(title|subtitle|description):/mg;
    is_deeply( \@order, [qw(title subtitle description)],
        'in the declared order, not the hash\'s' );
};

subtest 'AND EVERYTHING ELSE IS WITHHELD' => sub {
    my $b = body_of( fetch('/open.md') );
    # Each of these is a real key on a real shipped page, named in the audit.
    for my $secret (
        [ 'SECRET-GROUP-NAME',       'auth_groups - the name of a group' ],
        [ 'SECRET-PARAM',            'query_params - the prefill allowlist' ],
        [ 'SECRET-BINDING',          'tt_page_var - the data bindings' ],
        [ 'SECRET-PAYMENT-ADDRESS',  'payment_address' ],
        [ 'SECRET-FORM-NAME',        'form - hence the handler binding' ],
        )
    {
        unlike( $b, qr/\Q$secret->[0]\E/, "withheld: $secret->[1]" );
    }
    unlike( $b, qr/^auth:/m, 'withheld: auth - whether the page is gated, and how' )
        or diag( '`auth:` is in the front matter of 27 of the 64 shipped pages, '
            . 'which is why this is an allowlist and not a denylist.' );
    unlike( $b, qr/^api:/m, 'withheld: api - that the page is a raw endpoint' );

    # AND THE ALLOWLIST IS AN ALLOWLIST, not a list of things to strip: a key
    # nobody has thought of is withheld with no code change. This is the
    # assertion that would fail if somebody rewrote the emitter as a filter.
    put( 'future.md', "---\ntitle: Future\nsome_key_invented_later: SECRET-FUTURE\n"
            . "---\n\nProse.\n" );
    my $f = body_of( fetch('/future.md') );
    like( $f, qr/^title:\s*"Future"$/m, 'the allowlisted key still travels' );
    unlike( $f, qr/SECRET-FUTURE|some_key_invented_later/,
        'and a key added later is withheld by default, with nobody deciding to' );
};

subtest 'A TT DIRECTIVE IN AN ALLOWLISTED VALUE DOES NOT TRAVEL AS ONE' => sub {
    # One shipped page carries `[% client_ip %]` inside its subtitle. Emitting
    # the delimiters would put a template expression into a file another tool
    # may process; the same helper the `register:` list uses handles it.
    my $b = body_of( fetch('/open.md') );
    unlike( $b, qr/\[%/, 'no opening delimiter' );
    unlike( $b, qr/%\]/, 'no closing delimiter' );
};

subtest 'THE GATE IS THE PAGE OWN, because this IS the render path' => sub {
    my $r = fetch('/gated.md');
    like( $r, qr/^Status: 302/m, 'a page behind auth: required redirects' )
        or diag( 'The alternate must be refused on exactly the terms the '
            . 'rendering is refused on - the SM460 shape is a gated page with a '
            . 'world-readable source.' );
    unlike( body_of($r), qr/GATED-PROSE/, 'and its prose does not leave' );
    # The discriminator: the same rig DOES serve an ungated page's alternate,
    # so the refusal above is the gate and not a broken emitter.
    like( body_of( fetch('/open.md') ), qr/THE-PROSE/,
        'while an ungated page\'s alternate is served' );
};

subtest 'A DRAFT IS A DRAFT ON THIS PATH TOO' => sub {
    # `draft:` is NOT a front-matter key - _acl_is_draft reads an acls.json
    # entry - which is worth stating because t/unit/processor/74's fixture writes
    # `draft: true` into front matter and calls the body SECRET-DRAFT-BODY. That
    # page was never a draft by the engine's definition, and its prose was public
    # through the RENDERING before this emitter existed. A real draft is a store
    # entry, and it is refused by _acl_refused well before the emitter runs.
    my $store = "$d/lazysite/auth/acls.json";
    open my $w, '>', $store or die $!;
    print {$w} '{"unfinished.md":{"draft":true}}';
    close $w;
    put( 'unfinished.md', "---\ntitle: Unfinished\n---\n\nUNFINISHED-PROSE\n" );

    my $md = fetch('/unfinished.md');
    unlike( $md, qr/UNFINISHED-PROSE/, 'a draft page has no source alternate' )
        or diag( 'The alternate must be refused on the same terms as the '
            . 'rendering, and a draft is one of those terms.' );
    # The discriminator: the SAME store still serves the ungated page, so the
    # refusal above is the draft entry rather than a broken fixture.
    like( fetch('/open.md'), qr/THE-PROSE/,
        'while a page with no draft entry still has one' );
    # And the rendering agrees, which is the point - one decision, not two.
    unlike( fetch('/unfinished'), qr/UNFINISHED-PROSE/,
        'the rendering refuses it too, on the same store entry' );

    open my $r, '>', $store or die $!;
    print {$r} "{}\n";
    close $r;
};

subtest 'SM797 STAYS CLOSED: a doubled extension is still not source' => sub {
    # `/page.md.md` collapses to the same page, so answering it with source
    # would reopen the door SM797 shut through a new hole. Exactly one `.md`.
    my $r = fetch('/open.md.md');
    like( $r, qr{Content-Type:\s*text/html}i,
        'the doubled extension gets the rendering, not the source' );
    unlike( body_of($r), qr/^---$/m, 'no front matter block' );
    my $g = fetch('/gated.md.md');
    unlike( body_of($g), qr/GATED-PROSE/, 'and it is no way around the gate either' );
};

subtest 'the alternate is not indexed and is not cached' => sub {
    my $r = fetch('/open.md');
    like( $r, qr/^X-Robots-Tag:.*noindex/mi,
        'noindex - the rendering is the thing to index' );
    like( $r, qr/^Cache-Control:.*no-store/mi, 'and no-store at the edge' )
        or diag( 'The engine cache is keyed on the collapsed path, so /page and '
            . '/page.md share one slot and it must hold neither of them.' );

    # THE CACHE POISONING THIS GUARDS, asserted rather than described: fetch the
    # alternate first, then the page, and the page must still be HTML. If the
    # emitter ran after try_serve_cache, the markdown would be in the HTML slot.
    fetch('/open.md');
    my $html = fetch('/open');
    like( $html, qr{Content-Type:\s*text/html}i,
        'the page is still HTML after its alternate was fetched' );
    like( body_of($html), qr/<!DOCTYPE html>/i, 'and still a rendering' );
};

subtest 'a page with no front matter, and one with accents' => sub {
    my $b = body_of( fetch('/bare.md') );
    like( $b, qr/Just prose, no front matter at all/, 'the prose is served' );
    unlike( $b, qr/\A---/, 'and no empty front-matter block is invented' );

    my $a = fetch('/accented.md');
    like( $a, qr{charset=utf-8}i, 'the alternate declares utf-8' );
    # run_processor hands back the BYTES the engine wrote, so they are decoded
    # here before being compared with characters. Asserting a character class
    # against undecoded bytes fails on correct output, which is how this
    # subtest read on its first run.
    my $chars = Encode::decode( 'UTF-8', body_of($a), Encode::FB_CROAK() );
    like( $chars, qr/Caf\x{e9}/, 'and a non-ASCII title survives as UTF-8' )
        or diag( 'A mojibake title is what a second encoding pass looks like - '
            . 'SM904 is the same fault on the way in.' );
    like( $chars, qr/R\x{e9}sum\x{e9} of the caf\x{e9}/, 'as does the prose' );
};

done_testing();
