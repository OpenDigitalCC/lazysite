#!/usr/bin/perl
# SM1288: THE STARTER /forgot.md AND /search-results.md LOSE THEIR INLINE
# <style> ON EXISTING SITES TOO - when the site never changed them.
#
# Ruling 12 moved the rules of both pages to the fallback chrome. They are seed
# files (ADR 0004), so an upgrade overwrites a copy whose bytes still match what
# the install state recorded and preserves one that differs. As SM1251's
# t/tools/211 did for the contact page, that is run here, not assumed:
#
#   - a site holding the 0.16.1 pages exactly as shipped is upgraded to the new
#     pages, with no <style> in either;
#   - a site that changed its copies keeps every byte of both, and is told so.
#
# The 0.16.1 pages are embedded VERBATIM and their checksums asserted, so the
# fixture is the files real sites have rather than something shaped like them.
# (The engine's own login, forgot and claim pages are the code bucket and are
# replaced on every upgrade; nothing on a site's side keeps the old ones.)
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(sha256_hex);
use JSON::PP    qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard site_tempdir);

my $ROOT     = repo_root();
my $MF_GUARD = repo_manifest_guard();

my $OLD_FORGOT = <<'END_OLD_FORGOT';
---
provenance: lazysite-starter
starter_role: infrastructure
title: Reset your password
auth: none
search: false
---

<style>
  .reset-form {
    max-width: min(440px, 100%);
    margin: 1rem 0;
    display: grid;
    grid-template-columns: 9rem 1fr;
    gap: 0.6rem 0.75rem;
    align-items: center;
  }
  .reset-form label { text-align: right; }
  .reset-form input[type="text"] {
    width: 100%; max-width: 100%; box-sizing: border-box;
    padding: 0.4rem 0.55rem; border: 1px solid #ccc; border-radius: 3px; font: inherit;
  }
  .reset-form .reset-submit { grid-column: 2; }
  .reset-form button {
    padding: 0.45rem 1.25rem; font: inherit; cursor: pointer;
    border: 1px solid #0056b3; background: #0056b3; color: #fff; border-radius: 3px;
  }
  .reset-form button:hover { background: #003d80; border-color: #003d80; }
</style>

<p>Enter your username or email. If an interactive account with an email on
file matches, a one-time link to set a new password is sent. This link works
once and expires in 24 hours.</p>

<!-- SM361: THIS IS A SYSTEM PAGE, AND THE EXCEPTION TO A RULE YOU SHOULD OTHERWISE FOLLOW.

     The authoring briefing tells every agent never to hand-author form HTML,
     and it is right. Content forms are native: use create_form, or a :::form
     block bound to an operator-vetted handler.

     This form is different because it posts to the AUTH CGI. Native forms bind
     to content handlers, which store submissions and notify - they cannot
     perform authentication, and making them able to would be a considerably
     worse idea than this page.

     So: do not copy this pattern into ordinary content. If you are reading the
     starter pages to learn the conventions, the convention is create_form. This
     is the narrow exception, and it says so here because a rule contradicted
     without comment by a shipped example teaches the contradiction.
-->
<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=forgot" class="reset-form">
  <label for="identifier">Username or email</label>
  <input type="text" name="identifier" id="identifier" required autocomplete="username">

  <div class="reset-submit">
    <button type="submit">Send reset link</button>
  </div>
</form>
END_OLD_FORGOT

my $OLD_SEARCH = <<'END_OLD_SEARCH';
---
provenance: lazysite-starter
starter_role: infrastructure
title: Search Results
search: false
query_params:
  - q
---

<div id="search-container" data-query="[% query.q %]">
<style>
.search-result { border-bottom: 1px solid #eee; padding: 1rem 0; margin-bottom: 0.5rem; }
.search-result h2 { font-size: 1.1rem; margin: 0 0 0.3rem; }
.search-result h2 a { text-decoration: none; }
.search-result h2 a:hover { text-decoration: underline; }
.search-subtitle { color: #666; margin: 0.2rem 0; font-size: 0.95rem; }
.search-excerpt { margin: 0.4rem 0; font-size: 0.9rem; line-height: 1.5; }
.search-tags { margin: 0.3rem 0; }
.search-tag { display: inline-block; background: #f0f0f0; border-radius: 3px; padding: 0.1rem 0.4rem; font-size: 0.8rem; margin-right: 0.3rem; }
.search-date { color: #888; font-size: 0.8rem; }
mark { background: #fff3cd; padding: 0.1em 0; }
#search-status { color: #666; margin: 0.5rem 0; font-size: 0.9rem; }
</style>
  <div id="search-status"></div>
  <div id="search-results"></div>
</div>

<script>
(function() {
  // --- Configuration ---
  var INDEX_URL   = '/search-index';
  var MAX_RESULTS = 20;
  var EXCERPT_LEN = 200;

  // --- State ---
  var index = null;

  // --- Markdown stripping ---
  function stripMarkdown(text) {
    return text
      .replace(/^---[\s\S]*?---\n?/, '')
      .replace(/^#+\s+/gm, '')
      .replace(/\*\*(.+?)\*\*/g, '$1')
      .replace(/\*(.+?)\*/g, '$1')
      .replace(/`{1,3}[^`\n]*`{1,3}/g, '')
      .replace(/^```[\s\S]*?```$/gm, '')
      .replace(/^:::[^\n]*/gm, '')
      .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      .replace(/!\[[^\]]*\]\([^)]+\)/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // --- Highlighting ---
  function highlight(text, terms) {
    var escaped = terms.map(function(t) {
      return t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    });
    var re = new RegExp('(' + escaped.join('|') + ')', 'gi');
    return text.replace(re, '<mark>$1</mark>');
  }

  // --- Scoring ---
  function score(page, terms) {
    var s = 0;
    var title    = (page.title    || '').toLowerCase();
    var subtitle = (page.subtitle || '').toLowerCase();
    var body     = stripMarkdown(page.excerpt || '').toLowerCase();
    var tags     = (page.tags     || []).join(' ').toLowerCase();

    for (var i = 0; i < terms.length; i++) {
      var t = terms[i].toLowerCase();
      if (title.indexOf(t) !== -1)    s += 10;
      if (subtitle.indexOf(t) !== -1) s += 5;
      if (tags.indexOf(t) !== -1)     s += 4;
      var headings = (page.excerpt || '')
        .split('\n')
        .filter(function(l) { return /^#+\s/.test(l); })
        .join(' ')
        .toLowerCase();
      if (headings.indexOf(t) !== -1) s += 3;
      if (body.indexOf(t) !== -1)     s += 1;
    }
    return s;
  }

  // --- Excerpt extraction ---
  function getExcerpt(page, terms) {
    var body = stripMarkdown(page.excerpt || '');
    if (!body) return '';

    var lower = body.toLowerCase();
    for (var i = 0; i < terms.length; i++) {
      var idx = lower.indexOf(terms[i].toLowerCase());
      if (idx !== -1) {
        var start = Math.max(0, idx - 60);
        var end   = Math.min(body.length, idx + EXCERPT_LEN);
        var excerpt = body.slice(start, end);
        if (start > 0) excerpt = '...' + excerpt;
        if (end < body.length) excerpt += '...';
        return excerpt;
      }
    }

    return body.slice(0, EXCERPT_LEN) +
      (body.length > EXCERPT_LEN ? '...' : '');
  }

  // --- Render results ---
  function renderResults(results, terms, query) {
    var container = document.getElementById('search-results');
    var status    = document.getElementById('search-status');

    if (!results.length) {
      status.textContent = 'No results for "' + query + '".';
      container.innerHTML = '';
      return;
    }

    status.textContent = results.length + ' result' +
      (results.length === 1 ? '' : 's') + ' for "' + query + '"';

    container.innerHTML = results.map(function(r) {
      var excerpt = getExcerpt(r.page, terms);
      var title   = highlight(r.page.title || r.page.url, terms);
      var exh     = highlight(excerpt, terms);
      var tags    = (r.page.tags || [])
        .map(function(t) { return '<span class="search-tag">' + t + '</span>'; })
        .join(' ');

      return '<article class="search-result">' +
        '<h2><a href="' + r.page.url + '">' + title + '</a></h2>' +
        (r.page.subtitle
          ? '<p class="search-subtitle">' + r.page.subtitle + '</p>'
          : '') +
        (exh ? '<p class="search-excerpt">' + exh + '</p>' : '') +
        (tags ? '<p class="search-tags">' + tags + '</p>' : '') +
        (r.page.date
          ? '<time class="search-date">' + r.page.date + '</time>'
          : '') +
        '</article>';
    }).join('');
  }

  // --- Main search ---
  function runSearch() {
    var query = searchQuery;
    var status = document.getElementById('search-status');

    if (!query) {
      status.textContent = '';
      document.getElementById('search-results').innerHTML = '';
      return;
    }

    var terms = query.split(/\s+/).filter(Boolean);

    function doSearch() {
      var scored = index
        .map(function(page) {
          return { page: page, score: score(page, terms) };
        })
        .filter(function(r) { return r.score > 0; })
        .sort(function(a, b) { return b.score - a.score; })
        .slice(0, MAX_RESULTS);

      renderResults(scored, terms, query);
    }

    if (index) {
      doSearch();
      return;
    }

    status.textContent = 'Loading index...';

    fetch(INDEX_URL)
      .then(function(r) { return r.json(); })
      .then(function(data) {
        index = data;
        doSearch();
      })
      .catch(function() {
        status.textContent = 'Search unavailable.';
      });
  }

  // SM709: read the term from a data ATTRIBUTE, not interpolated into this
  // script. Inside <script> the browser decodes no HTML entities, so the
  // `| html %]` this used to carry escaped a value that was ALREADY escaped in
  // parse_query_string - a search for it's searched for it&amp;#39;s. In an
  // attribute the parser decodes the single escaping and hands JS the real
  // characters, which is why the attribute is the idiom and the filter is not.
  var searchQuery = (document.getElementById('search-container').dataset.query || '').trim();

  // Run search on page load
  document.addEventListener('DOMContentLoaded', function() {
    if (searchQuery) {
      runSearch();
    } else {
      document.getElementById('search-status').textContent = 'No search term provided.';
    }
  });
})();
</script>

END_OLD_SEARCH

my %OLD = ( 'forgot.md' => $OLD_FORGOT, 'search-results.md' => $OLD_SEARCH );
is( sha256_hex($OLD_FORGOT), 'd11afd1847e6e419ede54b4d8f4f6d3e153b9a93ed25d30f7082c42015ed9c93',
    'the forgot fixture is the 0.16.1 starter forgot.md byte for byte' );
is( sha256_hex($OLD_SEARCH), '3b4f895aca54d68705ead28a726365c852dc47d61c3fe0249926074970f1d42c',
    'the search fixture is the 0.16.1 starter search-results.md byte for byte' );
like( $OLD{$_}, qr/<style>/, "the 0.16.1 $_ carries the <style> block this change removes" ) for sort keys %OLD;

sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit  { my ( $p, $t ) = @_; open my $f, '>:raw', $p or die "$p: $!"; print {$f} $t; close $f }

my %SHIPPED = map { $_ => slurp("$ROOT/starter/$_") } keys %OLD;
unlike( $SHIPPED{$_}, qr/<style/i, "the starter $_ ships with no <style> block" ) for sort keys %OLD;

sub install {
    my ( $docroot, $cgibin, $mode ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my @cmd = ( $^X, "$ROOT/install.pl", '--docroot', $docroot, '--cgibin', $cgibin,
        '--mode', $mode, '--serving-group', ( getgrgid( $) + 0 ) // ( $) + 0 ) ) );
    my $cmd = join ' ', map {quotemeta} @cmd;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# A site as 0.16.1 left it: its two pages are %$pages, and the install state
# records the 0.16.1 pages as what was installed there. Then put it on edge and
# backdate the state, so the next run is the upgrade a release brings.
sub old_site {
    my ($pages) = @_;
    my $docroot = site_tempdir();
    ( my $cgibin = $docroot ) =~ s{/[^/]+\z}{/cgi-bin};
    make_path($cgibin);
    my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
    is( $rc, 0, 'the site is provisioned' ) or diag $out;

    my $sp    = "$docroot/lazysite/.install-state.json";
    my $state = decode_json( slurp($sp) );
    for my $f ( sort keys %$pages ) {
        spit( "$docroot/$f", $pages->{$f} );
        ok( exists $state->{files}{"$docroot/$f"}, "the state tracks $f" );
        $state->{files}{"$docroot/$f"} = 'sha256:' . sha256_hex( $OLD{$f} );
    }
    $state->{version} = '0.0.1';
    spit( $sp, encode_json($state) );

    my $conf = "$docroot/lazysite/lazysite.conf";
    my $c    = slurp($conf);
    $c =~ s/^update_channel:.*$/update_channel: edge/m or $c .= "update_channel: edge\n";
    spit( $conf, $c );
    return ( $docroot, $cgibin );
}

subtest 'unmodified 0.16.1 pages are refreshed by the upgrade' => sub {
    my ( $docroot, $cgibin ) = old_site( {%OLD} );
    my ( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
    is( $rc, 0, 'the upgrade ran' ) or diag $out;
    for my $f ( sort keys %OLD ) {
        my $now = slurp("$docroot/$f");
        is( $now, $SHIPPED{$f}, "$f is now the shipped page" );
        unlike( $now, qr/<style/i, "and has no <style> block" );
        unlike( $out, qr{- \Q$docroot\E/\Q$f\E}, "$f is not listed as preserved" );
    }
};

subtest 'customised pages are never touched' => sub {
    my %mine = (
        'forgot.md'         => $OLD_FORGOT =~ s/title: Reset your password/title: Forgotten password/r,
        'search-results.md' => $OLD_SEARCH =~ s/title: Search Results/title: Search/r,
    );
    isnt( $mine{$_}, $OLD{$_}, "the customised $_ differs from the shipped one" ) for sort keys %mine;
    my ( $docroot, $cgibin ) = old_site( \%mine );
    my ( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
    is( $rc, 0, 'the upgrade ran' ) or diag $out;
    for my $f ( sort keys %mine ) {
        is( slurp("$docroot/$f"), $mine{$f}, "the customised $f is byte-identical" );
        like( $out, qr{- \Q$docroot\E/\Q$f\E}, "and the upgrade says it preserved $f" );
    }
};

done_testing();
