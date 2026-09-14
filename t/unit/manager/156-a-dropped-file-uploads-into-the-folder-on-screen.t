#!/usr/bin/perl
# SM878: files dropped onto the Files page upload into the folder on screen.
#
# Asked for by the release manager: "file apps - drag drop file uploder required
# as well as upload". Built once it was confirmed to be front-end only.
#
# THE HANDLER IS RUN, following t/unit/manager/121: the behaviours that matter
# here are what the listeners DO when an event arrives, and a source grep passes
# on any file containing the right words in the wrong order.
#
# THE THREE THINGS THAT GO WRONG WITH DROP TARGETS, all covered below:
#
#   1. The browser's default action for a dropped file is to NAVIGATE TO IT,
#      throwing away the page - an unsaved rename, a filter, a selection. The
#      drops that do this are the ones that MISS, so suppressing it only on the
#      target is no protection at all.
#   2. A dropped FOLDER is not a file. It arrives as an entry needing
#      webkitGetAsEntry() to walk; dataTransfer.files does not carry it. Accept
#      the drop and the operator watches nothing happen and is told nothing.
#   3. Any drag lights the target up - a text selection, a link - unless the
#      handler asks whether the drag carries files.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/files.md';
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

my ($block) = $src =~ /(\/\/ SM878: drop files onto the page.*?\n\}\)\(\);)/s;
ok( $block, 'the page carries the drop handler' ) or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/drop.js" or die $!;
print {$js} <<"JS";
// A DOM small enough to drive the handler and nothing more. Each element
// records the listeners registered on it so the test can fire them.
function El(id) {
  this.id = id; this.h = {}; this.attrs = {}; this.cls = {};
  var self = this;
  this.classList = {
    add:    function (c) { self.cls[c] = 1; },
    remove: function (c) { delete self.cls[c]; }
  };
}
El.prototype.addEventListener = function (n, fn) { (this.h[n] = this.h[n] || []).push(fn); };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.fire = function (n, e) { (this.h[n] || []).forEach(function (f) { f(e); }); };

var app = new El('app');
var document = new El('document');
document.getElementById = function (id) { return id === 'app' ? app : null; };
var window = { FileList: function () {} };

// What the handler is supposed to reach.
var uploaded = null, status = null;
function uploadFiles(f) { uploaded = f; }
function showStatus(m, isErr) { status = { msg: m, err: !!isErr }; }
var currentDir = '/photos';

$block

function ev(types, opts) {
  opts = opts || {};
  var prevented = false, stopped = false;
  return {
    dataTransfer: { types: types, files: opts.files || ['a.png'], items: opts.items },
    preventDefault:  function () { prevented = true; },
    stopPropagation: function () { stopped = true; },
    wasPrevented: function () { return prevented; },
    wasStopped:   function () { return stopped; }
  };
}

var out = {};

// 1. a stray drop anywhere on the document must not navigate
var stray = ev(['Files']);
document.fire('drop', stray);
out.documentDropPrevented = stray.wasPrevented();
var strayOver = ev(['Files']);
document.fire('dragover', strayOver);
out.documentDragoverPrevented = strayOver.wasPrevented();

// The handler keeps a private enter/leave COUNT, so each case below has to
// start from a known zero rather than inheriting the previous case's drags -
// an unpaired dragenter here would make a later assertion fail for a reason
// that has nothing to do with what it is testing. A document drop resets
// everything, which is the handler's own escape hatch.
function reset() { document.fire('drop', ev(['Files'])); app.cls = {}; }

// 2. a file drag lights the target and names the destination
reset();
app.fire('dragenter', ev(['Files']));
out.activeOnFileDrag = !!app.cls['mg-drop-active'];
out.hint = app.attrs['data-drop-hint'];

// 3. a NON-file drag does not
reset();
app.fire('dragenter', ev(['text/plain']));
out.activeOnTextDrag = !!app.cls['mg-drop-active'];

// 4. enter/leave over children does not flicker the target off early
reset();
app.fire('dragenter', ev(['Files']));   // onto the table
app.fire('dragenter', ev(['Files']));   // onto a row inside it
app.fire('dragleave', ev(['Files']));   // off the row, still inside the table
out.stillActiveAfterChildLeave = !!app.cls['mg-drop-active'];
app.fire('dragleave', ev(['Files']));   // and finally out
out.clearedAfterLastLeave = !!app.cls['mg-drop-active'];

// 4b. a LEAKED enter - one whose leave never arrives, because the listing
// re-rendered mid-drag or the drag ended off-window - does not strand the
// outline on a page nobody is dragging over.
reset();
app.fire('dragenter', ev(['Files']));
app.fire('dragenter', ev(['Files']));
document.fire('dragend', ev(['Files']));
out.clearedOnDragend = !!app.cls['mg-drop-active'];

// 5. dropping files uploads them
reset();
uploaded = null;
var drop = ev(['Files'], { files: ['one.png', 'two.png'] });
app.fire('drop', drop);
out.uploadedCount = uploaded ? uploaded.length : 0;
out.clearedOnDrop  = !!app.cls['mg-drop-active'];

// 6. dropping a FOLDER refuses by name and uploads nothing
reset();
uploaded = null; status = null;
app.fire('drop', ev(['Files'], {
  files: ['ignored'],
  items: [{ webkitGetAsEntry: function () { return { isDirectory: true }; } }]
}));
out.folderUploaded = uploaded !== null;
out.folderStatus   = status ? status.msg : null;
out.folderWasError = status ? status.err : false;

console.log(JSON.stringify(out));
JS
close $js;

my $got = eval {
    require JSON::PP;
    JSON::PP::decode_json(`\Q$node\E \Q$dir/drop.js\E 2>&1`);
};
ok( $got, 'the drop handler ran' ) or do { done_testing(); exit };

# --- the page is not thrown away by a missed drop ----------------------------
ok( $got->{documentDropPrevented},
    'a drop anywhere on the document is prevented, not just one on the target' )
    or diag( 'The browser navigates to a dropped file by default, discarding '
        . 'the page. A drop that MISSES the target is exactly the one that '
        . 'would do it, so the suppression has to be document-wide.' );
ok( $got->{documentDragoverPrevented},
    'and dragover likewise, or the drop event never fires at all' );

# --- the target appears for file drags only ----------------------------------
ok( $got->{activeOnFileDrag}, 'a drag carrying files activates the drop target' );
like( $got->{hint}, qr{/photos},
    'and the hint names the destination folder, so a wrong drop is prevented '
        . 'rather than undone' );
ok( !$got->{activeOnTextDrag},
    'a drag carrying no files does NOT activate it' )
    or diag( 'Dragging a text selection or a link across the page would flash '
        . 'an upload target at somebody who is not uploading.' );

# --- the counter, not a boolean ----------------------------------------------
ok( $got->{stillActiveAfterChildLeave},
    'moving from the table onto a row inside it keeps the target active' )
    or diag( 'dragenter/dragleave fire per child element. A boolean flag turns '
        . 'the target off the moment the pointer crosses onto a row, so it '
        . 'flickers and the operator cannot tell whether a drop will land.' );
ok( !$got->{clearedAfterLastLeave}, 'and leaving for good clears it' );

ok( !$got->{clearedOnDragend},
    'a drag that ends without its leaves arriving does not strand the outline' )
    or diag( 'The count only returns to zero if every dragenter is matched. A '
        . 'listing that re-renders mid-drag, or a drag ending off-window, '
        . 'leaves it positive and the page keeps a drop outline nobody is '
        . 'dragging over. dragend and a document drop both reset it outright.' );

# --- the drop uploads --------------------------------------------------------
is( $got->{uploadedCount}, 2, 'dropped files are handed to uploadFiles' )
    or diag( 'uploadFiles already does the POST, the overwrite confirmation and '
        . 'the partial-success reporting. Anything else here would be a second '
        . 'upload path answering for what lands on disk.' );
ok( !$got->{clearedOnDrop}, 'and the target clears once the files are taken' );

# --- a folder is refused, by name --------------------------------------------
ok( !$got->{folderUploaded}, 'dropping a folder uploads nothing' );
ok( $got->{folderWasError},  'and reports it as a failure, not a success' );
like( $got->{folderStatus}, qr/not the folder/i,
    'saying what to do instead' )
    or diag( 'A dropped directory arrives as an entry needing '
        . 'webkitGetAsEntry() to walk - dataTransfer.files does not carry it. '
        . 'Accepting the drop silently uploads nothing, which is the worst of '
        . 'the three options.' );

done_testing();
