#!/usr/bin/perl
# SM1104: an info mark's note is visible on keyboard focus.
#
# The 0.15.6/0.15.7 test plan, row N4: "47 info marks over 11 extension forms,
# each with its note in title and aria-label and tabindex 0 ... FAIL on
# 'tabbing shows the text': :focus only recolours the mark, so a sighted
# keyboard user never sees the note - it shows on mouse hover (native title)
# and to screen readers only."
#
# What this holds:
#
# - renderForm and the Extensions row draw the mark with its note in
#   data-note (escaped) as well as aria-label, and no title (the native
#   tooltip would show the text a second time beside the drawn one)
# - each manager stylesheet shows data-note as generated content on :hover and
#   :focus-visible, with an empty alt so a screen reader does not read it twice
# - in a real browser, focusing the mark makes the note appear, and a mark
#   that is neither hovered nor focused shows nothing
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
my @sheets = map {"$root/starter/lazysite/manager/assets/manager-$_.css"} qw(classic modern accessible);

for my $css (@sheets) {
    open my $fh, '<', $css or die "$css: $!";
    local $/;
    my $src = <$fh>;
    ( my $name = $css ) =~ s{.*/}{};
    like $src, qr/\.mg-info\[data-note\]:focus-visible::after[^{]*\{[^}]*content:\s*attr\(data-note\)/s,
        "$name: focus shows the note";
    like $src, qr/\.mg-info\[data-note\]:hover::after/, "$name: hover shows the same text";
    like $src, qr{content:\s*attr\(data-note\)\s*/\s*""}, "$name: the drawn copy has empty alt text";
}

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 2 unless length $node && -x $node;
    my $page = PageScript::page_source("$root/starter/manager/plugin-config.md");
    my $fns  = join "\n", map { PageScript::extract_function( $page, $_ ) } qw(esc renderForm);
    my $plugin = encode_json(
        {   id => 'x', _script => 'x.pl',
            config_schema => [ { key => 'a', label => 'Explained', type => 'text', note => 'Says "why" & <how>' } ],
        }
    );
    my $dir = File::Temp->newdir;
    open my $fh, '>', "$dir/t.js" or die "t.js: $!";
    print {$fh} $fns, "\nconsole.log(renderForm($plugin, {}));\n";
    close $fh;
    my $html = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    like $html, qr{<span class="mg-info" tabindex="0" role="img" aria-label="Says &quot;why&quot; &amp; &lt;how&gt;" data-note="Says &quot;why&quot; &amp; &lt;how&gt;">},
        'the config mark carries the escaped note in data-note';
    unlike $html, qr/\btitle=/, 'and no title that would show it twice';

    my $plugins = PageScript::page_source("$root/starter/manager/plugins.md");
    like $plugins, qr/class="mg-info"[^;]*data-note="'/, 'the Extensions row mark carries data-note too';
}

chomp( my $browser = `sh -c 'command -v chromium || command -v chromium-browser' 2>/dev/null` );
SKIP: {
    skip 'no chromium on this host: the note was NOT checked in a browser', scalar(@sheets) * 3 unless length $browser;
    my $dir = File::Temp->newdir;
    for my $css (@sheets) {
        ( my $name = $css ) =~ s{.*manager-(\w+)\.css}{$1};
        my $page = "$dir/$name.html";
        open my $o, '>', $page or die $!;
        print {$o} qq{<!doctype html><html><head><title>pending</title><link rel="stylesheet" href="file://$css"></head><body>
<label>Field <span id="a" class="mg-info" tabindex="0" role="img" aria-label="NOTE" data-note="The long explanation of the field">&#9432;</span></label>
<div class="mg-plugin-end" style="position:absolute;right:0;top:100px"><span id="b" class="mg-info" tabindex="0" role="img" aria-label="E" data-note="At the right edge, long enough to wrap rather than run off the page, which it must not do">&#9432;</span></div>
<script>
window.addEventListener('load', function () {
  var a = document.getElementById('a'), b = document.getElementById('b');
  function c(e) { return getComputedStyle(e, '::after').content; }
  var r = { idle: c(a) };
  a.focus(); r.focus = c(a);
  b.focus(); r.edge = c(b);
  var box = b.getBoundingClientRect();
  r.right = Math.round(window.innerWidth - box.right);
  document.title = JSON.stringify(r);
});
</script></body></html>};
        close $o;
        my $dom = `timeout 60 \Q$browser\E --headless=new --no-sandbox --disable-gpu --user-data-dir=\Q$dir/p-$name\E --virtual-time-budget=3000 --dump-dom file://\Q$page\E 2>/dev/null`;
        my ($t) = $dom =~ m{<title>(.*?)</title>}s;
        $t =~ s/&quot;/"/g if defined $t;
        my $r = eval { decode_json($t) } || {};
        unlike $r->{idle} // '', qr/explanation/, "$name: an idle mark shows nothing";
        like $r->{focus} // '', qr/The long explanation of the field/, "$name: focusing the mark shows its note";
        like $r->{edge} // '',  qr/At the right edge/, "$name: and at the right edge too";
    }
}

done_testing;
