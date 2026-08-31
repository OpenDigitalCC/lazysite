#!/usr/bin/perl
# SEC-2026-07 (H3/H4 + active content): the generic file editor must not reach
# the lazysite/ management tree, must reject active-content / server-config
# extensions, and must confine strictly under the docroot (no sibling-prefix
# escape). Pins is_blocked_path + validate_path.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(is_blocked_path validate_path);

# --- H4: the lazysite/ tree is off-limits (except forms/submissions) --------
ok( is_blocked_path('lazysite/lazysite.conf'),         'H4: lazysite.conf blocked' );
ok( is_blocked_path('lazysite/auth/acls.json'),        'H4: auth tree blocked' );
ok( is_blocked_path('lazysite/backups/full-x.tar.gz'), 'H4: backups blocked' );
ok( is_blocked_path('lazysite/logs/audit.log'),        'H4: logs blocked' );
ok( is_blocked_path('lazysite/templates/registries/sitemap.xml.tt'), 'H4: templates blocked' );
ok( is_blocked_path('lazysite/git-sync.conf'), 'H4: plugin-secret conf blocked' );
ok( !is_blocked_path('lazysite/forms/submissions/2026.jsonl'), 'forms/submissions still readable' );
ok( !is_blocked_path('content/page.md'), 'ordinary content not blocked' );

# SM694/SM706: the BRAND folder. The plugin creates it under lazysite/ so that
# a logo and a letterhead are not served to the web, and tells the operator to
# manage it on the Files page - which answered "Path is blocked", so the
# instruction was false and the folder invisible.
#
# It is carved out for what it mostly holds - a logo, a font, a colour - and
# NOT for a pandoc template. A template's text reaches xelatex at render time,
# so `\input{/etc/passwd}` in one is read by the CGI user: uploading a template
# would turn manage_content, which authors pages, into "read any file this
# server can". md-to-pdf never passes -shell-escape, so this is a file read
# rather than command execution - which is why the line is drawn here and not
# further out. SM707 asks whether the manager should ever offer it.
ok( !is_blocked_path('lazysite/brands'),            'the brand folder is listable' );
ok( !is_blocked_path('lazysite/brands/house/logo.png'), 'a brand logo is managed like content' );
ok( !is_blocked_path('lazysite/brands/house/Font.otf'), 'and so is a font' );
ok( is_blocked_path('lazysite/brands/house/brand.latex'),
    'a pandoc template is NOT uploadable through the manager' )
    or diag( 'Its text reaches the PDF engine, which reads what it is told to '
        . 'read. That is a bigger grant than the page this was uploaded from.' );
ok( is_blocked_path('lazysite/brands/house/brand.tex'), '.tex likewise' );
ok( is_blocked_path('lazysite/brands/house/macros.sty'), '.sty likewise' );
ok( is_blocked_path('lazysite/brands/house/filter.lua'),
    'and a lua filter, which pandoc executes' );
ok( is_blocked_path('lazysite/brands/house/BRAND.LaTeX'),
    'the rule is case-insensitive, like the extension rule above it' );

# The capability-/scope-gated content areas partners legitimately manage by
# path (layouts, themes, nav.conf) must NOT be caught by this path blocklist -
# their own manage_layouts/manage_themes/manage_nav + dav_scope gates apply.
ok( !is_blocked_path('lazysite/layouts/demo/theme.css'), 'layouts/ managed area allowed' );
# SM421/F2: a TOP-LEVEL lazysite/themes/ is now BLOCKED, and this assertion is
# inverted deliberately. It was written in 88f16b4 alongside the layouts/ and
# nav.conf exemptions, which are real managed areas - this one exempted a store
# no engine code has ever resolved. Real themes live under
# lazysite/layouts/<layout>/themes/<theme>/ and are covered by the assertion
# above, which is what makes removing this one safe.
ok( is_blocked_path('lazysite/themes/live/theme.css'),
    'a TOP-LEVEL themes/ path is blocked - no store resolves there, so the '
        . 'carve-out was an under-gated write path waiting for a feature' );
ok( !is_blocked_path('lazysite/nav.conf'), 'nav.conf (nav editor) allowed' );
# ...but the sensitive form CONFIGS next to submissions stay blocked.
ok( is_blocked_path('lazysite/forms/smtp.conf'), 'form configs (secrets) still blocked' );
ok( is_blocked_path('lazysite/manager/layout.tt'), 'manager UI chrome still blocked' );

# --- active-content / server-config extensions (SSI, PHP, .htaccess, .PL) ----
ok( is_blocked_path('x.cgi'),         'cgi blocked' );
ok( is_blocked_path('x.shtml'),       'shtml (SSI) blocked' );
ok( is_blocked_path('x.phtml'),       'phtml blocked' );
ok( is_blocked_path('x.php'),         'php blocked' );
ok( is_blocked_path('x.PL'),          'uppercase .PL blocked (case-insensitive)' );
ok( is_blocked_path('sub/.htaccess'), '.htaccess blocked' );
ok( is_blocked_path('x.htpasswd'),    '.htpasswd blocked' );
ok( !is_blocked_path('x.md'),         '.md allowed' );
ok( !is_blocked_path('x.html'), '.html allowed by this gate (upload gate blocks it separately)' );

# --- H3: validate_path confines strictly under the docroot ------------------
{
    my $base = tempdir( CLEANUP => 1 );
    my $doc  = "$base/public_html";
    make_path( $doc, "$base/public_html.bak" );
    open my $fh, '>', "$base/public_html.bak/secret.txt" or die $!;
    print {$fh} "SIBLING\n";
    close $fh;
    local $Lazysite::Manager::Common::DOCROOT = $doc;

    my $ok = validate_path('page.md');
    ok( $ok->{ok}, 'a normal path validates' );

    # The sibling public_html.bak is a string-superset of the docroot: a bare
    # index() prefix check would accept it. The boundary check must not.
    my $esc = validate_path('../public_html.bak/secret.txt');
    ok( !$esc->{ok}, 'H3: sibling-prefix escape is rejected' );
}

done_testing();
