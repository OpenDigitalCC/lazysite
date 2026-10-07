#!/usr/bin/perl
# SM951: the manager bell is wired once the page has loaded - asked of a browser.
#
# The bell's script sits in <head> and the bell in <body>. For as long as the
# bell existed (0.10.0 at least) the block checked for the bell at once, found
# nothing, and returned, so no handler, badge or panel was ever set up. Every
# test passed, because they read the template's TEXT (t/unit/lib/196 extracts
# the toggle by regex). Parse order exists only in a browser, so this asks one:
# the layout's own head script, then its own bell markup, loaded headless, and
# the page reports what the handler is once it has loaded.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

chomp( my $browser = `sh -c 'command -v chromium || command -v chromium-browser' 2>/dev/null` );
plan skip_all => 'no chromium on this host: the bell was NOT checked in a browser '
    . '(install chromium to restore this)'
    unless length $browser;

my $tt = do {
    # No docroot here: the page is a static file and the dir holds only it and
    # the browser profile (built with catfile, which lint 118 does not mistake
    # for an engine docroot).
    open my $fh, q{<}, File::Spec->catfile( repo_root(), qw(starter lazysite manager layout.tt) ) or die $!;
    local $/;
    <$fh>;
};

# The head's inline scripts, verbatim, and the bell element - template
# directives removed, since what is being tested is the order, not the values.
my ($head) = $tt =~ m{<head>(.*?)</head>}s;
ok( $head, 'found the layout head' ) or done_testing(), exit;
my @scripts = $head =~ m{(<script>.*?</script>)}sg;
ok( scalar @scripts, 'and its inline scripts' );
my ($bell) = $tt =~ m{(<div class="mg-notif" id="mg-notif">.*?</div>\s*</div>)}s;
ok( $bell, 'found the bell markup' ) or done_testing(), exit;
s/\[%.*?%\]//sg for @scripts, $bell;

my $dir  = tempdir( CLEANUP => 1 );
my $page = "$dir/bell.html";
open my $out, '>', $page or die $!;
print {$out} "<!doctype html><html><head><title>pending</title>\n",
    @scripts, "\n</head><body>\n$bell\n",
    "<script>window.addEventListener('load', function(){\n",
    "  document.title = 'handler=' + typeof window.mgToggleNotif;\n",
    "  try { window.mgToggleNotif();\n",
    "    document.title += ' panel=' + (document.getElementById('mg-notif-panel').hidden ? 'hidden' : 'open');\n",
    "  } catch (e) { document.title += ' threw=' + e.name; }\n",
    "});</script>\n</body></html>\n";
close $out;

# Its own profile directory: nothing of the host's browser is read or written.
my $dom = `timeout 60 \Q$browser\E --headless=new --no-sandbox --disable-gpu --user-data-dir=\Q$dir/profile\E --virtual-time-budget=3000 --dump-dom file://\Q$page\E 2>/dev/null`;
my ($title) = $dom =~ m{<title>([^<]*)</title>};
plan skip_all => 'chromium did not render the page' unless defined $title && length $title;

like( $title, qr/handler=function/,
    'once the page has loaded, the bell has a handler' )
    or diag( "The page reported '$title'. The bell's script runs in <head>; if it "
        . 'looks for the bell before <body> is parsed, it finds nothing and sets nothing up.' );
like( $title, qr/panel=open/, 'and a click opens its panel' );

done_testing();
