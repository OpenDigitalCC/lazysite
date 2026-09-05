package Lazysite::Manager::StartPage;

# SM724: a user has a start page - where a sign-in with no destination lands.
#
# THE RULING (release manager, 2026-09-05): the fallback is the manager with the
# user's own account sheet open; the user, or a user manager, may set the start
# page; a domain target is a chosen page on that domain, not only its root.
#
# THREE THINGS DECIDE THE SHAPE, and each is a rule here rather than a comment:
#
# 1. A DOMAIN IS NOT A PATH. The login's `next` guard (sanitise_next) exists to
#    stop a sign-in redirecting off-site, and a "domains" dropdown proposes
#    exactly that. So a domain target is checked against the domains THIS
#    INSTANCE SERVES, by name, never against a character class - and the two
#    kinds of target are stored as two kinds (`manager:<page>` and
#    `domain:<host>|<path>`) so the distinction cannot be lost in one field.
#
# 2. A START PAGE THE USER CANNOT REACH TURNS SIGN-IN INTO A REFUSAL. The
#    choices offered for an account are computed from THAT account's grants -
#    the target's, never the operator's building the list - and a grant can
#    change after the choice is made, so resolve() checks again at every login
#    and falls back WITH A REASON rather than sending someone to a 403 forever.
#
# 3. AN EXPLICIT `next` WINS. Someone bounced to login from a page is going
#    somewhere; the start page is for an arrival with no destination. The
#    caller decides that (lazysite-auth.pl asks only when next is '/').
#
# The setting is a PREFERENCE, like display_name (SM642): nothing grants,
# confines, audits or looks an account up by it.
use strict;
use warnings;
use Exporter qw(import);
our @EXPORT_OK = qw(parse_start_page validate_start_page start_page_choices
    resolve_start_page fallback_landing manager_pages current_start_page apply_start_page);

our $DOCROOT = '';

# THE MANAGER PAGES A START PAGE MAY NAME, with the capability that reaches
# each (any-of; an empty list means every interactive account). This is the
# nav's own gating in starter/lazysite/manager/layout.tt, held here as data;
# t/lint/116 pins the two together so a page cannot be offered that the nav
# would not show, or shown that this would refuse. `plugin` names a plugin the
# page needs enabled. Pages that take a path (edit) or are a reference
# (style-guide) are not start pages.
our %PAGES = (
    'index'      => { label => 'Site settings', caps => [] },
    'files'      => { label => 'Files',         caps => ['manage_content'] },
    'nav'        => { label => 'Navigation',    caps => ['manage_nav'] },
    'appearance' => { label => 'Appearance', caps => [ 'manage_themes', 'manage_layouts' ] },
    'plugins'       => { label => 'Plugin Manager',  caps => [] },
    'plugin-config' => { label => 'Plugin Config',   caps => [] },
    'users'         => { label => 'Users',           caps => [] },
    'groups'        => { label => 'Groups',          caps => [] },
    'sessions'      => { label => 'Sessions & keys', caps => [] },
    'domains'       => { label => 'Domains',         caps => ['manage_domains'] },
    'cache'         => { label => 'Cache',           caps => [] },
    'backups'       => { label => 'Backups',         caps => [] },
    'audit'         => { label => 'Audit log',       caps => ['audit'] },
    'data'  => { label => 'Data tables', caps => ['manage_data'], plugin => 'data.pl' },
    'stats' => { label => 'Visitor statistics', caps => [],       plugin => 'stats.pl' },
);
my @PAGE_ORDER = qw(index files nav appearance plugins plugin-config users groups
    sessions domains cache backups audit data stats);

sub manager_pages { return map { { id => $_, %{ $PAGES{$_} } } } @PAGE_ORDER }

# The fallback: the manager, with the signed-in user's own account sheet open.
# `start=unreachable` when a set start page could not be honoured, so the
# manager can say why they are here instead of where they asked to be.
sub fallback_landing {
    my (%o) = @_;
    my $url = '/manager/?account=1';
    $url .= '&start=unreachable' if $o{unreachable};
    return $url;
}

# --- the stored form --------------------------------------------------------

# `manager:<page>` or `domain:<host>|<path>` (host may be `(default)` for the
# primary). Returns a hashref, or undef with the reason in $_[1] if given.
sub parse_start_page {
    my ($value) = @_;
    return undef unless defined $value && length $value;
    if ( $value =~ /\Amanager:([a-z][a-z-]*)\z/ ) {
        my $page = $1;
        return { kind => 'manager', page => $page };
    }
    if ( $value =~ /\Adomain:([^|]+)\|(.*)\z/s ) {
        my ( $host, $path ) = ( $1, $2 );
        $path = q{/} unless length $path;
        return { kind => 'domain', host => $host, path => $path };
    }
    return undef;
}

sub _path_ok {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    return 0 if $path     =~ m{\A(?://|\\)};
    return 0 unless $path =~ m{\A/[\w/.\-~]*\z};
    return 0 if $path     =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 1;
}

# --- what an account can reach -------------------------------------------------

sub _caps_for {
    my ($user) = @_;
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
    return Lazysite::Auth::Settings::caps_for($user) || {};
}

sub _scopes_for {
    my ($user) = @_;
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
    my @s = eval { Lazysite::Auth::Settings::resolve_user_scopes( $DOCROOT, $user ) };
    return @s;
}

sub _plugin_enabled {
    my ($script) = @_;
    require Lazysite::Manager::Plugins;
    no warnings 'once';
    local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
    return Lazysite::Manager::Plugins::plugin_enabled($script) ? 1 : 0;
}

sub _domains {
    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my $r = eval { Lazysite::Manager::Domains::domains_list() };
    return ref $r eq 'HASH' ? @{ $r->{domains} || [] } : ();
}

sub _page_reachable {
    my ( $page, $caps ) = @_;
    my $p = $PAGES{$page} or return 0;
    return 0 unless $caps->{ui};
    return 0 if $p->{plugin} && !_plugin_enabled( $p->{plugin} );
    return 1 unless @{ $p->{caps} };
    return ( grep { $caps->{$_} } @{ $p->{caps} } ) ? 1 : 0;
}

sub _domain_reachable {
    my ( $host, $user ) = @_;
    my ($d) = grep { lc( $_->{host} // '' ) eq lc $host } _domains();
    return ( 0, "'$host' is not a domain this instance serves" ) unless $d;
    my @scopes = _scopes_for($user);
    return ( 1, $d ) unless @scopes;    # unbound: every domain
    my $cr = $d->{content_root} // '';
    require Lazysite::Manager::Common;
    return ( 0, "'$host' is outside the account's confinement" )
        if !length $cr
        || Lazysite::Manager::Common::outside_all_scopes( \@scopes, $cr );
    return ( 1, $d );
}

# The dropdown, for ONE account, from that account's own grants.
sub start_page_choices {
    my ($user) = @_;
    my $caps   = _caps_for($user);
    my @pages  = map { { value => "manager:$_->{id}", label => $_->{label} } }
        grep { _page_reachable( $_->{id}, $caps ) } manager_pages();
    my @domains;
    for my $d ( _domains() ) {
        my $host = $d->{host} // '';
        next unless length $host;
        my ($ok) = _domain_reachable( $host, $user );
        next unless $ok;
        push @domains, {
            host => $host,
            label => $d->{is_primary} ? ( $d->{site_name} || 'this site' ) . ' (primary)' : $host,
        };
    }
    return { pages => \@pages, domains => \@domains };
}

# Refuse a start page the account cannot reach, at SET time. Returns the
# reason, or undef when it is fine. Empty clears and is always fine.
sub validate_start_page {
    my ( $user, $value ) = @_;
    return undef unless defined $value && length $value;
    my $p = parse_start_page($value)
        or return "a start page is 'manager:<page>' or 'domain:<host>|<path>' - got '$value'";
    if ( $p->{kind} eq 'manager' ) {
        return "'$p->{page}' is not a manager page a start page may name" unless $PAGES{ $p->{page} };
        return "'$user' cannot reach the manager page '$p->{page}' - it needs "
            . join( ' or ', @{ $PAGES{ $p->{page} }{caps} } )
            . ( $PAGES{ $p->{page} }{plugin} ? " (and the $PAGES{ $p->{page} }{plugin} plugin enabled)" : '' )
            unless _page_reachable( $p->{page}, _caps_for($user) );
        return undef;
    }
    return "the path '$p->{path}' is not a page path on this site (a leading slash, then letters, digits, / . - _)"
        unless _path_ok( $p->{path} );
    my ( $ok, $why ) = _domain_reachable( $p->{host}, $user );
    return $why unless $ok;
    return undef;
}

# The users tool's `set USER start_page VALUE`: trims, validates against the
# account's own reach, stores or clears. Dies with the reason so the tool's
# caller sees it as every other setting's refusal; sets $DOCROOT for the call.
sub apply_start_page {
    my ( $all, $user, $value, $docroot ) = @_;
    local $DOCROOT = $docroot if defined $docroot && length $docroot;
    my $v = defined $value ? "$value" : '';
    $v =~ s/^\s+|\s+$//g;
    if ( !length $v ) { delete $all->{$user}{start_page}; return }
    my $why = validate_start_page( $user, $v );
    die "start_page refused: $why\n" if defined $why;
    $all->{$user}{start_page} = $v;
    return;
}

# The stored value, raw. settings-get returns the RESOLVED settings (grants),
# which is not where a preference lives; this reads the account's own record.
sub current_start_page {
    my ($user) = @_;
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
    my $all = Lazysite::Auth::Settings::read_settings();
    return ( $all->{$user} || {} )->{start_page} // '';
}

# --- at sign-in -------------------------------------------------------------------

# Where this account lands when it signed in with no destination. Always
# returns { url => ... }; adds `unreachable => reason` when a set start page
# could not be honoured, and `set => 0` when none is set.
sub resolve_start_page {
    my ($user) = @_;
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
    my $value = current_start_page($user);
    return { url => fallback_landing(), set => 0 } unless length $value;

    my $why = validate_start_page( $user, $value );
    return { url => fallback_landing( unreachable => 1 ), set => 1, unreachable => $why }
        if defined $why;

    my $p = parse_start_page($value);
    return { url => "/manager/$p->{page}", set => 1 } if $p->{kind} eq 'manager' && $p->{page} ne 'index';
    return { url => '/manager/', set => 1 } if $p->{kind} eq 'manager';

    my ( undef, $d ) = _domain_reachable( $p->{host}, $user );
    if ( $d->{is_primary} ) {
        return { url => $p->{path}, set => 1 };    # same host: a relative path
    }
    # ANOTHER HOST THIS INSTANCE SERVES. Absolute, so the browser changes
    # host; https because the instance's sites are. The host came from the
    # domains list, not from the caller - that is what makes this not an
    # open redirect.
    return { url => "https://$p->{host}$p->{path}", set => 1 };
}

1;
