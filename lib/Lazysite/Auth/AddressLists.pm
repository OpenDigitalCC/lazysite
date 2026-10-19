package Lazysite::Auth::AddressLists;

# SM1138 (slice A of SM1134, ruled 2026-10-17): NAMED ADDRESS LISTS, AND THE ONE
# MODULE THAT ANSWERS "IS THIS ADDRESS IN THAT LIST". The store is
# lazysite/auth/address-lists.json, per instance, written only through the users
# tool (address-list-set / address-list-delete) and read here. This slice enforces
# nothing: pages, folders, groups and the manager apply a list in slices B, C and D,
# and each asks THIS module, so the matching, the deny-wins rule and the failure
# behaviour are written once.
#
# THE STORE
#
#   { "office":  { "kind": "allow", "entries": [ { "cidr": "203.0.113.0/24", "note": "HQ" } ],
#                  "created_by": "sjm", "updated_by": "sjm", "updated": 1760000000 },
#     "blocked": { "kind": "deny",  "entries": [ { "cidr": "198.51.100.7",   "note": "scanner" } ] } }
#
# A name is [a-z0-9_-]{1,64}. `kind` is allow or deny. An entry is a single address
# or a CIDR range, IPv4 or IPv6, with a note (which may be empty). `cidr` is stored
# as the canonical spelling of what was typed: one spelling per address, host bits
# NOT masked (10.1.2.3/8 keeps its address and matches the whole /8).
#
# API (kept small; slices B-D call only these)
#
#   lists()                       { name => { kind, entries => [ { cidr, note } ],
#                                   created_by, updated_by, updated, rejected => [...] } }
#                                 A fresh copy each call. {} for an absent store AND
#                                 for a faulted one - ask store_fault() which.
#   list_names()                  sorted names
#   in_list( $address, $name )    1 or 0. 0 for an unknown name (logged once per name
#                                 per process), an address that is not an address,
#                                 and a faulted store. Membership only: it does not
#                                 care whether the list is allow or deny.
#   decide( $address, allow => [names], deny => [names] )
#                                 ( 'allow' | 'deny', $reason ). Rules, in order:
#                                   no list named at all          -> allow, 'no-rules'
#                                   store unreadable/undecodable  -> deny,  'store-fault'
#                                   no usable address             -> deny,  'no-address'
#                                   address in any deny list      -> deny,  'deny-list'  (DENY WINS)
#                                   an allow list named, address
#                                   in none of them               -> deny,  'not-allowed'
#                                   address in an allow list      -> allow, 'allow-list'
#                                   only deny lists, no match     -> allow, 'not-denied'
#   client_address()              the visitor's address, from Lazysite::Util::request_address
#                                 with the instance's trusted_proxies. X-Forwarded-For is
#                                 believed only from a listed proxy, never directly.
#   store_fault()                 0, or 'unreadable' / 'undecodable' for the LAST read
#   valid_name( $name )           1 or 0
#   check_entry( $text )          ( $canonical_cidr, '' ) or ( undef, $reason )
#   write_lists( \%lists )        atomic write; refuses over a faulted store (SM785/SM1024).
#                                 For the users tool; nothing else writes.
#
# Context: $Lazysite::Auth::AddressLists::AUTH_DIR (the auth/ directory), else
# $Lazysite::Auth::Settings::AUTH_DIR, which every script that reads the other auth
# stores already sets.
#
# FAILS CLOSED, as SM1024 ruled for groups-settings.json and acls.json. A store that
# exists and will not open, or opens and does not decode to an object, is a store
# whose contents are UNKNOWN, not an empty one. decide() then denies whenever a rule
# names a list - allow OR deny: with an allow list "in none of them" is true of an
# unreadable list, and with a deny list "not in it" would be an unproven claim, so
# the broken file never opens a door that a working file would have shut. An ABSENT
# store is an answer (no lists): a rule naming a list is then an unknown name.
#
# UNKNOWN NAMES. A name no list carries contributes no addresses and is logged once.
# In `allow` it still counts as "an allow list is present", so a page that names only
# a deleted allow list refuses everybody rather than becoming public; in `deny` it
# blocks nobody (there is nothing to match, and denying all for a deleted deny list
# would be an outage out of proportion to the typo). A list named in the wrong slot -
# a deny-kind list under `allow`, or an allow-kind list under `deny` - is a
# configuration error handled the same way: logged once, contributes no addresses.
#
# ADDRESS MATCHING is Lazysite::Util's (parse_trusted_proxies and its range matcher),
# the same code the trusted_proxies and auth_proxy_trusted_from settings use, so an
# address means the same in every list. IPv4 and IPv6, same family only: an IPv4
# range never contains an IPv6 address. THE IPv4-MAPPED FORM (::ffff:203.0.113.5) IS
# AN IPv6 ADDRESS TO THIS MATCHER and is not converted: it is in no IPv4 range, as
# with trusted_proxies. A site whose front end hands the CGI mapped addresses lists
# them as ::ffff:... ranges. That fails closed for an allow list (not matched, so
# refused) and open for a deny list, which is why check_entry accepts the mapped
# spelling so an operator can name it. A zero-length prefix (0.0.0.0/0, ::/0) is
# refused, as parse_trusted_proxies refuses it: "every address" is not an address
# list, and an allow-everyone list is no rule.

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use Fcntl                    qw(:flock);
use Lazysite::Auth::Settings ();           # the AUTH_DIR the other stores are read from
use JSON::PP                 ();
use Lazysite::Util qw(log_event secure_write_perms cannot_read parse_trusted_proxies
    request_address trusted_proxy_spec front_end_is_every_visitor);

our $AUTH_DIR;    # set by the script; falls back to Auth::Settings::AUTH_DIR

# 'unreadable' or 'undecodable' for the last read; 0 when it read, or is absent.
my $FAULT = 0;

my $NAME_RE = qr/\A[a-z0-9_-]{1,64}\z/;

sub _dir {
    return $AUTH_DIR if defined $AUTH_DIR && length $AUTH_DIR;
    return $Lazysite::Auth::Settings::AUTH_DIR;
}

sub store_path { my $d = _dir(); return defined $d ? "$d/address-lists.json" : undef }

sub store_fault { return $FAULT }

sub valid_name ($name) { return ( defined $name && !ref $name && $name =~ $NAME_RE ) ? 1 : 0 }

# ( canonical, '' ) for one entry, or ( undef, why ). One address or one CIDR, and
# nothing else: parse_trusted_proxies would split a word list and read an empty
# string as its RFC1918 default and `none` as an empty set, so the shape is checked
# first and the parsed result must be exactly one range.
sub check_entry ($text) {
    return ( undef, 'an entry is required' ) unless defined $text && !ref $text;
    ( my $t = $text ) =~ s/\A\s+|\s+\z//g;
    return ( undef, 'an entry is required' ) unless length $t;
    return ( undef, "'$t' is not an address or a CIDR range" )
        unless $t =~ m{\A[0-9A-Fa-f:.]+(?:/[0-9]{1,3})?\z};
    my ( $set, $bad ) = parse_trusted_proxies($t);
    return ( undef,
        "'$t' is not an address or a CIDR range (a prefix of 0 is refused, and so is one longer than the address)" )
        if @{$bad} || @{$set} != 1;
    my ( $packed, $bits ) = @{ $set->[0] };
    my $addr = Lazysite::Util::_text_address($packed); ## no critic (Subroutines::ProtectPrivateSubs)
    return ( undef, "'$t' is not an address or a CIDR range" ) unless length $addr;
    my $single = $bits == length($packed) * 8;
    return ( $single ? $addr : "$addr/$bits", '' );
}

# The store as decoded, or undef after setting $FAULT. An absent file is an answer
# ({} with the flag clear); the open decides, not a -f guard (SM770).
sub _read_raw ($path) {
    $FAULT = 0;
    open my $fh, '<:raw', $path or do {
        $FAULT = $!{ENOENT} ? 0 : 'unreadable';    # errno first: cannot_read clobbers $!
        cannot_read( 'address-lists.json', $path );
        return $FAULT ? undef : {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    unless ( ref $d eq 'HASH' ) {
        $FAULT = 'undecodable';
        _warn_once( 'undecodable',
            'address-lists.json does not decode as a JSON object - every rule naming '
                . 'an address list denies until it is repaired',
            file => 'lazysite/auth/address-lists.json' );
        return undef;
    }
    return $d;
}

# THE STORE EXACTLY AS WRITTEN, uncached, for the one writer: it changes one list
# and must hand every other record back untouched (a hand-edited entry that
# lists() skips is still there to be repaired). {} when absent; undef and
# store_fault() set when it faulted.
sub raw_lists () {
    my $path = store_path();
    return undef unless defined $path;
    return _read_raw($path);
}

{
    # Decoded once per change: keyed on (path, mtime, size) with the one-second
    # guard Auth::Acl uses (a file younger than a second is read fresh, since a
    # same-second same-length rewrite carries the same key). write_lists clears it.
    my ( $cache_key, $cache_lists, $cache_sets ) = ( '', undef, undef );
    my %WARNED;

    sub _clear_cache { ( $cache_key, $cache_lists, $cache_sets ) = ( '', undef, undef ); return }

    sub _warn_once ( $what, $msg, %f ) {
        return if $WARNED{$what}++;
        log_event( 'WARN', 'address-lists', $msg, %f );
        return;
    }

    # ( \%lists, \%sets ): the decoded map and, per name, the parsed ranges.
    sub _load {
        my $path = store_path();
        $FAULT = 0;
        return ( {}, {} ) unless defined $path;
        my @st  = stat $path;
        my $key = @st ? "$path:$st[9]:$st[7]" : '';
        if ( length $key && $key eq $cache_key && $cache_lists ) {
            $FAULT = 0;
            return ( $cache_lists, $cache_sets );
        }
        my $d = _read_raw($path);
        return ( {}, {} ) unless $d;
        my ( %lists, %sets );
        for my $name ( keys %{$d} ) {
            my $rec = $d->{$name};
            next unless valid_name($name) && ref $rec eq 'HASH';
            my $kind = ( $rec->{kind} // '' );
            $kind = '' unless $kind eq 'allow' || $kind eq 'deny';
            my ( @entries, @set, @rejected );
            for my $e ( ref $rec->{entries} eq 'ARRAY' ? @{ $rec->{entries} } : () ) {
                my $text = ref $e eq 'HASH' ? $e->{cidr} : $e;
                my ( $canon, $why ) = check_entry($text);
                if ( defined $canon ) {
                    my ($s) = parse_trusted_proxies($canon);
                    push @set, $s->[0];
                    push @entries, { cidr => $canon, note => ( ref $e eq 'HASH' && defined $e->{note} ? "$e->{note}" : '' ) };
                }
                else {
                    push @rejected, defined $text ? "$text" : '';
                    _warn_once( "bad:$name:" . ( $text // '' ),
                        "address list '$name' has an entry that is not an address or range; it matches nothing",
                        entry => ( $text // '' ) );
                }
            }
            # A list with no kind (hand-edited) is not usable in either role.
            _warn_once( "kind:$name", "address list '$name' has no kind (allow or deny); it is ignored",
                list => $name )
                unless length $kind;
            $lists{$name} = {
                kind    => $kind,
                entries => \@entries,
                ( map { $_ => $rec->{$_} } grep { defined $rec->{$_} && !ref $rec->{$_} } qw(
                        created_by
                        updated_by
                        updated ) ),
                ( @rejected ? ( rejected => \@rejected ) : () ),
            };
            $sets{$name} = length $kind ? \@set : [];
        }
        if ( length $key && @st && $st[9] < time() - 1 ) {
            ( $cache_key, $cache_lists, $cache_sets ) = ( $key, \%lists, \%sets );
        }
        return ( \%lists, \%sets );
    }

    sub _warn_unknown ( $name, $why ) {
        _warn_once( "unknown:$name:$why", "address list '$name' $why; it matches no address", list => $name );
    }
}

sub _copy ($lists) {
    return {
        map {
            my $r = $lists->{$_};
            $_ => {
                %{$r},
                entries => [ map { { %$_ } } @{ $r->{entries} } ],
                ( $r->{rejected} ? ( rejected => [ @{ $r->{rejected} } ] ) : () ),
            }
        } keys %{$lists}
    };
}

sub lists () { my ($l) = _load(); return _copy($l) }

sub list_names () { my ($l) = _load(); my @n = sort keys %{$l}; return @n }

# The address as the matcher sees it: ( packed bytes ) or ''.
sub _packed ($address) {
    return '' unless defined $address && !ref $address;
    ( my $a = $address ) =~ s/\A\s+|\s+\z//g;
    return Lazysite::Util::_packed_address($a); ## no critic (Subroutines::ProtectPrivateSubs)
}

sub _in_set ( $packed, $set ) {
    return Lazysite::Util::_address_in_set( $packed, $set ) ? 1 : 0; ## no critic (Subroutines::ProtectPrivateSubs)
}

sub in_list ( $address, $name ) {
    my ( $lists, $sets ) = _load();
    return 0 if $FAULT;
    unless ( defined $name && exists $lists->{$name} ) {
        _warn_unknown( $name // '', 'is not in the store' );
        return 0;
    }
    my $p = _packed($address);
    return 0 unless length $p;
    return _in_set( $p, $sets->{$name} );
}

sub decide ( $address, %o ) {
    my @allow = grep { defined } @{ $o{allow} || [] };
    my @deny  = grep { defined } @{ $o{deny}  || [] };
    return ( 'allow', 'no-rules' ) unless @allow || @deny;
    my ( $lists, $sets ) = _load();
    return ( 'deny', 'store-fault' ) if $FAULT;
    my $p = _packed($address);
    return ( 'deny', 'no-address' ) unless length $p;

    for my $name (@deny) {
        my $l = $lists->{$name};
        unless ($l) { _warn_unknown( $name, 'is named by a rule and is not in the store' ); next }
        if ( $l->{kind} ne 'deny' ) { _warn_unknown( $name, 'is named as a deny list and is not one' ); next }
        return ( 'deny', 'deny-list' ) if _in_set( $p, $sets->{$name} );
    }
    if (@allow) {
        for my $name (@allow) {
            my $l = $lists->{$name};
            unless ($l) { _warn_unknown( $name, 'is named by a rule and is not in the store' ); next }
            if ( $l->{kind} ne 'allow' ) { _warn_unknown( $name, 'is named as an allow list and is not one' ); next }
            return ( 'allow', 'allow-list' ) if _in_set( $p, $sets->{$name} );
        }
        return ( 'deny', 'not-allowed' );
    }
    return ( 'allow', 'not-denied' );
}

sub client_address () {
    my $d = _dir();
    ( my $lz = defined $d              ? $d                      : '' ) =~ s{/auth/?\z}{};
    return request_address( length $lz ? trusted_proxy_spec($lz) : undef );
}

# SM1192: the manager's plain warning for the pages where address rules are edited,
# or undef. Decided here, beside client_address, from the same trusted_proxies spec,
# so a page only shows it.
sub front_end_warning () {
    my $d = _dir();
    ( my $lz = defined $d ? $d : '' ) =~ s{/auth/?\z}{};
    my ( $peer, $cause, $set ) = front_end_is_every_visitor( length $lz ? trusted_proxy_spec($lz) : undef );
    return undef unless defined $peer;
    return "Every visitor reaches this site from $peer, which is not named in trusted_proxies ($set), "
        . 'so an address rule here applies to every visitor at once. Name the front proxy in trusted_proxies '
        . "once its vhost appends the visitor's address to X-Forwarded-For (lazysite templates since 0.15.2, SM929); "
        . 'while it is older keep trusted_proxies: none, because an older front end passes a visitor\'s own '
        . 'X-Forwarded-For through and trusting it lets any visitor choose their address (SM1194).'
        if $cause eq 'untrusted';
    # SM1194: (b) is how an older front end looks with no header sent, and the same
    # front end passes a sent one through, so the interim fix is `none`, never
    # removing the line (absent is the private-range default, which trusts it).
    return "Every visitor reaches this site from $peer, a trusted proxy, but no visitor address arrives in "
        . 'X-Forwarded-For, so an address rule here applies to every visitor at once. The front end does not '
        . "send the visitor's address in X-Forwarded-For: rebuild its vhost (lazysite templates since 0.15.2, SM929). "
        . 'Until it is rebuilt set trusted_proxies: none (removing the line restores the default trust): an older '
        . "front end passes a visitor's own X-Forwarded-For through, so any visitor can choose their address (SM1194).";
}

# THE ONLY WRITER. Atomic (temp, lock, rename) like the other auth JSON stores, at
# 0660 owned by the directory's owner (SM289, SM428). It refuses to write over a
# store whose last read faulted: every caller is a read-modify-write of the whole
# map, and a faulted read answered {}, so the write would erase every other list.
sub write_lists ($ref) {
    my $path = store_path();
    die "no auth directory is set\n" unless defined $path;
    # Read first so the fault flag is this store's, not a stale one.
    _read_raw($path);
    die "Refusing to overwrite lazysite/auth/address-lists.json: it "
        . ( $FAULT eq 'undecodable' ? 'does not decode as a JSON object' : 'could not be read' )
        . ", so this write would replace every other list with the one being changed. "
        . "Repair the file and retry.\n"
        if $FAULT;
    my $json = JSON::PP->new->canonical->pretty->encode($ref);
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:utf8', $tmp or die "cannot write $tmp: $!\n";
    flock( $fh, LOCK_EX );
    print {$fh} $json;
    flock( $fh, LOCK_UN );
    close $fh;
    secure_write_perms( $tmp, 0660 );
    rename( $tmp, $path ) or die "cannot replace address-lists.json: $!\n";
    _clear_cache();
    return 1;
}

1;

__END__

=head1 NAME

Lazysite::Auth::AddressLists - the named address lists (lazysite/auth/address-lists.json) and the one reader of them

=head1 SYNOPSIS

    use Lazysite::Auth::AddressLists ();
    local $Lazysite::Auth::AddressLists::AUTH_DIR = "$lazysite_dir/auth";  # or Auth::Settings' AUTH_DIR

    my $addr = Lazysite::Auth::AddressLists::client_address();
    if ( Lazysite::Auth::AddressLists::in_list( $addr, 'office' ) ) { ... }

    my ( $verdict, $reason ) = Lazysite::Auth::AddressLists::decide(
        $addr, allow => ['office'], deny => ['blocked'] );

=head1 DESCRIPTION

SM1138, slice A of SM1134. A list has a name (C<[a-z0-9_-]{1,64}>), a kind
(C<allow> or C<deny>) and entries: a single address or a CIDR range, IPv4 or
IPv6, each with a note. The store is written only by the users tool
(C<address-list-set>, C<address-list-delete>) and only for the operator. This
module enforces nothing by itself; the slices that apply a list to a page, a
folder, a group or the manager call it and nothing else.

=head1 FUNCTIONS

=over 4

=item lists()

Hashref C<< name => { kind, entries => [ { cidr, note } ], rejected, ... } >>.
A fresh copy each call. A record also says who made it, who last changed it and when. C<rejected> names stored entries that are not addresses
(they match nothing). Empty for an absent store and for a faulted one; ask
C<store_fault()> which.

=item list_names()

The names, sorted.

=item in_list( $address, $name )

1 or 0. 0 for an unknown name (logged once per name per process), for something
that is not an address, and for a faulted store. It answers membership only and
does not care whether the list is allow or deny.

=item decide( $address, allow =E<gt> [names], deny =E<gt> [names] )

Returns C<( 'allow' | 'deny', $reason )>. In order: nothing named is
C<allow, no-rules>; a faulted store is C<deny, store-fault>; no usable address
is C<deny, no-address>; in a deny list is C<deny, deny-list> (DENY WINS, even
over an allow list that also matches); an allow list named and the address in
none of them is C<deny, not-allowed>; in an allow list is C<allow, allow-list>;
only deny lists named and no match is C<allow, not-denied>.

An unknown name, and a list named in the wrong slot (a deny-kind list under
C<allow>), contribute no addresses and are logged once. Under C<allow> they still
count as "an allow list is present", so a rule naming only a deleted allow list
admits nobody; under C<deny> they block nobody.

=item client_address()

The visitor's address, from C<Lazysite::Util::request_address> with the
instance's C<trusted_proxies>. C<X-Forwarded-For> is believed only from a listed
proxy (rightmost untrusted hop), never directly.

=item store_fault()

0, or C<unreadable> or C<undecodable> for the last read.

=item valid_name( $name ), check_entry( $text )

C<check_entry> returns C<( $canonical, '' )> or C<( undef, $reason )>. An entry
is one address or one CIDR; a prefix of 0 (C<0.0.0.0/0>, C<::/0>), a word list,
C<none>, an empty string and a prefix longer than the address are refused.
C</32> and C</128> are stored as the bare address.

=item raw_lists(), write_lists( \%lists )

For the users tool: the store as written (uncached), and an atomic write
(temp, lock, rename; 0660 owned as the directory). C<write_lists> dies rather
than write over a store whose last read faulted.

=back

=head1 FAILURE BEHAVIOUR

Fails closed (SM1024). A store that exists and will not open, or opens and does
not decode to a JSON object, is unknown and not empty: C<decide> denies whenever
a rule names a list, allow or deny. An absent store is an answer (no lists).

=head1 ADDRESS MATCHING

C<Lazysite::Util>'s matcher, as C<trusted_proxies> uses it: same family only,
and the IPv4-mapped form (C<::ffff:203.0.113.5>) is an IPv6 address that no IPv4
range contains. List mapped ranges as IPv6 entries (C<::ffff:203.0.113.0/120>)
if the front end hands them over.

=cut
