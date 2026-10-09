package Lazysite::Manager::Remap;

# The URL remapper's manager actions (SM802), remap-list and remap-save: who may
# say where a domain's visitors are sent, and the per-host rule write. Moved
# unchanged out of lazysite-manager-api.pl by SM944 S22.
#
# Index
#   _remap_unit_off       the refusal while the remap extension is switched off
#   _remap_scopes         the caller's content scopes (the token's own, or the
#                         request's)
#   _remap_host_in_scope  may this caller name this host
#   _remap_list           remap-list: every rule, or the caller's domains' only
#   _remap_save           remap-save: replace one domain's rules
#
# The request context ($auth_user, $token_auth, %token_caps, @REQUEST_SCOPES) is
# read from Lazysite::Manager::Common, which lazysite-manager-api.pl sets and
# nothing here assigns (t/lint/217). Loaded where no request set it, it is
# fail-closed: every host is outside the caller's scope (t/unit/manager/205).
# $DOCROOT is set by the dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util             qw(log_event);
use Lazysite::Paths            ();
use Lazysite::Manager::Common  qw($auth_user $token_auth %token_caps @REQUEST_SCOPES);
use Lazysite::Manager::Domains qw(domain_content_root);
use Lazysite::Manager::Plugins ();

our @EXPORT_OK = qw(_remap_list _remap_save);

our $DOCROOT;    # set by the script

# --- SM802: the URL remapper's two actions ------------------------------------
#
# Operator-only by ruling: a rule sends a visitor to another host, the same
# authority as a connector's destination. manage_domains, because the ruling
# calls this domain configuration, and PER HOST, so a save replaces one domain's
# rules and can never touch another's.
#
# THE SCOPE CHECK IS STRICTER THAN domain-set's, deliberately. domain-set skips
# a host with no content_root, and for a redirect that is a reach: this instance
# answers for its primary hostname and for any unregistered host pointed at it,
# so a scoped caller naming one could send another site's visitors anywhere. A
# scoped caller may name only a REGISTERED domain whose content lies inside its
# scope; everything else is refused.

sub _remap_unit_off {
    return undef if Lazysite::Manager::Plugins::plugin_enabled('plugins/remap.pl');
    return { ok => 0, kind => 'disabled',
        error => 'The URL remapper extension is switched off. An operator can '
            . 'enable it on the Extensions page.' };
}

sub _remap_scopes {
    return $token_auth ? @{ $token_caps{dav_scopes} || [] } : @REQUEST_SCOPES;
}

sub _remap_host_in_scope {
    my ($host) = @_;
    my @scopes = _remap_scopes();
    return 1 unless @scopes;
    my $root = domain_content_root($host);
    return 0 unless defined $root && length $root;
    return Lazysite::Manager::Common::outside_all_scopes( \@scopes, $root ) ? 0 : 1;
}

sub _remap_list {
    if ( my $off = _remap_unit_off() ) { return $off }
    require Lazysite::Remap;
    my $r      = Lazysite::Remap::report( Lazysite::Paths::lazysite_dir($DOCROOT) );
    my @scopes = _remap_scopes();
    $r->{rules} = [ grep { _remap_host_in_scope( $_->{host} ) } @{ $r->{rules} } ] if @scopes;
    return $r;
}

sub _remap_save {
    my ($req) = @_;
    if ( my $off = _remap_unit_off() ) { return $off }
    require Lazysite::Remap;
    my $host = lc( $req->{host} // '' );
    return { ok => 0, kind => 'invalid', field => 'host',
        error => 'remap-save needs a host: the domain whose rules these are.' }
        unless length $host;
    return { ok => 0, kind => 'forbidden',
        error => "Domain '$host' is not a registered domain inside your assigned "
            . 'scope, so you cannot set where its visitors are redirected.' }
        unless _remap_host_in_scope($host);
    my $rules = $req->{rules};
    return { ok => 0, kind => 'invalid', field => 'rules',
        error => 'rules must be a list of {prefix, destination, code} - an empty list removes this domain\'s rules.' }
        unless ref $rules eq 'ARRAY';

    my $lz = Lazysite::Paths::lazysite_dir($DOCROOT);
    my ( $existing, undef ) = Lazysite::Remap::parse_rules( Lazysite::Remap::read_rules_text($lz) );
    my @lines = map { join ' ', $_->{host}, $_->{prefix}, $_->{dest}, $_->{code} }
        grep { $_->{host} ne $host } @$existing;
    for my $r (@$rules) {
        return { ok => 0, kind => 'invalid', field => 'rules', error => 'each rule must be an object' }
            unless ref $r eq 'HASH';
        push @lines, join ' ', $host, ( $r->{prefix} // '' ), ( $r->{destination} // '' ),
            ( $r->{code} // 302 );
    }
    my $text = "# URL remapper rules (SM802) - host prefix destination [301|302]\n"
        . join( "\n", @lines ) . "\n";
    my $w = Lazysite::Remap::write_rules( $lz, $text );
    log_event( 'INFO', $auth_user // '-', 'remap rules saved', host => $host,
        rules => scalar @$rules ) if $w->{ok};
    return $w;
}

1;
