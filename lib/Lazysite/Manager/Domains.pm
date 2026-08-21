package Lazysite::Manager::Domains;

# SM154 (P2): the domain engine - register / list / configure / remove the
# domains this one lazysite instance serves. A domain is `alias_hosts` (the
# comma list of served hosts) + `alias.<host>.<key>` overrides in
# lazysite.conf, plus a content-root directory under the docroot. This module
# is the SINGLE source of that logic, shared by the manager control-API
# (domain-* actions) and the `lazysite-domains` CLI, so an external control
# panel can drive the lazysite side identically to the UI.
#
# HARD SCOPE LINE: lazysite owns only the lazysite side (conf + content root).
# DNS, the web-server domain alias and TLS are a PRECONDITION handled by the
# operator / Hestia / an external orchestrator - this module never touches
# them.

use strict;
use warnings;
use Cwd                       qw(realpath);
use File::Path                qw(make_path);
use Lazysite::Util            qw(log_event);
use Lazysite::Manager::Common qw(path_is_reserved processor_path conf_batch);
use Exporter 'import';
use Lazysite::Paths ();
our @EXPORT_OK = qw(domains_list domains_using domain_usage domain_add domain_remove domain_set domain_check domain_preview preview_public known_domain_host instance_public_ips host_for_path content_root_for_path);

our $DOCROOT;    # set by the caller (manager-api or the CLI)

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
our $auth_user = '';    # for log attribution

# Per-host presentation/routing keys that may be overridden for an alias. Same
# set the read-only view (action_domains_list) surfaces and domain_set accepts.
# content_root is the one that actually roots a domain's content; the rest are
# presentation. SM165 adds the two ACCESS keys: allowed_groups (comma list of
# groups that may manage this domain) and locked_users (comma list of accounts
# confined to it). SM179 adds the language keys: lang (this host's language) and
# lang_group (the language set it belongs to) - so a language set is configurable
# through the Domains page / control API / CLI, not only by hand-editing the conf.
my @DOMAIN_KEYS = qw(content_root site_url site_name theme layout nav_file
    search_default allowed_groups locked_users lang lang_group);
my %IS_KEY = map { $_ => 1 } @DOMAIN_KEYS;

sub _conf_path { return _lz() . "/lazysite.conf" }

# A host label is a lowercase DNS name: dot-separated labels of [a-z0-9-], no
# leading/trailing hyphen, no traversal, no scheme/port/path. Kept strict so a
# host can never be spelled to inject a conf line or escape a directory.
sub _valid_host {
    my ($h) = @_;
    return 0 unless defined $h && length $h && length $h <= 253;
    $h = lc $h;
    return 0 if $h =~ /[^a-z0-9.-]/;
    return 0 if $h =~ /\.\./ || $h =~ /^[.-]/ || $h =~ /[.-]$/;
    for my $label ( split /\./, $h ) {
        return 0 unless length $label && $label !~ /^-/ && $label !~ /-$/;
    }
    return 1;
}

# A content root is a docroot-relative directory. Reject traversal and any
# reserved (system) root - path_is_reserved is the single definition, shared
# with the manager blocklist and mirrored by the processor's
# confine_content_root: a domain's content must never be the secrets/auth/ACL
# tree. Returns the cleaned relative path, or undef.
sub _clean_content_root {
    my ($rel) = @_;
    return undef unless defined $rel && length $rel;
    $rel =~ s{^/+|/+$}{}g;
    return undef unless length $rel;
    return undef if $rel =~ m{(?:^|/)\.\.(?:/|$)};    # traversal
    return undef if $rel =~ m{(?:^|/)\.[^/]};         # dotfile/dotdir segment

    # SM268 03-F12: collapse `.` segments and refuse what is left empty. A
    # content_root of `.` is the docroot itself, and it passed every check above:
    # the dotdir test wants a character after the dot, and path_is_reserved
    # normalises `.` away to nothing. Accepted, it made package_create stage its
    # copy INSIDE the tree it was copying - the copy fed itself until the kernel
    # refused the path length and the CGI died with a 500, leaving a ~50-deep
    # directory behind. The staging prune in SitePackage::_copy_tree is the
    # second line; this is the first.
    $rel =~ s{(?:^|/)\.(?=/|$)}{/}g;
    $rel =~ s{/+}{/}g;
    $rel =~ s{^/+|/+$}{}g;
    return undef unless length $rel;

    return undef if path_is_reserved($rel);    # engine-owned (system) area
    return $rel;
}

# Parse the conf into ( \%base, \%overrides, \@hosts ). %overrides is
# host => { key => value }; @hosts is the ordered alias_hosts list.
sub _parse {
    my %base;
    my %ov;
    if ( open my $fh, '<:utf8', _conf_path() ) {
        while ( my $line = <$fh> ) {
            if ( $line =~ /^alias\.(\S+?)\.(\w+)\s*:\s*(.*?)\s*$/ ) {
                $ov{ lc $1 }{$2} = $3;
            }
            elsif ( $line =~ /^(\w+)\s*:\s*(.*?)\s*$/ ) {
                $base{$1} = $2;
            }
        }
        close $fh;
    }
    my @hosts = grep { length } map { s/^\s+|\s+$//gr } split /,/,
        ( $base{alias_hosts} // '' );
    return ( \%base, \%ov, \@hosts );
}

# Read the whole conf verbatim (for line-level rewrites).
sub _slurp {
    open my $fh, '<:utf8', _conf_path() or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# SM255: conf writes go through the ONE shared path, which locks, writes in place
# (preserving the inode and so the owner and mode - the field bug this module's
# own writer existed to avoid) and records the change in content history. Before
# this, config-set committed lazysite.conf and the domain verbs did not, on the
# same file; an operator cannot tell those apart and should not have to.
sub _write {
    my ( $content, $message ) = @_;
    # Each manager module carries its own $DOCROOT / $auth_user, set per request
    # by the dispatcher, so bridge this module's context into Common's for the
    # duration of the write - otherwise the shared writer looks in the wrong
    # docroot and attributes the commit to nobody.
    no warnings 'once';
    local $Lazysite::Manager::Common::DOCROOT   = $DOCROOT;
    local $Lazysite::Manager::Common::auth_user = $auth_user;
    return Lazysite::Manager::Common::write_conf_content( $content, $message );
}

# Set (or replace) one `alias.<host>.<key>: value` line in $content, returning
# the new content. Appends if absent.
sub _set_line {
    my ( $content, $host, $key, $value ) = @_;
    my $k  = "alias.$host.$key";
    my $qk = quotemeta $k;
    if ( $content =~ /^$qk\s*:/m ) {
        $content =~ s/^$qk\s*:.*$/$k: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$k: $value\n";
    }
    return $content;
}

# Set (or replace) a bare `key: value` line (used for alias_hosts).
sub _set_base {
    my ( $content, $key, $value ) = @_;
    my $qk = quotemeta $key;
    if ( $content =~ /^$qk\s*:/m ) {
        $content =~ s/^$qk\s*:.*$/$key: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$key: $value\n";
    }
    return $content;
}

# --- public: list ----------------------------------------------------------

# The domains this instance serves: the primary/default host (base keys) plus
# each alias, an override winning over the inherited base value. Mirrors the
# manager's read-only domains view.
sub domains_list {
    my ( $base, $ov, $hosts ) = _parse();
    my @domains = ( {
            host       => '(default)',
            is_primary => 1,
            map { $_ => ( $base->{$_} // '' ) } @DOMAIN_KEYS,
    } );
    for my $h (@$hosts) {
        my %row = ( host => $h, is_primary => 0 );
        for my $k (@DOMAIN_KEYS) {
            $row{$k} = defined $ov->{$h}{$k} ? $ov->{$h}{$k}      : ( $base->{$k} // '' );
            $row{ $k . '_inherited' } = defined $ov->{$h}{$k} ? 0 : 1;
        }
        push @domains, \%row;
    }
    return { ok => 1, domains => \@domains, keys => \@DOMAIN_KEYS };
}

# SM177: which registered domains (base + every alias/sub-domain) currently
# depend on a given layout - or a given theme UNDER a given layout. Sub-domains
# are first-class peers here: a theme/layout one of them uses must block its
# deletion just as the primary's active one does. Effective values resolve the
# same way the engine serves them - a per-host override wins, else the base value
# is inherited - so an alias that inherits the base layout but pins its own theme
# is matched correctly. Returns the list of host labels ('(default)' for the
# primary) that use it, most useful hosts first. Pass (layout => L) to find
# layout users; (theme => T, layout => L) to find theme users under layout L.

# SM238: render a registered domain as an anonymous visitor would see it, under
# its own Host - so a domain can be prepared and checked before DNS or TLS point
# at it. Moved here from lazysite-manager-api.pl so the control API and the MCP
# connector share ONE implementation rather than the connector growing a copy;
# that shared-module shape is also what SM239 asks for across the two surfaces.
#
# Shells the processor exactly as the dev server does: no auth headers, the
# target Host, and cache bypassed - so what comes back is the real per-Host
# render, with that domain's content root, layout, theme and nav all applied.
# SM238 follow-up: shared by domain_preview here and action_domain_check in the
# control API, so it carries a public name. Both bound an outbound probe or a
# render to operator-declared hosts - never an arbitrary target.
sub known_domain_host {
    my ($host) = @_;
    my @rows = @{ domains_list()->{domains} || [] };
    for my $r (@rows) {
        next     if $r->{is_primary};
        return 1 if lc( $r->{host} // '' ) eq $host;
    }
    my ($prim) = grep { $_->{is_primary} } @rows;
    if ( $prim && ( $prim->{site_url} // '' ) =~ m{^https?://([^/:]+)}i ) {
        return 1 if lc($1) eq $host;
    }
    return 0;
}

# SM436: does this value name a host that a public request could actually
# carry, and does it agree with the site_url beside it?
#
# NOT folded into _valid_host, deliberately: that is shared with domain_remove
# and domain_set, and tightening it there would strand an already-registered
# bad row - unremovable by the verb that exists to remove it. Registration is
# the only moment this can be caught, and it is also the LAST moment: `host`
# is not in @DOMAIN_KEYS, so domain_set cannot correct it and there is no
# rename verb. A value that cannot be edited afterwards has exactly one chance
# to be right.
#
# The incident: a domain registered as `dhcf` with site_url
# https://dhcf.sites.lazysite.io. The processor matches the FULL Host header
# with eq, so `dhcf` never matched, no alias overlay applied, and every
# request fell through to the primary - serving a different organisation's
# site under that name. The domain record, the render, the alias map and the
# domain check all looked correct; only following a request showed it. Both
# halves of the answer were already in the row.
sub _host_cannot_match {
    my ($host) = @_;
    return undef if $host =~ /\./;
    return 'A domain name needs at least one dot - "' . $host . '" is a single '
        . 'label, and no public request can arrive with it as its Host. If this '
        . 'is a subdomain, register the full name (for example '
        . $host . '.example.com).';
}

# The other half: the row disagreeing with itself. Kept separate from the dot
# check because domain_set must apply THIS one and not that one - an
# already-registered dotless host cannot be corrected (host is not settable and
# there is no rename), so answering a site_url edit with a message about
# registering it differently would misdirect. Removing it is the only route,
# and domain_remove deliberately does not run either check.
sub _host_disagrees_with_url {
    my ( $host, $site_url ) = @_;
    return undef unless defined $site_url && length $site_url;
    # A placeholder site_url (the primary's ${SERVER_NAME} form) names no host.
    return undef if $site_url =~ /\$\{/;
    return undef unless $site_url =~ m{^https?://([^/:?#]+)}i;
    my $url_host = lc $1;
    return undef if $url_host eq $host;
    return 'The site address names ' . $url_host . ' but the domain is '
        . $host . '. A request arrives under the name in the site address, so '
        . 'these disagreeing means this domain never matches and visitors get '
        . 'the default site instead. Use ' . $url_host . '.';
}

# SM441: which registered domain OWNS a docroot-relative path.
#
# The page previews shelled the processor without a Host, so SM151's per-Host
# routing never fired and a domain's page rendered with the BASE layout, theme
# and nav - whoever it belonged to. The content was right, because the
# docroot-relative path resolves under the primary, and the presentation was
# another site's. That is the awkward shape of it: it looks like a working
# preview of a page given the wrong theme, rather than a preview that has not
# been told which site it is previewing.
#
# LONGEST content_root wins, so a domain nested inside another's tree is
# resolved to the inner one. Returns '' for a path no content root contains -
# the primary owns it, and today's behaviour is already correct there.
#
# AMBIGUITY IS NOT RESOLVED HERE, only made deterministic: if two domains
# declare the SAME content_root there is no fact that decides between them, and
# the honest answer is a host selector on the preview. This picks the first by
# sorted host so the same path always previews the same way, which is strictly
# better than the primary-always behaviour it replaces, and returns the count
# so a caller can say so.
# SM440: the same walk, answering for the CONTENT ROOT rather than the host.
# Aliases need the root - to make a URL relative to the site that serves it,
# and to key the map per domain; previews need the host. ONE traversal, so the
# containment rule cannot drift between the two callers.
sub content_root_for_path {
    my ($rel) = @_;
    my ( $host, $tied, $root ) = _owner_for_path($rel);
    return ( $root, $host, $tied );
}

sub host_for_path {
    my ($rel) = @_;
    my ( $host, $tied ) = _owner_for_path($rel);
    return ( $host, $tied );
}

sub _owner_for_path {
    my ($rel) = @_;
    $rel = '' unless defined $rel;
    $rel =~ s{^/+}{};

    my $r = eval { domains_list() };
    return ( '', 0, '' ) unless ref $r eq 'HASH' && $r->{ok};

    my ( $best, @tied ) = ('');
    for my $d ( @{ $r->{domains} || [] } ) {
        next if $d->{is_primary};
        my $cr = $d->{content_root} // '';
        $cr =~ s{^/+|/+$}{}g;
        next unless length $cr;
        next if $cr =~ m{(?:^|/)\.\.(?:/|$)};
        next unless $rel eq $cr || index( $rel, "$cr/" ) == 0;

        if ( !length $best || length($cr) > length($best) ) {
            $best = $cr;
            @tied = ( $d->{host} );
        }
        elsif ( length($cr) == length($best) ) {
            push @tied, $d->{host};
        }
    }
    return ( '', 0, '' ) unless @tied;
    @tied = sort @tied;
    return ( $tied[0], scalar @tied, $best );
}

# SM282: what a PUBLIC visitor gets for one path.
#
# A draft section is invisible to the public and visible to a signed-in editor.
# That is the feature working, and it is exactly why the editor is the one
# person who cannot check it: everything looks fine from where they are
# standing. The current answer is a private browsing window, which works and
# means leaving the manager - while the thing being checked is precisely
# whether leaving the manager changes what you see.
#
# The machinery already existed one scope up. domain_preview shells the
# processor with every auth marker stripped, so a domain can be seen before DNS
# points at it. This is the same trick at page scope.
#
# SAFE BY CONSTRUCTION, and the construction is the point: the processor applies
# the identical refusal it would apply to a visitor, because it is not told who
# is asking. So a 404 or a redirect to /login is the CORRECT answer for a gated
# path and is reported as the finding rather than as an error - which is the
# whole reason an operator would run this.
sub preview_public {
    my ($rel) = @_;
    $rel = '/'     unless defined $rel && length $rel;
    $rel = "/$rel" unless $rel =~ m{^/};

    return { ok => 0, error => 'Invalid path' }
        if $rel =~ m{ \0 }x || $rel =~ m{ (?:^|/) \.\. (?:/|$) }x;

    local %ENV = %ENV;

    # The identity strip is the mechanism. Anything that could tell the
    # processor who is asking has to go, or the preview shows the operator
    # their own view and reports it as the public's - which is the defect this
    # exists to remove, wearing the costume of the fix.
    delete @ENV{
        grep {
            m{ \A (?: HTTP_X_REMOTE_ | LAZYSITE_AUTH_
                | HTTP_COOKIE | HTTP_AUTHORIZATION ) }x
        } keys %ENV
    };
    delete $ENV{HTTP_COOKIE};
    delete $ENV{HTTP_AUTHORIZATION};

    $ENV{DOCUMENT_ROOT}    = $DOCROOT;
    $ENV{REDIRECT_URL}     = $rel;
    $ENV{REQUEST_METHOD}   = 'GET';
    $ENV{QUERY_STRING}     = '';
    $ENV{LAZYSITE_NOCACHE} = '1';

    # SM441: render under the OWNING domain's Host, so the per-Host overlay
    # supplies that site's layout, theme and nav. Without this the preview
    # inherited the manager request's Host - normally the primary - and this
    # tool, whose whole claim is to show what a public visitor gets, showed a
    # different site's presentation.
    my ($owner) = host_for_path($rel);
    $ENV{HTTP_HOST} = $owner if length $owner;

    my $processor = processor_path();
    my $raw       = qx($^X \Q$processor\E 2>/dev/null);
    my $status    = $?;

    if ( $status != 0 ) {
        return { ok => 0, kind => 'render-failed',
            error => 'The processor failed to render ' . $rel };
    }
    unless ( defined $raw && $raw =~ /\r?\n\r?\n/ ) {
        return { ok => 0, kind => 'no-cgi-headers',
            error => 'The processor returned no CGI response for ' . $rel };
    }

    my ($head) = $raw =~ /\A(.*?)\r?\n\r?\n/s;
    ( my $body = $raw ) =~ s/\A.*?\r?\n\r?\n//s;
    utf8::decode($body);

    my ($code) = ( $head // '' ) =~ /^Status:\s*(\d{3})/m;
    $code //= 200;
    my ($location) = ( $head // '' ) =~ /^Location:\s*(\S+)/m;

    # The VERDICT, in the operator's terms rather than HTTP's. "404" is a fact
    # about a response; "a visitor does not see this page" is the answer to the
    # question they asked.
    my $visible
        = $code == 200                     ? 'visible'
        : ( $code == 404 )                 ? 'not-found'
        : ( $code >= 300 && $code < 400 )  ? 'redirected'
        : ( $code == 401 || $code == 403 ) ? 'refused'
        :                                    'other';

    return {
        ok      => 1,
        path    => $rel,
        status  => $code + 0,
        public  => ( $visible eq 'visible' ? JSON::PP::true : JSON::PP::false ),
        verdict => $visible,
        ( defined $location ? ( location => $location ) : () ),

        # A bounded excerpt, not the page. Enough to tell a rendered 404 from a
        # rendered page without shipping a whole document through the API.
        excerpt => substr( $body, 0, 400 ),
        note    => $visible eq 'visible'
        ? 'A visitor WOULD see this page.'
        : 'A visitor would NOT see this page - this is the expected result for '
            . 'a draft or protected section, and is the check succeeding.',
    };
}

sub domain_preview {
    my ($host) = @_;
    $host = lc( $host // '' );
    return { ok => 0, error => 'Invalid domain host' }
        unless $host =~ /\A [a-z0-9] (?:[a-z0-9-]*[a-z0-9])?
            (?: \. [a-z0-9] (?:[a-z0-9-]*[a-z0-9])? )* \z/x;

    # Only a registered domain (or the primary site's own host) may be previewed.
    return { ok => 0, error => "Not a registered domain: $host" }
        unless known_domain_host($host);

    local %ENV = %ENV;
    delete @ENV{ grep { /^(?:HTTP_X_REMOTE_|LAZYSITE_AUTH_)/ } keys %ENV };
    $ENV{DOCUMENT_ROOT}    = $DOCROOT;
    $ENV{HTTP_HOST}        = $host;
    $ENV{REDIRECT_URL}     = '/';
    $ENV{REQUEST_METHOD}   = 'GET';
    $ENV{QUERY_STRING}     = '';
    $ENV{LAZYSITE_NOCACHE} = '1';

    # SM257: this tool exists to VERIFY a domain renders before DNS points at it,
    # so it must not report success without having verified anything. It used to
    # discard the processor's stderr (2>/dev/null), never look at its exit
    # status, and return ok:1 whatever came back - so a dead processor, a render
    # that emitted nothing, and a genuinely blank page were one answer. An agent
    # checking its own work was told "fine" in every case.
    require File::Temp;
    my ( $efh, $errfile ) = File::Temp::tempfile( 'lzs-preview-XXXXXX', TMPDIR => 1 );
    close $efh;

    my $processor = processor_path();
    my $raw       = qx($^X \Q$processor\E 2>\Q$errfile\E);
    my $status    = $?;

    my $stderr = '';
    if ( open my $ef, '<:utf8', $errfile ) {
        local $/;
        $stderr = <$ef> // '';
        close $ef;
    }
    unlink $errfile;
    $stderr =~ s/\s+\z//;
    # Enough to identify the fault without returning a whole stack trace.
    $stderr = substr( $stderr, 0, 500 ) if length $stderr > 500;

    if ( $status != 0 ) {
        my $code = $status >> 8;
        my $sig  = $status & 127;
        return { ok => 0, kind => 'render-failed',
            error => "The processor failed to render $host"
                . ( $sig           ? " (killed by signal $sig)" : " (exit $code)" )
                . ( length $stderr ? ": $stderr" : '. It produced no diagnostic.' ) };
    }

    # A CGI response is headers, a blank line, then the body. No blank line means
    # the processor did not produce a response at all - distinct from producing
    # an empty one, and a different fault to chase.
    unless ( defined $raw && $raw =~ /\r?\n\r?\n/ ) {
        return { ok => 0, kind => 'no-cgi-headers',
            error => "The processor returned no CGI response for $host"
                . ( length $stderr ? ": $stderr" : '. Output was: '
                    . ( defined $raw && length $raw
                    ? '"' . substr( $raw, 0, 200 ) . '"'
                    : 'nothing at all.' ) ) };
    }

    ( my $output = $raw ) =~ s/\A.*?\r?\n\r?\n//s;  # strip CGI headers (ASCII, byte-safe)

    # qx() returns the processor's raw UTF-8 BYTES. respond() emits the JSON via
    # encode_json, which UTF-8-encodes CHARACTER strings - so bytes handed to it
    # get double-encoded (e => é -> Ã©, Thai -> mojibake). Decode to characters
    # here so the round-trip is clean. (Same raw-bytes-vs-characters trap the
    # resolve_json path fixed on the render side.)
    require Encode;
    $output = Encode::decode( 'UTF-8', $output );

    # An empty body is the signature of a broken render, not of a blank page: the
    # engine always emits a layout around whatever content it found, and a
    # missing page is a 404 document rather than nothing.
    return { ok => 0, kind => 'empty-render',
        error => "The processor rendered nothing for $host. The domain is "
            . 'registered, so check its content_root points at a directory with '
            . 'an index page.' }
        unless $output =~ /\S/;

    return { ok => 1, host => $host, html => $output };
}

# SM234: the whole usage picture in ONE parse. domains_using() re-reads and
# re-parses the domain config on every call, so asking it per theme costs a parse
# per row; a listing needs the inverse mapping anyway. Returns
# { layouts => { <layout> => [hosts] }, themes => { "<layout>\0<theme>" => [hosts] } }
# with '(default)' standing for the base site, matching domains_using's own
# vocabulary. Effective per-host values, so an alias inheriting the active layout
# but pinning its own theme is counted against that theme.
sub domain_usage {
    my ( $base, $ov, $hosts ) = _parse();
    my %use = ( layouts => {}, themes => {} );
    for my $h ( '', @$hosts ) {
        my $eff = sub {
            my ($k) = @_;
            return $base->{$k} // '' if $h eq '';
            return defined $ov->{$h}{$k} ? $ov->{$h}{$k} : ( $base->{$k} // '' );
        };
        my $layout = $eff->('layout');
        my $theme  = $eff->('theme');
        my $who    = ( $h eq '' ? '(default)' : $h );
        next unless length $layout;
        push @{ $use{layouts}{$layout} },          $who;
        push @{ $use{themes}{"$layout\0$theme"} }, $who if length $theme;
    }
    return \%use;
}

sub domains_using {
    my (%q) = @_;
    my ( $base, $ov, $hosts ) = _parse();

    my $eff = sub {
        my ( $h, $k ) = @_;
        return $base->{$k} // '' if $h eq '';
        return defined $ov->{$h}{$k} ? $ov->{$h}{$k} : ( $base->{$k} // '' );
    };

    my @using;
    for my $h ( '', @$hosts ) {
        my $layout = $eff->( $h, 'layout' );
        if ( defined $q{theme} ) {
            next unless $layout eq ( $q{layout} // '' );
            next unless $eff->( $h, 'theme' ) eq $q{theme};
        }
        else {
            next unless $layout eq ( $q{layout} // '' );
        }
        push @using, ( $h eq '' ? '(default)' : $h );
    }
    return @using;
}

# --- public: add -----------------------------------------------------------

# %opts: content_root (OPTIONAL - empty means the host serves the DEFAULT site,
# i.e. the docroot root, no per-host content of its own), and any of
# site_url/site_name/theme/layout/nav_file/search_default; seed => 1 to write a
# starter index.md (ignored when there is no content root of its own).
sub domain_add {
    my ( $host, %opts ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    # SM436: refuse a name no request can carry, and a name that disagrees
    # with its own site_url. Both are unrecoverable after this call - `host`
    # is not settable and there is no rename - and both are silent in
    # production: the domain simply never matches and the visitor is served
    # the primary's site under someone else's name.
    for my $why ( _host_cannot_match($host),
        _host_disagrees_with_url( $host, $opts{site_url} ) )
    {
        return { ok => 0, kind => 'invalid', error => $why } if $why;
    }

    # Empty content_root is allowed: the host then serves the default site.
    # A NON-empty value must clean (under the docroot, not a reserved area).
    my $raw      = $opts{content_root};
    my $has_root = defined $raw && $raw =~ /\S/;
    my $rel      = '';
    if ($has_root) {
        $rel = _clean_content_root($raw);
        return { ok => 0, kind => 'invalid',
            error => 'The content folder must be inside your site. '
                . 'The lazysite system area is reserved - pick another folder.' }
            unless defined $rel;
    }

    # SM179: validate the language keys the same way domain_set does - they land
    # in <html lang> and name an i18n file, so fail closed on a bad value.
    if ( defined $opts{lang} && length $opts{lang}
        && $opts{lang} !~ /^[A-Za-z]+(?:-[A-Za-z0-9]+)*\z/ )
    {
        return { ok => 0, kind => 'invalid', error => 'Invalid language tag' };
    }
    if ( defined $opts{lang_group} && length $opts{lang_group}
        && $opts{lang_group} !~ /^[A-Za-z0-9_-]+\z/ )
    {
        return { ok => 0, kind => 'invalid', error => 'Invalid lang_group name' };
    }
    # SEC (F6.11): every override value is written as a single conf line via
    # _set_line, so reject CR/LF in ANY of them - matching domain_set - so a value
    # cannot smuggle a second conf directive (e.g. a reserved content_root).
    for my $k (@DOMAIN_KEYS) {
        next unless defined $opts{$k};
        return { ok => 0, kind => 'invalid', error => 'Value must be a single line' }
            if $opts{$k} =~ /[\r\n]/;
    }

    my ( $base, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'exists', error => "Domain already registered: $host" }
        if grep { $_ eq $host } @$hosts;

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;

    # content_root first (only when the host has its own), then any presentation
    # overrides. With no content root the host writes no content_root line and
    # inherits the base - it serves the default site.
    $content = _set_line( $content, $host, 'content_root', $rel ) if length $rel;
    for my $k (@DOMAIN_KEYS) {
        next if $k eq 'content_root';
        next unless defined $opts{$k} && length $opts{$k};
        $content = _set_line( $content, $host, $k, $opts{$k} );
    }

    # Append the host to alias_hosts (preserve order).
    my @new_hosts = ( @$hosts, $host );
    $content = _set_base( $content, 'alias_hosts', join( ',', @new_hosts ) );

    my ( $ok, $err ) = _write( $content, "register domain $host" );
    return { ok => 0, error => $err } unless $ok;

    # A host with no content root of its own serves the default site - nothing
    # to provision or seed.
    unless ( length $rel ) {
        log_event( 'INFO', $host, 'domain registered (serves the default site)',
            host => $host, user => $auth_user );
        return { ok => 1, host => $host, content_root => '' };
    }

    # Provision the content-root directory (+ optional seed). A directory that
    # already exists is fine (adopting an existing tree).
    my $dir = "$DOCROOT/$rel";
    unless ( -d $dir ) {
        eval { make_path($dir); 1 }
            or return { ok => 0,
            error => "Domain registered but content root could not be created: $@" };
    }
    if ( $opts{seed} && !-e "$dir/index.md" ) {
        my $title = $opts{site_name} || $host;
        if ( open my $sf, '>:utf8', "$dir/index.md" ) {
            print {$sf} "---\ntitle: $title\n---\n\n# $title\n\n"
                . "This domain is served by lazysite. Replace this page.\n";
            close $sf;
        }
    }

    log_event( 'INFO', 'domain-add', 'domain registered',
        host => $host, content_root => $rel, user => $auth_user );
    return { ok => 1, host => $host, content_root => $rel };
}

# --- public: set -----------------------------------------------------------

sub domain_set {
    my ( $host, $key, $value ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);
    return { ok => 0, kind => 'invalid', error => "Not a settable domain key: $key" }
        unless defined $key && $IS_KEY{$key};
    $value = '' unless defined $value;

    # SM436: the same disagreement can be introduced after registration by
    # pointing site_url at a different name. The host cannot be changed to
    # match (not in @DOMAIN_KEYS, no rename verb), so accepting this would
    # leave a row that can never serve and can never be corrected in place.
    if ( $key eq 'site_url' && length $value ) {
        if ( my $why = _host_disagrees_with_url( $host, $value ) ) {
            return { ok => 0, kind => 'invalid', error => $why };
        }
    }

    if ( $key eq 'content_root' ) {
        my $rel = _clean_content_root($value);
        return { ok => 0, kind => 'invalid', error => 'Invalid content_root' }
            unless defined $rel;
        $value = $rel;
    }
    elsif ( $key eq 'allowed_groups' || $key eq 'locked_users' ) {
        # SM165: a comma list of group / account names. Normalise (trim, drop
        # blanks, dedupe) and reject any token that is not a plain name - this is
        # access-control config, so it fails closed rather than storing garbage.
        my @toks = grep { length } map { s/^\s+|\s+$//gr } split /,/, $value;
        for my $t (@toks) {
            return { ok => 0, kind => 'invalid', error => "Invalid name in $key: $t" }
                unless $t =~ /^[A-Za-z0-9_-]+\z/;
        }
        my %seen;
        $value = join ', ', grep { !$seen{$_}++ } @toks;
    }
    elsif ( $key eq 'lang' ) {
        # SM179: a BCP-47-ish language tag (en, fr, pt-BR). Strict - it lands in
        # <html lang> and names the i18n override file. Empty clears it.
        $value =~ s/^\s+|\s+$//g;
        return { ok => 0, kind => 'invalid', error => 'Invalid language tag' }
            unless $value eq '' || $value =~ /^[A-Za-z]+(?:-[A-Za-z0-9]+)*\z/;
    }
    elsif ( $key eq 'lang_group' ) {
        # SM179: the language-set name, shared across the set's hosts. A plain
        # name token; empty clears it.
        $value =~ s/^\s+|\s+$//g;
        return { ok => 0, kind => 'invalid', error => 'Invalid lang_group name' }
            unless $value eq '' || $value =~ /^[A-Za-z0-9_-]+\z/;
    }
    # Values are single-line conf values: no newlines.
    return { ok => 0, kind => 'invalid', error => 'Value must be a single line' }
        if $value =~ /[\r\n]/;

    my ( undef, undef, $hosts ) = _parse();
    return { ok => 0, kind => 'not-found', error => "Domain not registered: $host" }
        unless grep { $_ eq $host } @$hosts;

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;
    $content = _set_line( $content, $host, $key, $value );
    my ( $ok, $err ) = _write( $content, "set domain key $host" );
    return { ok => 0, error => $err } unless $ok;

    log_event( 'INFO', 'domain-set', 'domain key set',
        host => $host, key => $key, user => $auth_user );

    # SM241: binding a layout/theme to a domain must PUBLISH that theme's assets,
    # not merely record the choice. Without this the domain serves a 404
    # stylesheet: the layout renders its header, nav and footer correctly and the
    # page looks chrome-less because nothing styles it. That is what happened to
    # a secondary domain whose theme source was in the right place and whose
    # public mirror was never written.
    #
    # The mirror was previously written only by theme-activate, theme upload,
    # layout activate/install and site_apply - so the natural action for a
    # secondary domain was the one action that published nothing, and the
    # documented remedy (re-activate) is instance-wide and would switch the
    # PRIMARY site's theme.
    #
    # Mirrors the pair the host resolves to AFTER this change, using the theme's
    # own layout - the whole failure case is a secondary domain on a layout other
    # than the active one. Best-effort and non-fatal: the binding is recorded
    # either way, and _mirror_theme_assets already logs its own failure.
    # SM322: and REPORT what it mirrored. SM315 gave activation an
    # `assets_mirrored` count on the reasoning that zero is the whole point - a
    # theme that mirrors nothing is a site about to render unstyled, and at the
    # HTTP level that is indistinguishable from a working one. It was added to
    # action_theme_activate and not here, so the per-domain path - which is the
    # path a MULTI-DOMAIN instance uses, and the one whose failure SM315 was
    # written about - ran the mirror and threw the answer away.
    #
    # An agent binding a theme to a domain got ok:1 and no indication whether
    # anything had been published. That is how a fully unstyled site was handed
    # over on edge2 in August with every page returning 200.
    my $mirror;
    if ( $key eq 'layout' || $key eq 'theme' ) {
        my ( $l, $t ) = _effective_presentation($host);
        if ( length $l && length $t ) {
            local $@;
            eval {
                # Loaded and imported at RUNTIME: Themes uses this module, so a
                # compile-time `use` here would close the loop. _mirror_theme_assets
                # is in the Themes @EXPORT_OK set (SitePackage imports it the
                # ordinary way), so this is a published helper, not a reach inside.
                require Lazysite::Manager::Themes;
                Lazysite::Manager::Themes->import('_mirror_theme_assets');
                no warnings 'once';    # fully-qualified package vars
                local $Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
                local $Lazysite::Manager::Themes::LAZYSITE_DIR = _lz();
                local $Lazysite::Manager::Themes::action       = 'domain-set';
                $mirror = _mirror_theme_assets( $l, $t );
                1;
            } or log_event( 'WARN', 'domain-set', 'theme asset mirror skipped',
                host => $host, error => "$@" );
        }
    }

    my $res = { ok => 1, host => $host, key => $key, value => $value };
    if ( ref $mirror eq 'HASH' ) {
        $res->{assets_mirrored} = $mirror->{mirrored};
        if ( !$mirror->{mirrored} ) {
            push @{ $res->{warnings} ||= [] },
                'no theme assets were mirrored for this domain: '
                . ( $mirror->{reason} // 'unknown' )
                . ( $mirror->{expected}
                ? ". Assets belong in $mirror->{expected}"
                : '' )
                . ( $mirror->{misplaced}
                ? ' (found outside it: '
                    . join( ', ', @{ $mirror->{misplaced} } ) . ')'
                : '' )
                . '. This domain will render with no stylesheet, and every page '
                . 'will still return 200.';
        }
    }
    return $res;
}

# SM241: the layout+theme a host actually resolves to - its own override where it
# has one, the base site's value otherwise. Same resolution domain_usage uses, so
# what gets mirrored is what gets served.
sub _effective_presentation {
    my ($host) = @_;
    my ( $base, $ov ) = _parse();
    my $eff = sub {
        my ($k) = @_;
        return defined $ov->{$host}{$k} ? $ov->{$host}{$k} : ( $base->{$k} // '' );
    };
    return ( $eff->('layout'), $eff->('theme') );
}

# --- public: remove --------------------------------------------------------

# Unregisters the host: drops it from alias_hosts and strips every
# alias.<host>.* line. The content directory is LEFT IN PLACE by default (data
# safety); pass purge => 1 to remove it too.
sub domain_remove {
    my ( $host, %opts ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    my ( undef, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'not-found', error => "Domain not registered: $host" }
        unless grep { $_ eq $host } @$hosts;

    my $rel = $ov->{$host}{content_root};

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;

    # Strip every alias.<host>.<key> line.
    my $qh = quotemeta $host;
    $content =~ s/^alias\.$qh\.\w+\s*:.*\n//mg;

    # Rewrite alias_hosts without this host.
    my @remaining = grep { $_ ne $host } @$hosts;
    $content = _set_base( $content, 'alias_hosts', join( ',', @remaining ) );

    my ( $ok, $err ) = _write( $content, "remove domain $host" );
    return { ok => 0, error => $err } unless $ok;

    my $purged = 0;
    if ( $opts{purge} && defined $rel ) {
        my $clean = _clean_content_root($rel);
        if ( defined $clean ) {
            my $real  = realpath("$DOCROOT/$clean");
            my $droot = realpath($DOCROOT);
            if ( defined $real
                && defined $droot
                && $real ne $droot
                && index( $real, "$droot/" ) == 0 )
            {
                require File::Path;
                eval { File::Path::remove_tree($real); $purged = 1; 1 };
            }
        }
    }

    log_event( 'INFO', 'domain-remove', 'domain unregistered',
        host => $host, purged => $purged, user => $auth_user );
    return { ok => 1, host => $host, purged => $purged };
}

# --- public: check a domain's live configuration (SM156) -------------------

# Resolve a host to its distinct IP addresses (v4 + v6). Returns the list, or
# () when the name does not resolve. Loaded lazily - the network modules must
# not add to every manager request's startup.
sub _resolve_ips {
    my ($host) = @_;
    return () unless eval { require Socket; 1 };    # absent => treated as "no resolution"
    my ( $err, @res )
        = Socket::getaddrinfo( $host, '', { socktype => Socket::SOCK_STREAM() } );
    return () if $err;
    my ( %seen, @ips );
    for my $ai (@res) {
        my ( $e, $ip )
            = Socket::getnameinfo( $ai->{addr}, Socket::NI_NUMERICHOST(), Socket::NIx_NOSERV() );
        next if $e;
        push @ips, $ip unless $seen{$ip}++;
    }
    return @ips;
}

# SSRF guard (SEC-2026-07, 0.8.1): domain-check opens outbound TLS + HTTPS
# connections to a caller-influenced host. A manage_domains delegate could point
# that at the server's own internal network - loopback, RFC1918, the cloud
# metadata endpoint (169.254.169.254), CGNAT, an IPv6 ULA/link-local - directly
# (an IP-literal or 'localhost' host, both of which pass _valid_host) or via DNS
# rebinding (a public name that resolves to an internal address). The connection
# is refused unless every RESOLVED address is public, so the guard holds for the
# rebinding case too (it keys on the resolved IPs, not the name). Returns 1 for a
# routable public address, 0 for anything internal/reserved/malformed.
sub _ip_is_public {
    my ($ip) = @_;
    return 0 unless defined $ip && length $ip;
    $ip =~ s/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)//i;    # IPv4-mapped IPv6 -> test the v4
    if ( $ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ ) {
        my @o = ( $1, $2, $3, $4 );
        return 0 if grep { $_ > 255 } @o;                           # malformed
        return 0 if $o[0] == 0;                                     # 0.0.0.0/8 this-host
        return 0 if $o[0] == 10;                                    # 10/8 private
        return 0 if $o[0] == 127;                                   # 127/8 loopback
        return 0 if $o[0] == 169 && $o[1] == 254;    # 169.254/16 link-local + metadata
        return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;    # 172.16/12 private
        return 0 if $o[0] == 192 && $o[1] == 168;                  # 192.168/16 private
        return 0 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127;    # 100.64/10 CGNAT
        return 0 if $o[0] >= 224;    # 224/4 multicast, 240/4 reserved
        return 1;
    }
    my $l = lc $ip;
    $l =~ s/%.*$//;                           # strip an IPv6 zone id (fe80::1%eth0)
    return 0 if $l eq '::' || $l eq '::1';    # unspecified / loopback
    return 0 if $l =~ /^fe[89ab]/;            # fe80::/10 link-local
    return 0 if $l =~ /^f[cd]/;               # fc00::/7 unique-local
    return 1;                                 # global unicast
}

# Open a verified TLS connection to $host:443. A connection only forms when the
# certificate is valid AND matches the host (SSL_verify_mode PEER + SNI), so a
# returned {ok=>1} means "trusted HTTPS". When full verification fails we probe
# again verifying the CHAIN but NOT the hostname, to tell a SAN/coverage gap
# (a trusted cert is served but does not cover this host - e.g. Hestia did not
# add the sub-domain to the certificate) apart from "no trusted HTTPS at all".
# Detail carries the CN and expiry when they can be read; never throws.
sub _tls_probe {
    my ( $host, $timeout ) = @_;
    return { ok => 0, detail => 'TLS check unavailable (IO::Socket::SSL not installed)' }
        unless eval { require IO::Socket::SSL; 1 };

    my $sock = IO::Socket::SSL->new(
        PeerHost          => $host,
        PeerPort          => 443,
        Timeout           => $timeout,
        SSL_verify_mode   => IO::Socket::SSL::SSL_VERIFY_PEER(),
        SSL_hostname      => $host,
        SSL_verifycn_name => $host,
    );
    if ($sock) {
        my $cn      = eval { $sock->peer_certificate('commonName') } // '';
        my $expires = eval {
            require Net::SSLeay;    # IO::Socket::SSL's backend; named for the SBOM
            my $t = Net::SSLeay::X509_get_notAfter( $sock->peer_certificate );
            $t ? Net::SSLeay::P_ASN1_TIME_get_isotime($t) : '';
        } // '';
        close $sock;
        my $detail = 'valid certificate';
        $detail .= " for $cn"           if length $cn;
        $detail .= ", expires $expires" if length $expires;
        return { ok => 1, detail => $detail, expires => $expires };
    }

    my $e = do { no warnings 'once'; $IO::Socket::SSL::SSL_ERROR || $! || 'connection failed' };
    $e =~ s/\s+/ /g;

    # Chain-only probe: same connection, hostname verification disabled. If it
    # succeeds, a TRUSTED certificate is served - it just does not cover $host.
    my $chain = IO::Socket::SSL->new(
        PeerHost            => $host,
        PeerPort            => 443,
        Timeout             => $timeout,
        SSL_verify_mode     => IO::Socket::SSL::SSL_VERIFY_PEER(),
        SSL_hostname        => $host,     # SNI, so the server returns its cert
        SSL_verifycn_scheme => 'none',    # verify the chain, NOT the hostname
    );
    if ($chain) {
        # What the cert DOES cover: its dNSName SANs (type 2), falling back to
        # the CN - so the operator sees exactly which name is missing.
        my @san = eval {
            map  { $_->[1] }
            grep { ref $_ eq 'ARRAY' && $_->[0] == 2 }
                $chain->peer_certificate('subjectAltNames');
        };
        my $cn = eval { $chain->peer_certificate('commonName') } // '';
        close $chain;
        my ( %seen, @cover );
        for ( @san, $cn ) { push @cover, $_ if defined && length && !$seen{$_}++ }
        my $shown
            = @cover > 6 ? ( join( ', ', @cover[ 0 .. 5 ] ) . ', …' ) : join( ', ', @cover );
        my $detail = 'a certificate is served';
        $detail .= " (covers $shown)" if length $shown;
        $detail .= ' but not this host'
            . ' - add this host to the certificate (e.g. via Hestia SSL)';
        return { ok => 0, kind => 'cert-mismatch', detail => $detail, covers => \@cover };
    }

    return { ok => 0, detail => "no trusted HTTPS ($e)" };
}

# GET the public instance marker over $host and read back its instance id, so
# the caller can tell whether the request terminated on THIS install.
sub _marker_fetch {
    my ( $host, $timeout ) = @_;
    return { ok => 0, detail => 'HTTPS check unavailable (HTTP::Tiny not installed)' }
        unless eval { require HTTP::Tiny; 1 };
    my $http = HTTP::Tiny->new(
        timeout    => $timeout,
        verify_SSL => 1,
        agent      => 'lazysite-domain-check/1 ',
    );
    my $res = $http->get("https://$host/.well-known/lazysite-instance.json");
    unless ( $res->{success} ) {
        my $why = $res->{status} == 599 ? ( $res->{content} || 'network error' )
            :   "HTTP $res->{status}";
        $why =~ s/\s+/ /g;
        return { ok => 0, detail => $why };
    }
    my ($inst) = ( $res->{content} // '' ) =~ /"instance"\s*:\s*"([0-9a-f]{1,64})"/;
    return { ok => 1, instance => ( $inst // '' ), detail => 'marker answered' };
}

# True for a routable public address - excludes RFC1918 / loopback / link-local
# (v4) and loopback / link-local / unique-local (v6). Used so a private
# SERVER_ADDR (the norm behind a proxy) is never taken for the public address.
sub _is_public_ip {
    my ($ip) = @_;
    return 0 unless defined $ip && length $ip;
    if ( $ip =~ /:/ ) {    # IPv6
        my $l = lc $ip;
        return 0 if $l eq '::1';                   # loopback
        return 0 if $l =~ /^fe80:/;                # link-local
        return 0 if $l =~ /^f[cd][0-9a-f]{2}:/;    # unique-local (fc00::/7)
        return 1;
    }
    my @o = $ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ or return 0;
    return 0 if $o[0] == 0 || $o[0] == 10 || $o[0] == 127;
    return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 0 if $o[0] == 192 && $o[1] == 168;
    return 0 if $o[0] == 169 && $o[1] == 254;    # link-local
    return 1;
}

# The PUBLIC address(es) an operator would point a domain at to reach THIS
# install - for the "points to this server" check. Behind a proxy/NAT the
# private SERVER_ADDR is wrong, so discover the public address in order:
#   1. canonical_ip (an explicit override, or the config key) - authoritative;
#   2. resolving the install's own domain (the primary site_url host), which
#      goes through the same public entry point a new domain must;
#   3. SERVER_ADDR, only if it is itself public (a non-proxied host).
# Empty list => undecidable; the check then reports "unknown", not a failure.
sub instance_public_ips {
    my (%o)    = @_;
    my ($base) = _parse();

    my $cfg = ( defined $o{canonical_ip} && length $o{canonical_ip} )
        ? $o{canonical_ip}
        : ( $base->{canonical_ip} // '' );
    if ( length $cfg ) {
        my @ips = grep { _is_public_ip($_) } map { s/^\s+|\s+$//gr } split /,/, $cfg;
        return @ips if @ips;
    }

    my $site_url = $base->{site_url} // '';
    if ( $site_url =~ m{^https?://([^/:]+)}i ) {
        my @ips = grep { _is_public_ip($_) } _resolve_ips( lc $1 );
        return @ips if @ips;
    }

    return ( $o{fallback_ip} )
        if length( $o{fallback_ip} // '' ) && _is_public_ip( $o{fallback_ip} );

    return ();
}

# domain_check($host, %opt) - is $host configured to serve THIS install live?
# Runs four ordered checks and returns them as an array (UI renders in order):
#   dns        - the name resolves to an address
#   host       - one of those addresses is THIS server (opt{self_ips}); undef
#                (indeterminate) when our public address is unknown
#   ssl        - a trusted certificate terminates for the host
#   terminates - an HTTPS request lands on THIS install (marker id == opt{instance_id})
# %opt: self_ips (arrayref) or self_ip, instance_id, timeout; and
#       resolve/tls/fetch code-ref overrides
# so tests drive every branch without touching the network. A check `pass` is
# 1, 0, or undef (indeterminate - e.g. this server's own address is unknown).
sub domain_check {
    my ( $host, %opt ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    # The server's own PUBLIC address(es). A list, because behind a proxy / NAT
    # the private SERVER_ADDR is useless - the caller self-discovers the public
    # IP(s) (operator canonical_ip, or resolving the install's own domain) and
    # passes them here. self_ip (scalar) is still accepted for a simple caller.
    my @self_ips
        = $opt{self_ips} ? grep { length } @{ $opt{self_ips} }
        : ( defined $opt{self_ip} && length $opt{self_ip} ) ? ( $opt{self_ip} )
        :                                                     ();
    my $instance = $opt{instance_id} // '';
    my $timeout  = $opt{timeout} || 6;
    my $resolve  = $opt{resolve} || \&_resolve_ips;
    my $tls      = $opt{tls}     || \&_tls_probe;
    my $fetch    = $opt{fetch}   || \&_marker_fetch;

    my @checks;

    # 1. DNS resolution.
    my @ips    = $resolve->($host);
    my $dns_ok = @ips ? 1 : 0;
    push @checks, {
        id     => 'dns',
        label  => 'DNS resolves',
        pass   => $dns_ok,
        detail => $dns_ok
        ? ( 'resolves to ' . join( ', ', @ips ) )
        : 'the host name does not resolve yet - add the DNS record',
    };

    # SSRF guard: if ANY resolved address is non-public, refuse the outbound TLS
    # and marker connections below. Keying on the resolved IPs (not the host name)
    # closes the DNS-rebinding path too. A public domain legitimately never
    # resolves to an internal address, so this only ever fires on abuse.
    my @nonpublic  = grep { !_ip_is_public($_) } @ips;
    my $ssrf_block = @nonpublic ? 1 : 0;

    # 2. Points to this server (a resolved IP is one of ours). Behind a proxy or
    # NAT the server cannot know its own public IP, so when none was discovered
    # this is INDETERMINATE (undef), not a failure - the "Serves this lazysite"
    # check below is the authoritative reachability signal.
    if ( !$dns_ok ) {
        push @checks, { id => 'host', label => 'Points to this server',
            pass => 0, detail => 'skipped - the host does not resolve' };
    }
    elsif ( !@self_ips ) {
        push @checks, {
            id     => 'host',
            label  => 'Points to this server',
            pass   => undef,
            detail => "this server's public address is unknown (behind a proxy/NAT?) - "
                . 'set canonical_ip in config to enable this check',
        };
    }
    else {
        my %mine = map { $_ => 1 } @self_ips;
        my ($match) = grep { $mine{$_} } @ips;
        push @checks, {
            id     => 'host',
            label  => 'Points to this server',
            pass   => $match ? 1 : 0,
            detail => $match
            ? "points here ($match)"
            : ( 'resolves to ' . join( ', ', @ips )
                    . ', not this server (' . join( ', ', @self_ips ) . ')' ),
        };
    }

    # 3. Trusted HTTPS certificate. Refused (not probed) when the host resolves
    # to a non-public address - see the SSRF guard above.
    if ($ssrf_block) {
        push @checks, { id => 'ssl', label => 'HTTPS certificate valid', pass => 0,
            detail => 'refused - the host resolves to a non-public address ('
                . join( ', ', @nonpublic ) . '); not probed (SSRF guard)' };
    }
    else {
        my $ssl = $tls->( $host, $timeout );
        push @checks, { id => 'ssl', label => 'HTTPS certificate valid',
            pass => $ssl->{ok} ? 1 : 0, detail => $ssl->{detail} };
    }

    # 4. Terminates on THIS install (marker id match). Also refused under the guard.
    if ($ssrf_block) {
        push @checks, { id => 'terminates', label => 'Serves this lazysite', pass => 0,
            detail => 'refused - the host resolves to a non-public address ('
                . join( ', ', @nonpublic ) . '); not fetched (SSRF guard)' };
    }
    else {
        my $mk = $fetch->( $host, $timeout );
        my $term_ok
            = ( $mk->{ok} && length $instance && ( $mk->{instance} // '' ) eq $instance ) ? 1 : 0;
        my $tdetail
            = !$mk->{ok} ? ( 'no reply over HTTPS - ' . ( $mk->{detail} || 'unreachable' ) )
            : $term_ok   ? 'serves this lazysite instance'
            :              'reachable, but answered by a different server or instance';
        push @checks, { id => 'terminates', label => 'Serves this lazysite',
            pass => $term_ok, detail => $tdetail };
    }

    my $all_pass = ( grep { defined $_->{pass} && !$_->{pass} } @checks ) ? 0 : 1;
    return { ok => 1, host => $host, all_pass => $all_pass, checks => \@checks };
}

1;
