#!/usr/bin/perl
# SM099 auth-sync injection. Regression for the editor-blanking bug: the
# injected <script> must go before the document's REAL closing </body>, not a
# literal "</body>" that appears inside page content (e.g. a JS string that
# builds an iframe srcdoc). Splicing it inside such a string closes the page's
# own inline <script> early and breaks every script on the page.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);
use File::Temp qw(tempdir);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- a page with a literal </body> inside a JS string (the editor case) ---
{
    my $html = <<'HTML';
<body class="mg-body">
<script>
function refreshPreview() {
  frame.srcdoc = '<html><body>preview</body></html>';
}
</script>
</body>
</html>
HTML

    my $out = main::_inject_auth_sync($html);

    # The srcdoc string must be untouched: no auth-sync spliced into it.
    like( $out, qr/frame\.srcdoc = '<html><body>preview<\/body><\/html>';/,
        'literal </body> inside a JS string is left intact' );

    # The auth-sync script lands before the document's final </body>.
    like( $out, qr/data-ls-auth-out.*<\/body>\s*<\/html>\s*\z/s,
        'auth-sync injected before the real closing </body>' );

    # There must be exactly one injected auth-sync block, not two.
    my $count = () = $out =~ /data-ls-auth-out/g;
    is( $count, 1, 'auth-sync injected exactly once' );

    # The page now has TWO </body> (string + real) but only the real one was
    # rewritten - the injected </script> never sits between </body></html>.
    unlike( $out, qr/<html><body>preview<\/body><\/html>'.*<script>.*<\/script>'/s,
        'no <script> spliced inside the srcdoc JS string' );
}

# --- ordinary page: still injected before its only </body> ---
{
    my $html = "<body>\n<p>hello</p>\n</body>\n</html>\n";
    my $out  = main::_inject_auth_sync($html);
    like( $out, qr/<p>hello<\/p>.*data-ls-auth-out.*<\/body>/s,
        'ordinary page still gets the auth-sync before </body>' );
}

# --- no body tag: returned unchanged ---
{
    my $html = "Status: 200\nContent-type: text/plain\n\nraw body";
    is( main::_inject_auth_sync($html), $html,
        'page with no </body> is returned unchanged' );
}

done_testing;
