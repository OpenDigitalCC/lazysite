#!/usr/bin/perl
# SM635: a held-back row says so where the operator is looking.
#
# The operator's report: the Protected sections card said `protect-test` was
# gated - 2 pages, 1 asset - and the row's own expansion did not reflect it.
#
# TWO CAUSES, and the first is the one the eye lands on. A FOLDER rendered an
# EMPTY Access cell by construction:
#
#     html += '<td class="mg-col-access">' + (isDir ? '' : accessBadge(f)) + '</td>';
#
# so the one row that most needed to say "held back" was the one row that said
# nothing at all. And protectionFor() answered only for directories, on an exact
# prefix match - so everything INSIDE a protected folder reported nothing, while
# the entire point of a section rule is that it covers what is beneath it. An
# operator standing on a gated page was told nothing, which reads as "public".
#
# THE CARD IS GONE, as asked, and two things had to move with it rather than
# vanish: the Publish / Remove-protection controls it carried were the only ones
# on the page, and the fetch that filled it also fills the map the LISTING
# reads - it returned early when the card's elements were missing, so deleting
# the markup alone would have blanked every padlock while still fetching the
# data.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $page = "$FindBin::Bin/../../../starter/manager/files.md";
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# --- 1. the card is gone, and so are its orphans ----------------------------
{
    unlike( $src, qr/id="protected-card"/,     'the Protected sections card is gone' );
    unlike( $src, qr/protected-rows/,          'and its table body' );
    unlike( $src, qr/id="protected-empty"/,    'and its empty state' );

    # The fetch must NOT be gated on the card it used to fill. This is the trap:
    # the data it loads is what every padlock on the page depends on.
    my ($fn) = $src =~ /(function loadProtectedSections\(\).*?\n\})/s;
    ok( $fn, 'the loader survives the card' );
    # THE PROPERTY, not the old bug's exact wording. The first version of this
    # matched `if (!table || !empty) return` and a sabotage inserting a
    # differently-spelled early return passed - which is the same defect
    # wearing other clothes. What must hold is that NOTHING returns between the
    # response arriving and the map being filled: every padlock on the page
    # depends on that assignment, and an early return would fetch the data and
    # throw it away while the listing said "nothing is protected".
    my ($before_fill) = $fn =~ /\.then\(function\(d\) \{(.*?)PROTECTED_BY_PREFIX = \{\}/s;
    ok( defined $before_fill, 'the handler fills the map' );
    unlike( $before_fill // 'return', qr/\breturn\b/,
        'and nothing returns before it does - the map is what the padlocks read' );
    like( $fn, qr/PROTECTED_BY_PREFIX = \{\}/, 'it still fills the map the rows read' );
    like( $fn, qr/paintFiles\(\)/,             'and repaints so the rows show it' );
}

# --- 2. the padlock is in the listing, for folders too ----------------------
{
    # Bounded, and newline-tolerant: the cell is built across two lines and a
    # single-line pattern said "missing" about code that was there. Bounded so
    # it cannot match a protectionGlyph call somewhere else entirely.
    like( $src, qr/mg-col-access">.{0,140}protectionGlyph\(f\)/s,
        'the padlock renders beside the access rights' );
    my ($cell) = $src =~ /(html \+= '<td class="mg-col-access">.*?<\/td>';)/s;
    ok( $cell, 'the access cell is built in one place' );
    like( $cell, qr/isDir \? '' : accessBadge/,
        'a folder still shows no per-file access badge (it has none)' );
    like( $cell, qr/protectionGlyph\(f\)/,
        'but DOES get the padlock - the empty folder cell was half the defect' );
}

# --- 3. the lookup answers for files, and names where the rule came from ----
my $dir = tempdir( CLEANUP => 1 );
my ($blk) = $src =~ /(var PROTECTED_BY_PREFIX.*?)(?=\/\/ The per-file config card)/s;
ok( $blk, 'the protection helpers are present' ) or do { done_testing(); exit };

sub ask {
    my ($setup, $expr) = @_;
    open my $js, '>', "$dir/p.js" or die $!;
    print {$js} "function escHtml(x){return String(x==null?'':x);}\n$blk\n$setup\nconsole.log($expr);\n";
    close $js;
    my $out = `\Q$node\E \Q$dir/p.js\E 2>&1`;
    chomp $out;
    return $out;
}
my $RULES = <<'JS';
PROTECTED_BY_PREFIX = {
  'intranet':         { prefix:'intranet',         policy:'gated', read:['staff'],   exists:true, pages:3, assets:0 },
  'intranet/private': { prefix:'intranet/private', policy:'draft', read:['managers'],exists:true, pages:1, assets:0 }
};
var dirRule  = { name:'intranet',  path:'/intranet',              type:'dir'  };
var fileIn   = { name:'a.md',      path:'/intranet/a.md',         type:'file' };
var deepFile = { name:'b.md',      path:'/intranet/private/b.md', type:'file' };
var open     = { name:'c.md',      path:'/c.md',                  type:'file' };
JS

is( ask($RULES, "protectionFor(dirRule).via === '' ? 'own' : 'inherited'"), 'own',
    'a folder with its own rule reports it as its own' );
is( ask($RULES, "protectionFor(fileIn).via"), 'intranet',
    'a FILE inside a protected folder is covered, and says by which folder' );

# Longest match wins. Reporting the wider rule would understate the gate - a
# draft section inside a gated one is hidden outright, not merely sign-in.
is( ask($RULES, "protectionFor(deepFile).via"), 'intranet/private',
    'the NEAREST covering rule wins, not the widest' );
is( ask($RULES, "protectionFor(deepFile).rule.policy"), 'draft',
    'so the policy reported is the one actually in force' );

is( ask($RULES, "protectionFor(open) === null ? 'none' : 'found'"), 'none',
    'an uncovered row reports nothing' );
is( ask($RULES, "protectionGlyph(open) === '' ? 'no lock' : 'lock'"), 'no lock',
    'and gets no padlock' );
isnt( ask($RULES, "protectionGlyph(fileIn) === '' ? 'no lock' : 'lock'"), 'no lock',
    'while a covered file does' );

# --- 4. the site-wide rule still covers everything --------------------------
{
    my $sw = "PROTECTED_BY_PREFIX = {}; SITE_WIDE_RULE = { prefix:'/', policy:'gated', "
           . "read:['staff'], exists:true, pages:9, assets:2, site_wide:true };\n"
           . "var any = { name:'x.md', path:'/x.md', type:'file' };";
    is( ask($sw, "protectionFor(any).via"), 'site',
        'with a site-wide rule every row is covered, and says so' );
}

# --- 5. an unprotected row says so, rather than saying nothing --------------
# An empty expansion is indistinguishable from one that failed to load.
like( ask($RULES, "protectionBlock(open)"), qr/Not held back/,
    'an uncovered row is told it is open, not left blank' );

# --- 6. the actions the card carried survive, on the owning row only -------
{
    like( ask($RULES, "protectionBlock(dirRule)"), qr/Remove protection/,
        'the row that OWNS the rule can remove it' );
    unlike( ask($RULES, "protectionBlock(fileIn)"), qr/Remove protection/,
        'a row that merely inherits cannot - the button would act somewhere else' );
    like( ask($RULES, "protectionBlock(fileIn)"), qr/Change it there, not here/,
        'and is told where the rule actually lives' );
}

done_testing();
