package Lazysite::Manager::AddressLists;

# SM1138 (slice A of SM1134): the manager's and the remote doors' view of the
# address-list store.
#
#   address-lists        read-only: every list, its kind, entries and notes.
#                        manage_users; control API `address-lists` and MCP
#                        `list_address_lists` are twins on this one function.
#   address-list-set     create or replace one list.        OPERATOR, cookie only.
#   address-list-delete  delete one list.                   OPERATOR, cookie only.
#
# WHY THE WRITES ARE THE OPERATOR'S AND NOT manage_users'. An address list decides
# who may reach a page, a group's grants and (slice D) the manager, so whoever
# edits one can lock the operator out or open a door from anywhere. manage_users
# is user and group management and, since SM991, is not the operator; the operator
# group is the operator's alone, and this store is held to the same line. The
# group verbs' ceiling ("holds AND may grant") has no shape here - there is no
# capability a list confers - so the line is who, not how much. The users tool,
# which owns the store, asks the same question again (a backstop for whoever else
# drives it).
#
# WHY THE WRITES ARE COOKIE-ONLY. The operator is never a token (SM991), so a
# token door would only ever refuse; the actions are declared cookie-only with that
# reason, and the read half is the part an agent can use (to see what a rule it
# writes would name).
#
# WHAT A DOMAIN-CONFINED CALLER IS SHOWN. The lists are shared by the instance
# (SM1134 ruling 6) and their entries are the site's own network addresses; a
# caller confined to some domains (every MCP grant, every token - SM648) does not
# read the instance's network map (SM976 R1). It is shown the NAMES, the kinds and
# the entry counts, which is what writing a rule that names a list needs, and
# not the entries or their notes.
#
# %who is Lazysite::Manager::Groups's: actor, held, confined, reach, operator.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                     ();
use Lazysite::Util               qw(log_event);
use Lazysite::Auth::Acl          ();
use Lazysite::Auth::AddressLists ();
use Lazysite::Manager::Common    ();

our @EXPORT_OK = qw(address_lists address_list_set address_list_delete);

# address-lists / list_address_lists.
sub address_lists {
    my (%who) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Address lists are listed for a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    local $Lazysite::Auth::AddressLists::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $all   = Lazysite::Auth::AddressLists::lists();
    my $fault = Lazysite::Auth::AddressLists::store_fault();
    # A store that will not read is not "no lists" (SM1024): the answer says so,
    # and the page shows it instead of an empty table.
    return { ok => 0, kind => 'cannot-tell',
        error => 'lazysite/auth/address-lists.json '
            . ( $fault eq 'undecodable' ? 'does not decode as a JSON object' : 'could not be read' )
            . '; every rule that names an address list refuses until it is repaired.' }
        if $fault;
    my @rows = map {
        my $l = $all->{$_};
        +{ name => $_, kind => $l->{kind}, entry_count => scalar @{ $l->{entries} },
            ( $who{confined}           ? () : ( entries => $l->{entries} ) ),
            ( defined $l->{updated_by} ? ( updated_by => $l->{updated_by} ) : () ),
            ( defined $l->{updated}    ? ( updated => $l->{updated} + 0 )   : () ),
            ( $l->{rejected}           ? ( rejected => $l->{rejected} )     : () ) }
    } sort keys %{$all};
    # SM1192: the server decides "every visitor is the front proxy"; the page shows it.
    my $proxy = Lazysite::Auth::AddressLists::front_end_warning();
    return { ok => 1, lists => \@rows,
        ( defined $proxy ? ( proxy_warning => $proxy )           : () ),
        ( $who{confined} ? ( confined      => JSON::PP::true() ) : () ),
        # The operator changes lists; anyone else is shown them and no controls.
        can_edit => ( $who{operator} ? JSON::PP::true() : JSON::PP::false() ),
        note => 'kind is allow or deny; an entry is a single address or a CIDR range (IPv4 or '
            . 'IPv6) with a note. Lists are changed by the operator in the manager.' };
}

sub _write_refusal {
    my (%who) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Address lists are changed by a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    return { ok => 0, kind => 'forbidden',
        error => 'Only the operator changes address lists, in the manager: a list decides who '
            . 'may reach a page, a group or the manager, so it is the operator\'s as the '
            . 'operator group is.' }
        unless $who{operator};
    return undef;
}

# address-list-set: { name, kind, entries => [ {cidr, note} ] }. The whole request
# is validated in the users tool, the store's owner, before anything is written.
sub address_list_set {
    my ( $req, %who ) = @_;
    if ( my $no = _write_refusal(%who) ) { return $no }
    $req = {} unless ref $req eq 'HASH';
    my $r = Lazysite::Manager::Common::users_api( {
            action => 'address-list-set',
            name   => $req->{name},
            kind   => $req->{kind},
            ( exists $req->{entries} ? ( entries => $req->{entries} ) : () ),
            actor => $who{actor},
    } ) || {};
    return $r->{ok} ? $r : { ok => 0, kind => ( $r->{kind} // 'error' ),
        ( $r->{field} ? ( field => $r->{field} ) : () ),
        error => ( $r->{error} // 'no answer from user management' ) };
}

sub address_list_delete {
    my ( $req, %who ) = @_;
    if ( my $no = _write_refusal(%who) ) { return $no }
    $req = {} unless ref $req eq 'HASH';
    my $r = Lazysite::Manager::Common::users_api( {
            action => 'address-list-delete',
            name   => $req->{name},
           # SM1141: force is the operator's (the write is already refused to anyone else)
            force => ( $req->{force} ? 1 : 0 ),
            actor => $who{actor},
    } ) || {};
    return $r->{ok} ? $r : { ok => 0, kind => ( $r->{kind} // 'error' ),
        error => ( $r->{error} // 'no answer from user management' ) };
}

1;
