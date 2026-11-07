#!/usr/bin/perl
# SM1411: THE EDITOR TAKES AND RENEWS ITS LOCK WITH A POST.
#
# `lock` and `renew-lock` write the lock record, so Lazysite::ControlApi::Actions
# declares them mutating and the manager API refuses them as a GET ("This
# action must be sent as POST.", SM475). The editor sent both as a GET, so from
# 0.7.19 no editor open was granted its lock, and from 0.15.5 (SM992) the page
# showed that refusal as its lock label and started with Save disabled. `unlock`
# already posted.
#
# The editor's own acquireLock runs under node with `fetch` recorded (the shape
# of t/unit/manager/204, which asks the same of the bell's notices-seen): the
# lock call and the renewal it schedules are POSTs. With the change reverted
# both are GETs. t/lint/340 keeps every manager page's fetch of a mutating
# action a POST.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my $edit = PageScript::page_source("$root/starter/manager/edit.md");
my %MUT  = Lazysite::ControlApi::Actions::mutating();

ok( $MUT{$_}, "$_ is declared mutating, so the API refuses it as a GET" ) for qw(lock renew-lock unlock);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed: the editor\'s lock calls were NOT run' unless length $node && -x $node;

my $dir = tempdir( CLEANUP => 1 );
sub run_js {
    my ($js) = @_;
    open my $o, '>', "$dir/t.js" or die $!;
    print {$o} $js;
    close $o;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    chomp $out;
    return $out;
}

# The stand-ins: an element store, a recording fetch answering the lock as
# granted, and a setInterval that runs the renewal once, at once.
my $stubs = <<'JS';
var API = '/cgi-bin/lazysite-manager-api.pl';
var filePath = 'about.md', isNew = false, lockRenewTimer = null;
var SENT = [];
var els = {};
var document = { getElementById: function (id) {
  return els[id] || (els[id] = { id: id, className: '', textContent: '', innerHTML: '', disabled: false });
} };
function setInterval(fn) { fn(); return 1; }
function fetch(u, init) {
  init = init || {};
  SENT.push({ url: String(u), method: String(init.method || 'GET').toUpperCase() });
  return Promise.resolve({ json: function () { return { ok: 1, locked: 0 }; } });
}
JS

my $fn  = PageScript::extract_function( $edit, 'acquireLock', 'edit.md' );
my $out = run_js( $stubs . $fn . "\nacquireLock();\n"
        . "setTimeout(function () { console.log(JSON.stringify({ sent: SENT,"
        . " save: document.getElementById('ed-save-btn').disabled,"
        . " label: document.getElementById('ed-lock-label').textContent })); }, 50);\n" );
my $r = eval { decode_json($out) } or BAIL_OUT("node said: $out");

my %by = map { ( $_->{url} =~ /action=([a-z-]+)/ )[0] => $_->{method} } @{ $r->{sent} };
is( $by{lock},         'POST', 'opening the editor takes its lock with a POST' ) or diag explain $r;
is( $by{'renew-lock'}, 'POST', 'and renews it with a POST' )                    or diag explain $r;
like( $_->{url}, qr/path=about\.md/, "$_->{url}: names the file" ) for @{ $r->{sent} };
ok( !$r->{save}, 'a granted lock leaves Save as it was' );
is( $r->{label}, '', 'and no refusal is shown as the lock label' );

done_testing;
