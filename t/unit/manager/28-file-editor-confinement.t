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
