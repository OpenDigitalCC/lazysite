package Lazysite::Manager::AddressProfiles;

# SM1138 (slice A of SM1134), SM1343 (0.16.5): the manager's and the remote doors'
# view of the address-profile store.
#
#   address-profiles        read-only: every profile, its entries and notes.
#                           manage_users; control API `address-profiles` and MCP
#                           `list_address_profiles` are twins on this one function.
#   address-profile-set     create or replace one profile.  OPERATOR, cookie only.
#   address-profile-delete  delete one profile.             OPERATOR, cookie only.
#
# A profile has no kind (SM1343): a rule that names it allows or denies it.
#
# WHY THE WRITES ARE THE OPERATOR'S AND NOT manage_users'. An address profile decides
# who may reach a page, a group's grants and the manager, so whoever edits one can
# lock the operator out or open a door from anywhere. manage_users is user and group
# management and, since SM991, is not the operator; the operator group is the
# operator's alone, and this store is held to the same line. The group verbs'
# ceiling ("holds AND may grant") has no shape here - there is no capability a
# profile confers - so the line is who, not how much. The users tool, which owns
# the store, asks the same question again (a backstop for whoever else drives it).
#
# WHY THE WRITES ARE COOKIE-ONLY. The operator is never a token (SM991), so a
# token door would only ever refuse; the actions are declared cookie-only with that
# reason, and the read half is the part an agent can use (to see what a rule it
# writes would name).
#
# WHAT A DOMAIN-CONFINED CALLER IS SHOWN. The profiles are shared by the instance
# (SM1134 ruling 6) and their entries are the site's own network addresses; a
# caller confined to some domains (every MCP grant, every token - SM648) does not
# read the instance's network map (SM976 R1). It is shown the NAMES and the entry
# counts, which is what writing a rule that names a profile needs, and not the
# entries or their notes.
#
# %who is Lazysite::Manager::Groups's: actor, held, confined, reach, operator.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                        ();
use Lazysite::Util                  qw(log_event);
use Lazysite::Auth::Acl             ();
use Lazysite::Auth::AddressProfiles ();
use Lazysite::Manager::Common       ();

our @EXPORT_OK = qw(address_profiles address_profile_set address_profile_delete);

# address-profiles / list_address_profiles.
sub address_profiles {
    my (%who) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Address profiles are listed for a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    local $Lazysite::Auth::AddressProfiles::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $all   = Lazysite::Auth::AddressProfiles::profiles();
    my $fault = Lazysite::Auth::AddressProfiles::store_fault();
    # A store that will not read is not "no profiles" (SM1024): the answer says so,
    # and the page shows it instead of an empty table.
    return { ok => 0, kind => 'cannot-tell',
        error => Lazysite::Auth::AddressProfiles::fault_text($fault)
            . '; every rule that names an address profile refuses until it is repaired.'
            . Lazysite::Auth::AddressProfiles::fault_note($fault) }
        if $fault;
    my @rows = map {
        my $l = $all->{$_};
        +{ name => $_, entry_count => scalar @{ $l->{entries} },
            ( $who{confined}           ? () : ( entries => $l->{entries} ) ),
            ( defined $l->{updated_by} ? ( updated_by => $l->{updated_by} ) : () ),
            ( defined $l->{updated}    ? ( updated => $l->{updated} + 0 )   : () ),
            ( $l->{rejected}           ? ( rejected => $l->{rejected} )     : () ) }
    } sort keys %{$all};
    # SM1192: the server decides "every visitor is the front proxy"; the page shows it.
    my $proxy = Lazysite::Auth::AddressProfiles::front_end_warning();
    return { ok => 1, profiles => \@rows,
        ( defined $proxy ? ( proxy_warning => $proxy )           : () ),
        ( $who{confined} ? ( confined      => JSON::PP::true() ) : () ),
        # The operator changes profiles; anyone else is shown them and no controls.
        can_edit => ( $who{operator} ? JSON::PP::true() : JSON::PP::false() ),
        note => 'an entry is a single address or a CIDR range (IPv4 or IPv6) with a note. A profile '
            . 'has no kind: each rule that names one allows it (addresses) or denies it '
            . '(addresses_deny). Profiles are changed by the operator in the manager.' };
}

sub _write_refusal {
    my (%who) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Address profiles are changed by a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    return { ok => 0, kind => 'forbidden',
        error => 'Only the operator changes address profiles, in the manager: a profile decides who '
            . 'may reach a page, a group or the manager, so it is the operator\'s as the '
            . 'operator group is.' }
        unless $who{operator};
    return undef;
}

# address-profile-set: { name, entries => [ {cidr, note} ] }. The whole request is
# validated in the users tool, the store's owner, before anything is written. A
# profile has no kind (SM1343): none is passed, and the reply carries none.
sub address_profile_set {
    my ( $req, %who ) = @_;
    if ( my $no = _write_refusal(%who) ) { return $no }
    $req = {} unless ref $req eq 'HASH';
    my $r = Lazysite::Manager::Common::users_api( {
            action => 'address-profile-set',
            name   => $req->{name},
            ( exists $req->{entries} ? ( entries => $req->{entries} ) : () ),
            actor => $who{actor},
    } ) || {};
    return $r->{ok} ? $r : { ok => 0, kind => ( $r->{kind} // 'error' ),
        ( $r->{field} ? ( field => $r->{field} ) : () ),
        error => ( $r->{error} // 'no answer from user management' ) };
}

sub address_profile_delete {
    my ( $req, %who ) = @_;
    if ( my $no = _write_refusal(%who) ) { return $no }
    $req = {} unless ref $req eq 'HASH';
    my $r = Lazysite::Manager::Common::users_api( {
            action => 'address-profile-delete',
            name   => $req->{name},
            actor  => $who{actor},
    } ) || {};
    return $r->{ok} ? $r : { ok => 0, kind => ( $r->{kind} // 'error' ),
        error => ( $r->{error} // 'no answer from user management' ) };
}

1;
