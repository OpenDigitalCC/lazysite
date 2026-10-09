package Lazysite::Manager::Preview;

# Theme/layout preview (SM071 Phase 1) and the page preview: preview-grant mints
# the signed lzs_preview cookie the processor verifies, preview-clear expires
# it, and preview renders one page through the processor. Moved unchanged out
# of lazysite-manager-api.pl by SM944 S24.
#
# Index
#   $PREVIEW_COOKIE, $PREVIEW_TTL  the cookie's name and lifetime
#   _preview_secret        the per-install auth secret, read or minted
#   action_preview_grant   preview-grant: mint the cookie for a layout/theme
#   action_preview_clear   preview-clear: expire the caller's preview cookies
#   action_preview         preview: render a page through the processor
#
# The request context ($auth_user) is read from Lazysite::Manager::Common, which
# lazysite-manager-api.pl sets and nothing here assigns (t/lint/217). Loaded
# where no request set it, both verbs that act for an account refuse
# (t/unit/manager/205). $DOCROOT and $LAZYSITE_DIR are set by the dispatcher, as
# for every manager module.

use strict;
use warnings;
use Exporter 'import';
use File::Path                 qw(make_path);
use Digest::SHA                qw(hmac_sha256_hex);
use JSON::PP                   ();
use Lazysite::Util             qw(log_event);
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Common  qw($auth_user respond processor_path _emit_json);

our @EXPORT_OK = qw(action_preview action_preview_grant action_preview_clear);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

# SM071 Phase 1: theme/layout preview. preview-grant mints the signed
# cookie the processor verifies; declared here (before dispatch runs) so
# the action subs see initialised values.
my $PREVIEW_COOKIE = 'lzs_preview';
my $PREVIEW_TTL    = 3600;            # 1 hour

# --- SM071 Phase 1: theme/layout preview minting ---
#
# preview-grant mints the signed lzs_preview cookie the processor
# verifies (see lazysite-processor.pl check_preview). Same primitive as
# the auth cookie: payload ":" hmac_sha256_hex over lazysite/auth/.secret.
# Manager-only (behind the manager auth + CSRF gate). A valid cookie tells
# the processor to render that session against the named layout/theme,
# uncacheable. Payload: v1:<exp-epoch>:<layout>:<theme>:<user>.

# Read (or mint) the per-install auth secret - the same file the auth
# wrapper and the processor's preview verifier use. Fail closed without
# a CSPRNG.
sub _preview_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    # SM917: the `-f $path &&` guard is gone, which is subtest 3's rule as much as
    # subtest 2's - a stat this process may not make fails exactly like an open it
    # may not make, and renders as absence before the open can report otherwise.
    # Absence still reaches the mint below, because cannot_read is silent on
    # ENOENT; what is new is that an existing-but-unreadable secret says so
    # instead of quietly minting a SECOND one, which would sign previews the
    # processor's verifier cannot check.
    if ( open my $fh, '<', $path ) {
        chomp( my $s = <$fh> );
        close $fh;
        return $s if length $s;
    }
    else { Lazysite::Util::cannot_read( 'the preview secret', $path ) }
    make_path("$LAZYSITE_DIR/auth") unless -d "$LAZYSITE_DIR/auth";
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    open my $wfh, '>', $path or die "Cannot write $path: $!\n";
    # 0660: identity-shared secret (site-user CLI + www-data CGI via the
    # setgid auth dir group); owner-only minting locks the other side out.
    chmod 0o660, $path;
    print $wfh "$s\n";
    close $wfh;
    return $s;
}

sub action_preview_grant {
    my ($p)    = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';

    # SM944 S24 (b), ruled 2026-10-09: A PREVIEW IS MINTED FOR AN ACCOUNT. Inside
    # a request the dispatcher has authenticated a manager before this runs, so
    # $auth_user is never empty here; reached outside one (the request context's
    # reset leaves nobody) it minted a signed cookie for account '' and, on a
    # site with none, created the auth secret (tmp/sm944-s24-refusal-probe.out).
    unless ( length $auth_user ) {
        respond( { ok => 0, kind => 'forbidden',
                error => 'A preview is minted for a signed-in manager, and no account is asking.' } );
        return;
    }

    unless ( $layout =~ /^[A-Za-z0-9_-]+$/ ) {
        respond( { ok => 0, error => 'Invalid or missing layout' } );
        return;
    }
    unless ( $theme =~ /^[A-Za-z0-9_-]*$/ ) {
        respond( { ok => 0, error => 'Invalid theme' } );
        return;
    }

    # The layout must exist; a named theme must exist under it. An empty
    # theme means "preview the layout, no theme styling". This stops the
    # manager handing out a preview of something that cannot render.
    unless ( -f "$LAZYSITE_DIR/layouts/$layout/layout.tt" ) {
        respond( { ok => 0, error => "No such layout: $layout" } );
        return;
    }
    if ( length $theme
        && !-f "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json" ) {
        respond( { ok => 0, error => "No such theme: $theme" } );
        return;
    }

    # Cookie-safe user field (no CRLF / header injection); the processor
    # records but does not re-validate it.
    ( my $user = $auth_user ) =~ s/[^A-Za-z0-9_.\@-]//g;

    my $exp     = time() + $PREVIEW_TTL;
    my $payload = "v1:$exp:$layout:$theme:$user";
    my $sig     = hmac_sha256_hex( $payload, _preview_secret() );
    my $value   = "$payload:$sig";
    my $secure  = $ENV{HTTPS} ? '; Secure' : '';

    log_event( 'INFO', 'preview-grant', 'preview granted',
        layout => $layout, theme => $theme, user => $auth_user );

    # The second cookie is a non-HttpOnly UI marker so the manager can show or
    # hide "Stop preview". It carries no auth value - the signed HttpOnly cookie
    # above it is the gate.
    _emit_json(
        '200 OK',
        [ "Set-Cookie: $PREVIEW_COOKIE=$value; HttpOnly; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure",
            "Set-Cookie: ${PREVIEW_COOKIE}_active=1; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure",
        ],
        { ok => JSON::PP::true, layout => $layout, theme => $theme, expires => $exp } ); # SM353
}

sub action_preview_clear {
    my $secure = $ENV{HTTPS} ? '; Secure' : '';
    log_event( 'INFO', 'preview-clear', 'preview cleared', user => $auth_user );
    _emit_json(
        '200 OK',
        [ "Set-Cookie: $PREVIEW_COOKIE=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure",
            "Set-Cookie: ${PREVIEW_COOKIE}_active=; SameSite=Lax; Path=/; Max-Age=0$secure",
        ],
        { ok => JSON::PP::true } );    # SM353
}

sub action_preview {
    my ($rel_path) = @_;

    # SM944 S24 (c), ruled 2026-10-09: A PREVIEW IS RENDERED FOR AN ACCOUNT. As
    # for preview-grant: inside a request $auth_user is never empty here;
    # outside one this shelled the processor for any path it was given.
    return { ok => 0, kind => 'forbidden',
        error => 'A preview is rendered for a signed-in manager, and no account is asking.' }
        unless length $auth_user;

    my $uri = $rel_path;
    $uri =~ s{^/*}{/};
    $uri =~ s/\.md$//;
    $uri =~ s{/index$}{/};

    local $ENV{LAZYSITE_NOCACHE} = '1';
    local $ENV{REDIRECT_URL}     = $uri;
    local $ENV{DOCUMENT_ROOT}    = $DOCROOT;

    # SM441: render under the Host of the domain that OWNS this path. Without
    # it the preview inherited the Host of whatever the sysop was browsing
    # the manager on - normally the primary - so SM151's per-Host routing never
    # fired and a domain's page came back with the BASE layout, theme and nav.
    # The content was right and the presentation was another site's, which
    # reads as a page given the wrong theme rather than as a preview that has
    # not been told which site it is. An operator who happened to open the
    # manager on the domain's own host saw a correct preview, which is what
    # made it intermittent.
    my ($owner) = Lazysite::Manager::Domains::host_for_path($rel_path);
    local $ENV{HTTP_HOST} = length $owner ? $owner : ( $ENV{HTTP_HOST} // '' );

    my $processor = processor_path();
    my $output    = qx($^X \Q$processor\E 2>/dev/null);

    # Strip CGI headers
    $output =~ s/\A.*?\r?\n\r?\n//s;

    return { ok => 1, html => $output };
}

1;
