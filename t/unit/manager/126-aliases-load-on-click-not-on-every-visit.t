#!/usr/bin/perl
# SM628: the alias list opens on click instead of sitting on the Files page.
#
# It was a card: present on every visit to Files, fetched at page load AND again
# on every folder change - to answer a question an operator asks occasionally,
# about data that is read-only and authored somewhere else entirely (page front
# matter). Nothing on the page acted on it.
#
# Opening on demand also RETIRES a defect rather than keeping it fixed. The card
# was scoped to a folder, so it had to be re-fetched on navigation or it would
# sit there describing somewhere the operator had left - the comment in loadDir
# said exactly that. A modal reads currentDir when it opens, so it cannot be
# stale by construction.
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

# --- 1. nothing fetches aliases until asked ---------------------------------
# The whole point. Asserted on the SOURCE because it is an absence, and an
# absence is the one thing a render cannot show.
{
    # Both names. The first version of this named only the OLD function, so a
    # sabotage that re-added the fetch at page load under the NEW name passed -
    # an assertion pinned to a name that no longer exists proves nothing.
    # Column zero only: a TOP-LEVEL call is the one that runs on page load. The
    # loader is called from inside openAliases too, indented, and that one is
    # the point of the change - an assertion that caught it as well would have
    # been broken in the opposite direction, forbidding the fix.
    unlike( $src, qr/^loadAliases(?:Into)?\(\);/m,
        'no alias fetch at page load, under either name' );
    my ($nav) = $src =~ /(function loadDir\(dir\).*?\n\})/s;
    ok( $nav, 'loadDir is present' );
    unlike( $nav, qr/loadAliases|loadAliasesInto/,
        'and none on folder navigation' );
    unlike( $src, qr/id="aliases-card"/,
        'the always-present card is gone' );
}

# --- 2. there is a way in --------------------------------------------------
# Removing the card without a button would be a regression dressed as a fix.
like( $src, qr/id="alias-btn"[^>]*onclick="openAliases\(\)"/,
    'a button opens it' );
like( $src, qr/mg-file-actions-right[\s\S]{0,400}id="alias-btn"/,
    'in the toolbar beside the other read-only overview, not floating' );

# --- 3. the modal renders the rows it is given ------------------------------
my $dir = tempdir( CLEANUP => 1 );
my ($fn) = $src =~ /(function loadAliasesInto\(\).*?\n\})\n/s;
ok( $fn, 'the loader is present' ) or do { done_testing(); exit };

sub render {
    my ($json) = @_;
    open my $js, '>', "$dir/a.js" or die $!;
    print {$js} <<"JS";
function escHtml(x){return String(x==null?'':x).replace(/[&<>"]/g,function(c){
  return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
var API='/api', currentDir='/blog/';
var body={ innerHTML:'', parentNode:{} };
document = { getElementById: function(){ return body; } };
fetch = function(){ return Promise.resolve({ json: function(){ return $json; } }); };
$fn
loadAliasesInto();
setTimeout(function(){ console.log(JSON.stringify({html: body.innerHTML})); }, 10);
JS
    close $js;
    require JSON::PP;
    return JSON::PP::decode_json(`\Q$node\E \Q$dir/a.js\E 2>&1`);
}

{
    my $r = render( '{ ok:true, aliases:[{alias:"/old",target:"/new",code:301},'
            . '{alias:"/tmp",target:"/now",code:302}] }' );
    ok( $r, 'the loader ran' ) or do { done_testing(); exit };
    like( $r->{html}, qr{/old}, 'a row renders its alias' );
    like( $r->{html}, qr{/new}, 'and its target' );
    like( $r->{html}, qr/301/,  'and the permanent badge' );
    like( $r->{html}, qr/302/,  'and the temporary one' );
    like( $r->{html}, qr/read-only/,
        'and it still says the list is authored in front matter' );
}

# --- 4. empty says WHERE it is empty ----------------------------------------
# "No aliases" and "no aliases HERE" are different answers and the operator
# cannot tell them apart. The card version got this right; keep it.
{
    my $r = render('{ ok:true, aliases:[] }');
    like( $r->{html}, qr{/blog/},
        'an empty result names the folder it is empty for' );
}

# --- 5. a refusal is not rendered as "none" ---------------------------------
# The card version returned silently on !ok and left the empty state showing,
# so a server refusal read as "there are no aliases" - a wrong answer rather
# than no answer.
{
    my $r = render('{ ok:false, error:"refused" }');
    like( $r->{html}, qr/Could not read/,
        'a refusal says so' );
    unlike( $r->{html}, qr/No aliases point into/,
        'and is not dressed up as an empty list' );
}

done_testing();
