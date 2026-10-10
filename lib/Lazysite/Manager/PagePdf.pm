package Lazysite::Manager::PagePdf;

# A page, or a composed document and its parts, rendered to a branded PDF by
# the pandoc plugin and streamed back (page-pdf, SM732). Moved out of
# lazysite-manager-api.pl by SM944 S29 with one line changed, as ruled
# 2026-10-10 ("(a) load in main"): the plugin is loaded in package main.
# `do FILE` compiles a file into the CALLER's package, and the plugin declares
# none; it is found as main->can('convert'), so it is loaded where the script
# loaded it (t/unit/manager/219 fails without that line).
#
# Index
#   action_page_pdf  page-pdf: render a page the caller may read, and stream it
#
# The request context ($auth_user, @REQUEST_SCOPES) is read from
# Lazysite::Manager::Common, which lazysite-manager-api.pl sets and nothing here
# assigns (t/lint/217). page-pdf is path-scoped: the dispatcher refuses a page
# outside the caller's scope before it runs (SM978). Loaded where no request set
# the context, it refuses before the plugin loads (t/unit/manager/205, 219).
# The body goes out through Manager::Upload's one streamed path (Q16b). $DOCROOT
# is set by the dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util            qw(log_event);
use Lazysite::Auth::Acl       qw(_acl_denied);
use Lazysite::Manager::Common qw($auth_user @REQUEST_SCOPES);
use Lazysite::Manager::Upload ();

our @EXPORT_OK = qw(action_page_pdf);

our $DOCROOT;    # set by the script

# SM732: render a page to a branded PDF and stream it back.
#
# Returns { streamed => 1 } after the body, like action_site_backup_download
# above; any refusal comes back as ordinary JSON so a caller can read WHY - and
# for a composed document that reason names the part, which is the whole point
# of SM706 and was until now unreachable.
sub action_page_pdf {
    my ($rel) = @_;
    # SM944 S29, the established fail-closed pattern (ruled 2026-10-10, "(a)
    # load in main"): A PAGE IS RENDERED FOR AN ACCOUNT. Inside a request the
    # dispatcher has refused an empty $auth_user (and required
    # `manage_content`) before this runs, so it is never empty here; reached
    # outside one (the request context's reset leaves nobody) it loaded the
    # plugin and converted a public page for account ''
    # (tmp/sm944-s29-s30-refusal-probe.out). Refused before the plugin loads.
    return { ok => 0, kind => 'forbidden',
        error => 'A page is rendered to PDF for a signed-in account, and no account is asking.' }
        unless length $auth_user;
    return { ok => 0, error => 'a page path is required' }
        unless defined $rel && length $rel;

    # SM978 (ruled 2026-10-10, "Scope it + composed parts"): EVERY PAGE THE PDF
    # READS IS ASKED WHAT `read` WOULD ASK OF IT - the caller's scope and the
    # content ACL. The page itself is refused outside the scope by the
    # dispatcher (page-pdf is declared `scoped`, so _confine_scope sees its
    # path); its own read ACL was asked by nothing, and a composed document's
    # parts were asked the ACL alone, so a confined manager got another domain's
    # page as a part and any manage_content account got a page its rule denied
    # it (tmp/q16b-acl-probe.out). A part outside the scope REFUSES THE
    # DOCUMENT, naming the part - fail closed, as the page's own refusal does
    # and as the plugin already refuses a part the ACL denies.
    my @scopes  = grep { defined } @REQUEST_SCOPES;
    my $outside = sub {
        ( my $p = $_[0] // '' ) =~ s{\A/+}{};
        return 0 if $p =~ m{\Alazysite/};             # _confine_scope's own exemption
        return Lazysite::Manager::Common::outside_all_scopes( \@scopes, $p ) ? 1 : 0;
    };
    my $names = join ', ', map { ( my $s = $_ ) =~ s{^/+|/+$}{}g; "$s/" } @scopes;
    if ( my $denied = _acl_denied( $rel =~ s{\A/+}{}r, 'read', $auth_user ) ) {
        return $denied;
    }
    my $part_outside;    # the first part refused for scope, to say so below

    my $plugin = "$DOCROOT/../plugins/pandoc.pl";
    $plugin = "$DOCROOT/plugins/pandoc.pl" unless -f $plugin;
    return { ok => 0, error => 'The Branded PDF plugin is not installed' }
        unless -f $plugin;

    # The plugin decides everything about the conversion. This supplies only
    # what it cannot reach for: the docroot, and an answer to "may this reader
    # read that path?" - the content ACL, as SM706 asked for it.
    # The plugin is a PROGRAM, and declares no package - but it guards its own
    # entry point with `run(@ARGV) unless caller`, and `do` sets a caller frame.
    # So loading it defines its subs without executing it, which was tested
    # rather than assumed: a plugin that ran on load would print JSON into the
    # middle of this response.
    my $loaded = do { package main; do $plugin }; ## no critic (Modules::ProhibitMultiplePackages)
    return { ok => 0, error => "The Branded PDF plugin could not be loaded: $@" }
        if $@;
    return { ok => 0, error => 'The Branded PDF plugin could not be loaded' }
        unless $loaded;

    # Resolved at run time, because the sub does not exist until the line above.
    my $conv = main->can('convert')
        or return { ok => 0, error => 'The Branded PDF plugin has no converter' };

    my $out = eval {
        $conv->(
            docroot  => $DOCROOT,
            path     => $rel,
            may_read => sub {
                if ( $outside->( $_[0] ) ) { $part_outside //= $_[0]; return 0 }
                return !_acl_denied( $_[0], 'read', $auth_user );
            },

            # SM738: WHERE a file lives is the engine's business, not the
            # plugin's. A read ACL moves content into the private store, and the
            # plugin used to look only in the docroot - so a gated part was
            # "no such part" even to a reader authorised to read it, and the
            # may_read refusal above could never fire. The plugin asks; this
            # answers, the same way it answers may_read.
            resolve => sub {
                my ($rel) = @_;
                require Lazysite::Private;
                my ($abs) = Lazysite::Private::resolve( $DOCROOT, $rel );
                return $abs;
            },
        );
    };
    return { ok => 0, error => "PDF render failed: $@" } if $@;
    return { ok => 0, error => 'The PDF plugin returned nothing' }
        unless ref $out eq 'HASH';
    return { ok => 0, kind => 'forbidden',
        error => "This document includes '$part_outside', which is outside your assigned "
            . "scope ($names). It is refused rather than built without that part, so what "
            . 'you get is never quietly incomplete.' }
        if defined $part_outside && !$out->{ok};
    return $out unless $out->{ok} && $out->{pdf} && -f $out->{pdf}; # not a store: rendered output

    my $size = ( stat $out->{pdf} )[7] // 0;
    ( my $safe = $rel ) =~ s{.*/}{};
    $safe               =~ s/\.md\z//;
    $safe               =~ s/[\r\n"\\]//g;
    $safe .= '.pdf';
    log_event( 'INFO', 'page-pdf', 'page rendered to PDF',
        path => $rel, bytes => $size, cached => ( $out->{cached} ? 1 : 0 ),
        user => $auth_user );

    return { ok => 0, error => 'Cannot read the rendered PDF' }
        unless Lazysite::Manager::Upload::stream_attachment( $out->{pdf}, 'application/pdf',
        $safe, $size );
    return { ok => 1, streamed => 1 }; # Q16b: audited by the dispatcher, nothing after it
}

1;
