package Lazysite::Odoo::SiteSignin;

# SM1160 (inbox L3, rulings 2026-10-18): THE ODOO SIGN-IN AS THE SITE SIGN-IN -
# the configuration half, and nothing that touches Odoo or a cookie.
#
#   odoo_site_signin: on        opt-in per site; absent or anything else is off, and a
#                               site without it behaves exactly as it did
#   odoo_group_map: A = b, C = d
#                               Odoo group xml id -> lazysite group name. The person's
#                               Odoo groups are asked as the person for exactly these ids
#                               (OOM core.has_groups) and the held ones become the lazysite
#                               groups the page gate and the ACL already read
#   odoo_identity_ttl           the bound on how long a site session goes without Odoo
#                               being asked again (the same key the identity cookie uses)
#
# MANAGER RIGHTS ARE NEVER GRANTED THIS WAY. A mapping whose target group carries any
# capability (ui, manage_users, the manager flag, or any other key in
# Auth::Settings::@CAP_KEYS), directly or through the groups it nests, is refused BY NAME:
# at save (validate_group_map), and again every time the map is loaded (group_map), so a
# group that GAINED a capability after the map was saved stops being granted. A refused
# entry grants nothing and is reported by status and `lazysite check`. The test is
# "carries any capability" and not "carries a manager one" because the groups-only
# gates (Settings::groups_grant_cap, the ACL operator bypass) read capabilities off a
# request's group NAMES, and every capability key is a door of the manager or the API.
use strict;
use warnings;

our $TTL = 900;    # as Lazysite::Odoo::Identity: the identity cookie's default

my $XMLID  = qr/\A[A-Za-z_][\w-]*\.[\w-]+\z/;    # core.has_groups' own shape
my $TARGET = qr/\A[A-Za-z0-9_-]{1,64}\z/;        # a lazysite group name
our $MAX_GROUPS = 50;                            # core.has_groups' cap

# odoo.conf as key => value for a lazysite dir, {} when there is none. Last line wins.
sub conf {
    my ($dir) = @_;
    my %kv;
    return \%kv unless defined $dir && length $dir;
    open my $fh, '<:utf8', "$dir/odoo.conf" or return \%kv;
    while ( my $l = <$fh> ) {
        $kv{$1} = $2 if $l =~ /\A\s*([A-Za-z_]\w*)\s*:\s*(.*?)\s*\z/;
    }
    close $fh;
    return \%kv;
}

sub enabled {
    my ($dir) = @_;
    return ( lc( conf($dir)->{odoo_site_signin} // '' ) =~ /\A(?:on|yes|true|1)\z/ ) ? 1 : 0;
}

# SM1381: WHERE A STALE SITE SESSION IS RENEWED. A session past odoo_identity_ttl holds
# nothing until Odoo is asked again, and only the Odoo endpoint holds the person's Odoo
# session (its cookie is scoped to the endpoint's path), so the page gate sends the
# visitor here with `next`, and `?action=session` with `answer=session`. The verifier
# hands this path to core with its `odoo-stale` verdict (Auth::Session, `renew`), so
# core names no endpoint of its own. A path with a query, nothing else.
our $RENEW_PATH = '/cgi-bin/lazysite-odoo.pl?renew=1';

sub renew_path { return $RENEW_PATH }

# 60..86400 seconds, else the default - the rule Identity::configured_ttl applies.
sub identity_ttl {
    my ($dir) = @_;
    my $v = conf($dir)->{odoo_identity_ttl};
    return ( defined $v && $v =~ /\A[0-9]+\z/ && $v >= 60 && $v <= 86400 ) ? 0 + $v : $TTL;
}

# Does this lazysite group carry any capability, itself or through the groups it nests?
# Auth::Settings reads the site's group store from its AUTH_DIR, set here for the dir.
sub carries_capability {
    my ( $group, $dir ) = @_;
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$dir/auth";
    my $gs = Lazysite::Auth::Settings::read_group_settings();
    # a store that cannot be read says nothing about the group: unknown is not "safe"
    return 'its group settings cannot be read' if Lazysite::Auth::Settings::group_settings_unreadable();
    for my $g ( Lazysite::Auth::Settings::group_closure($group) ) {
        my $cfg = $gs->{$g};
        next unless ref $cfg eq 'HASH';
        return $g eq $group ? "the group '$group' carries capabilities" : "the group '$group' nests '$g', which carries capabilities"
            if $cfg->{manager} || grep { $cfg->{$_} } @Lazysite::Auth::Settings::CAP_KEYS;
    }
    return '';
}

# `a.b = grp, c.d = grp2` -> ( \%map, \@refused ). %map is only what may be granted;
# each @refused entry is { xmlid, group, why } and grants nothing.
sub parse_map {
    my ( $spec, $dir ) = @_;
    my ( %map, @refused );
    $spec = '' unless defined $spec;
    for my $entry ( split /,/, $spec ) {
        next unless $entry =~ /\S/;
        my ( $x, $to ) = split /=/, $entry, 2;
        $x  = '' unless defined $x;
        $to = '' unless defined $to;
        s/\A\s+|\s+\z//g for ( $x, $to );
        my $why;
        if ( $x !~ $XMLID ) { $why = 'the left side must be an Odoo group xml id (module.name)' }
        elsif ( $to !~ $TARGET ) { $why = 'the right side must be a lazysite group name (letters, digits, hyphen, underscore, at most 64)' }
        elsif ( keys %map >= $MAX_GROUPS && !exists $map{$x} ) { $why = "more than $MAX_GROUPS groups are mapped" }
        elsif ( length( my $cap = carries_capability( $to, $dir ) ) ) { $why = "$cap - manager rights are never granted by an Odoo group" }
        if ( defined $why ) { push @refused, { xmlid => $x, group => $to, why => $why }; next }
        $map{$x} = $to;
    }
    return ( \%map, \@refused );
}

sub group_map {
    my ($dir) = @_;
    return parse_map( conf($dir)->{odoo_group_map}, $dir );
}

# The save-time check (Manager::Extensions asks it of a field that declares `validate`):
# '' when every entry may be stored, else the sentence naming each refused entry.
sub validate_group_map {
    my ( $value, $dir )     = @_;
    my ( undef,  $refused ) = parse_map( $value, $dir );
    return '' unless @$refused;
    return join '; ', map { "'$_->{xmlid} = $_->{group}' is refused: $_->{why}" } @$refused;
}

# The lazysite groups a person holds: the targets of the xml ids Odoo answered 1 for.
sub groups_held {
    my ( $held, $map ) = @_;
    return [] unless ref $held eq 'HASH' && ref $map eq 'HASH';
    my %g = map { ( $map->{$_} => 1 ) } grep { $held->{$_} } keys %$map;
    return [ sort keys %g ];
}

# A login the site identity `odoo:<login>` may be made of: what Odoo reported, bounded and
# free of anything that would break a header, a log line or an audit field.
sub login_ok {
    my ($login) = @_;
    return defined $login && !ref $login && length $login && length $login <= 254
        && $login !~ /[\x00-\x1f\x7f|]/ ? 1 : 0;
}

# --- xml ids Odoo does not know: NOT NAMED (SM1217) -----------------------------------
#
# SM1160 named them from core.has_groups' `unknown` list, kept in odoo/unknown-groups.json.
# OOM 0.37 (fixes-37 R-1) answers `{ groups => { XMLID => 1|0 } }` only: an id Odoo has
# no group for answers 0, like a group the person does not hold. No OOM operation tells,
# as the person, whether a group exists, so lazysite cannot name them. Saying nothing
# would read as "every id is known", so the report says they are not named, and why. A
# file an older lazysite wrote is not read: nothing would ever correct it.
our $UNKNOWN_NOTE = 'an xml id Odoo does not know is answered as not held, so it grants nothing'
    . ' and is not named here: check each id against Odoo';

# What status and `lazysite check` show about the feature: nothing on a site that has not
# opted in.
sub report {
    my ($dir) = @_;
    return { enabled => 0 } unless enabled($dir);
    my ( $map, $refused ) = group_map($dir);
    return { enabled => 1, mapped => scalar( keys %$map ), refused => $refused, unknown_named => 0,
        unknown_note => $UNKNOWN_NOTE, ttl => identity_ttl($dir) };
}

# SM1160, moved here by SM1369 X5: the layout variable [% odoo_signin_banner %],
# a hook the descriptor declares (owns.hooks.template_vars), called by core with
# { docroot, lazysite_dir, version }. On a site that opted in to the Odoo sign-in
# as the site sign-in, the page's "Signed in as <name>" with a sign-out link -
# the same markup for every visitor, filled in by the browser helper from the
# signed identity (so a cached page is never one person's). '' on any other
# site. Safe markup: nothing of the request or the site is in it.
sub banner {
    my ($ctx) = @_;
    return '' unless ref $ctx eq 'HASH' && enabled( $ctx->{lazysite_dir} );
    return '<span class="ls-odoo-banner" data-ls-odoo-banner style="font-size:0.8rem;margin-left:auto;">'
        . '<span data-ls-odoo-in hidden>Signed in as <strong data-ls-odoo-name></strong> '
        . '<a href="#" data-ls-odoo-signout>Sign out</a></span>'
        . '<a href="#" data-ls-odoo-signin data-ls-odoo-out>Sign in</a></span>';
}

1;
