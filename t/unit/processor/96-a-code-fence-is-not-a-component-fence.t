#!/usr/bin/perl
# P6 (WORK-PLAN-0154): a fenced code block that SHOWS `:::` syntax is shown.
#
# Reported writing a style guide: a ``` block holding `::: callout ... :::`
# rendered the component's output, escaped, inside the <pre> - the `:::` passes
# (form, components, divs, include, oembed) run before convert_fenced_code and
# each matches `:::` at the start of a line. The fenced blocks are now converted
# first and held out of those passes; a live fence outside code still works, and
# a code block inside a box is still a code block.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path("$docroot/lazysite/templates/components");
spit( "$docroot/lazysite/templates/components/callout.tt",
    qq(<aside class="callout">[% content %]</aside>\n) );
spit( "$docroot/partial.md", "PARTIAL-TEXT\n" );

spit( "$docroot/guide.md", <<'MD' );
---
title: Guide
---

::: callout
LIVE-CALLOUT
:::

```
::: callout
SHOWN-CALLOUT
:::
```

```md
::: note
SHOWN-DIV
:::
```

```
::: include
/partial.md
:::
```

```
:::form
name | text | Name
:::
```

::: note
Inside a box:

```
::: callout
BOXED-EXAMPLE
:::
```
:::

::: callout
In a callout:

```
x < y
```
:::
MD

my $out = run_processor( $docroot, '/guide' ) // '';
my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
my ($main) = ( $body // '' ) =~ m{<main>(.*)</main>}s;
$main //= $body // '';
my @pre = $main =~ m{(<pre><code[^>]*>.*?</code></pre>)}gs;

sub pre_with { my ($marker) = @_; my ($p) = grep { index( $_, $marker ) >= 0 } @pre; return $p // '' }

subtest 'an example in a code fence is shown as written' => sub {
    like( pre_with('SHOWN-CALLOUT'), qr{<pre><code>::: callout\nSHOWN-CALLOUT\n:::\n</code></pre>},
        'a component example' );
    like( pre_with('SHOWN-DIV'), qr{<pre><code class="language-md">::: note\nSHOWN-DIV\n:::\n</code></pre>},
        'a box example, with its language' );
    like( pre_with('partial.md'), qr{::: include\n/partial\.md\n:::}, 'an include example' );
    unlike( $main, qr/PARTIAL-TEXT/, 'and the include was not made' );
    like( pre_with('name | text'), qr{:::form\nname \| text \| Name\n:::}, 'a form example' );
    unlike( $main,            qr/<form\b/,           'and no form was rendered' );
    unlike( join( '', @pre ), qr/&lt;(?:aside|div)/, 'no code block holds rendered markup' );
};

subtest 'the fences outside code still work' => sub {
    like( $main, qr{<aside class="callout"><p>LIVE-CALLOUT</p></aside>}, 'a live component' );
    like( $main, qr{<div class="note">.*?Inside a box:.*?BOXED-EXAMPLE.*?</div>}s, 'a live box' );
};

subtest 'a code block inside a box is still a code block' => sub {
    like( pre_with('BOXED-EXAMPLE'), qr{<pre><code>::: callout\nBOXED-EXAMPLE\n:::\n</code></pre>},
        'in a box, shown as written' );
    like( $main, qr{<aside class="callout">.*?<pre><code>x &lt; y\n</code></pre>.*?</aside>}s,
        'in a component, escaped' );
    unlike( $main, qr{<p>\s*<pre>|</pre>\s*</p>}, 'and no code block is wrapped in a paragraph' );
    unlike( $main, qr/LZSCODE/,                   'no placeholder is left in the page' );
};

done_testing;
