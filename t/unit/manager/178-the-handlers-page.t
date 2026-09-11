#!/usr/bin/perl
# SM842: the Handlers page - the manager's surface for the handler contract.
#
# One page for the three things that name a handler: the handlers, which forms
# call which, and what the timer calls. What it must hold, driven through the
# page's own JavaScript in node:
#
# - every listing row is the three-cell row (describes, metadata, acts - SM819)
# - a handler's fields are drawn from its type's schema, the catalogue the
#   engine validates against, so the page cannot offer a field the type does
#   not take; a value the engine knows (a table, a connector) is CHOSEN, and an
#   unreadable list is a text box that says so, never an empty select (SM806)
# - a schedule's fields round-trip between the page's one-per-line form and the
#   object the engine stores, and a line that is not name = value is refused
# - the handler UI is GONE from the Extension Config page, which keeps the
#   submissions viewer and links here
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper         qw(repo_root);
use PageScript         ();
use Lazysite::Handlers ();

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $page     = PageScript::page_source("$root/starter/manager/handlers.md");
my $dir      = File::Temp->newdir;    # scratch for the node script, not a docroot
my ($script) = $page =~ /<script>(.*)<\/script>/s;
ok( $script, 'the page has its script' ) or BAIL_OUT('no script');
# Everything but the boot calls at the end.
( my $defs = $script ) =~ s/\nloadChoices\(\);\nload\(\);\n\s*\z/\n/;

sub run_js {
    my ($body) = @_;
    open my $o, '>', "$dir/t.js" or die $!;
    print {$o} "var document = { getElementById: function () { return null; } };\n"
        . "var mgDirtyGuard = { set: function () {}, clear: function () {} };\n"
        . $defs . "\n" . $body;
    close $o;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    chomp $out;
    return $out;
}

sub top_level_cells {
    my ($row)   = @_;
    my ($inner) = $row =~ /^<div class="mg-row">(.*)<\/div>/s or return -1;
    my ( $depth, $n ) = ( 0, 0 );
    while ( $inner =~ /<(\/?)(span|a)\b[^>]*>/g ) {
        if   ($1) { $depth-- }
        else      { $n++ if $depth == 0 && $2 eq 'span'; $depth++ }
    }
    return $n;
}

my $types = encode_json( Lazysite::Handlers::types() );

subtest 'every listing row is the three-cell row' => sub {
    my $out = run_js(<<"JS");
TYPES = $types;
var h = { id: 'mail', type: 'smtp', name: 'Mail', to: 'a\@b.c', enabled: true, used_by: { forms: ['contact'], schedule: [] } };
console.log(handlerRow(h));
console.log('==SEP==');
FORMS = { contact: ['mail'] };
var el = { innerHTML: '' };
document.getElementById = function () { return el; };
renderForms(); console.log(el.innerHTML);
console.log('==SEP==');
SCHEDULE = [ { id: 'nightly', handler: 'mail', every: 86400, enabled: true, cap: 'manage_forms' } ];
renderSchedule(); console.log(el.innerHTML);
JS
    my @parts = split /\n==SEP==\n/, $out;
    is( scalar @parts, 3, 'three listings drawn' ) or diag $out;
    for my $i ( 0 .. $#parts ) {
        is( top_level_cells( $parts[$i] ), 3, (qw(handler form schedule))[$i] . ' row: three cells' )
            or diag $parts[$i];
        like( $parts[$i], qr/class="mg-chev mg-chev-label"[^>]*aria-label="Show details for/,
            '  its trigger is named' );
        like( $parts[$i], qr/<div class="mg-expand" id="exp-[^"]+" hidden><\/div>/, '  and its card is the next sibling' );
    }
    like( $parts[0], qr/used by 1 form/, 'a handler row says what uses it' );
    like( $parts[2], qr/every 1 day .*calls mail .*needs manage_forms/, 'a schedule row says how often, what, and under which capability' );
};

subtest 'a handler\'s fields come from its type, and known values are chosen' => sub {
    my $out = run_js(<<"JS");
TYPES = $types;
TABLES = ['leads', 'orders'];
console.log(handlerEditor({ id: 't', type: 'table', table: 'gone', fields: 'a=b', enabled: true, used_by: { forms: [], schedule: [] } }, 'h-t'));
console.log('==SEP==');
TABLES = null;
console.log(handlerEditor({ id: 't', type: 'table', table: 'leads', fields: 'a=b', enabled: true, used_by: { forms: [], schedule: [] } }, 'h-t'));
console.log('==SEP==');
console.log(handlerEditor({ type: 'smtp' }, 'new-handler', true));
JS
    my ( $known, $unknown, $new ) = split /\n==SEP==\n/, $out;
    like( $known, qr/<select class="mg-inp" id="f-h-t-table">/, 'a known table list is a select' );
    like( $known, qr/<option value="gone" selected>gone — not on this site<\/option>/,
        'and a configured table missing from it is kept and marked, never dropped' );
    like( $unknown, qr/<input class="mg-inp" type="text" id="f-h-t-table" value="leads">/,
        'an unreadable table list is a text box' );
    like( $unknown, qr/could not be read \(it needs Data\)/, 'which says why' );
    like( $known,   qr/id="f-h-t-keep_copy"/, 'every schema field is drawn (keep_copy)' );
    unlike( $known, qr/id="f-h-t-url"/, 'and nothing the type does not declare' );
    like( $new, qr/<select class="mg-inp" id="f-new-handler-type"/, 'a new handler chooses its type' );
    for my $t (@Lazysite::Handlers::TYPE_ORDER) {
        like( $new, qr/<option value="$t"/, "  offering $t" );
    }
    unlike( $new, qr/webhook/i, '  and no webhook' );
    like( $known, qr/data-impact="destroy"[^>]*>Delete</, 'Delete declares that it destroys' );
    like( $page, qr/function deleteHandler\(id\) \{\s*mgConfirm\(/, 'and confirms first' );
};

subtest 'the schedule\'s fields round-trip, and a bad line is refused' => sub {
    my $out = run_js(<<'JS');
var p = parsePayload('kind = ping\n\nsource=timer \n');
console.log(JSON.stringify(p.payload));
console.log(payloadText(p.payload));
console.log(parsePayload('no equals here').error);
JS
    my @l = split /\n/, $out;
    is( $l[0], '{"kind":"ping","source":"timer"}', 'name = value lines become the object' );
    is( "$l[1]\n$l[2]", "kind = ping\nsource = timer", 'and the object becomes the lines again' );
    is( $l[3], 'line 1 is not name = value', 'a line that is neither is refused, by line' );
};

subtest 'the page is registered, and the old handler UI is gone' => sub {
    my $layout = do { open my $fh, '<', "$root/starter/lazysite/manager/layout.tt" or die $!; local $/; <$fh> };
    like( $layout, qr/manager_caps\.manage_forms \|\| manager_caps\.manage_data \|\| manager_caps\.manage_connectors %\]<a href="\/manager\/handlers"/,
        'the nav offers it to any of the three destination capabilities' );
    my $pc = PageScript::page_source("$root/starter/manager/plugin-config.md");
    unlike( $pc, qr/handler-save|form-targets-save|renderHandlerList|showAddHandlerForm/,
        'the Extension Config page no longer draws or saves handlers' );
    like( $pc, qr/href="\/manager\/handlers">Handlers</, 'its form handler row links here' );
    like( $pc, qr/function openRequestedSubmissions\(\)/, 'and it opens the submissions viewer this page links to' );
    like( $page, qr/\/manager\/plugin-config\?submissions=/, 'which a file handler\'s card does' );
};

done_testing();
