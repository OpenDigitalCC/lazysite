package Lazysite::Auth::AddressProfiles;

# SM1138 (slice A of SM1134, ruled 2026-10-17), SM1343 (0.16.5, rulings 56-57):
# NAMED ADDRESS PROFILES, AND THE ONE MODULE THAT ANSWERS "IS THIS ADDRESS IN THAT
# PROFILE". The store is lazysite/auth/address-profiles.json, per instance, written
# only through the users tool (address-profile-set / address-profile-delete) and
# read here. Pages, folders, groups, the manager, sign-in and the Odoo binding apply
# a profile, and each asks THIS module, so the matching, the deny-wins rule and the
# failure behaviour are written once.
#
# A PROFILE HAS NO KIND (SM1343). Until 0.16.5 these were address LISTS, each an
# allow list or a deny list for life, so one office range allowed in one place and
# denied in another was kept twice. A profile is only a named set of addresses;
# whether it allows or denies is the choice of the rule that names it - the slot it
# is named in (`addresses` allows, `addresses_deny` denies, on a page, an access
# rule, a group, lazysite.conf's manager and sign-in keys and a session binding).
# The upgrade (install.pl, SM1345) turns each list into a profile of the same name.
#
# THE STORE
#
#   { "office":  { "entries": [ { "cidr": "203.0.113.0/24", "note": "HQ" } ],
#                  "created_by": "sjm", "updated_by": "sjm", "updated": 1760000000 },
#     "blocked": { "entries": [ { "cidr": "198.51.100.7",   "note": "scanner" } ] } }
#
# A name is [a-z0-9_-]{1,64}. An entry is a single address or a CIDR range, IPv4 or
# IPv6, with a note (which may be empty). `cidr` is stored as the canonical
# spelling of what was typed: one spelling per address, host bits NOT masked
# (10.1.2.3/8 keeps its address and matches the whole /8). A `kind` left on a
# record by a hand edit is ignored.
#
# API (kept small; the rules call only these)
#
#   profiles()                    { name => { entries => [ { cidr, note } ],
#                                   created_by, updated_by, updated, rejected => [...] } }
#                                 A fresh copy each call. {} for an absent store AND
#                                 for a faulted one - ask store_fault() which.
#   profile_names()               sorted names
#   in_profile( $address, $name ) 1 or 0. 0 for an unknown name (logged once per name
#                                 per process), an address that is not an address,
#                                 and a faulted store. Membership only.
#   decide( $address, allow => [names], deny => [names] )
#                                 ( 'allow' | 'deny', $reason ). Rules, in order:
#                                   no profile named at all       -> allow, 'no-rules'
#                                   store faulted                 -> deny,  'store-fault'
#                                   no usable address             -> deny,  'no-address'
#                                   address in a profile denied   -> deny,  'deny-profile'  (DENY WINS)
#                                   a profile allowed, address
#                                   in none of them               -> deny,  'not-allowed'
#                                   address in a profile allowed  -> allow, 'allow-profile'
#                                   only profiles denied, no match -> allow, 'not-denied'
#   client_address()              the visitor's address, from Lazysite::Util::request_address
#                                 with the instance's trusted_proxies. X-Forwarded-For is
#                                 believed only from a listed proxy, never directly.
#   store_fault()                 0, or 'unreadable' / 'undecodable' / 'unconverted'
#                                 for the LAST read
#   valid_name( $name )           1 or 0
#   check_entry( $text )          ( $canonical_cidr, '' ) or ( undef, $reason )
#   write_profiles( \%profiles )  atomic write; refuses over a faulted store (SM785/SM1024).
#                                 For the users tool; nothing else writes.
#
# Context: $Lazysite::Auth::AddressProfiles::AUTH_DIR (the auth/ directory), else
# $Lazysite::Auth::Settings::AUTH_DIR, which every script that reads the other auth
# stores already sets.
#
# FAILS CLOSED, as SM1024 ruled for groups-settings.json and acls.json. A store that
# exists and will not open, or opens and does not decode to an object, is a store
# whose contents are UNKNOWN, not an empty one. decide() then denies whenever a rule
# names a profile - allowed OR denied: "in none of them" is true of an unreadable
# profile, and "not in it" would be an unproven claim, so the broken file never
# opens a door that a working file would have shut. An ABSENT store is an answer
# (no profiles): a rule naming one is then an unknown name.
#
# UNCONVERTED (SM1345). A site whose store from before 0.16.5 (auth/address-lists.json) is still
# there with no profile store beside it has not had the upgrade's conversion: its
# rules name lists this module cannot read. That is a fault ('unconverted'), not an
# absent store, because an absent store would let every rule that denies a profile
# block nobody - the site would open to the addresses it shuts out today.
#
# UNKNOWN NAMES. A name no profile carries contributes no addresses and is logged
# once. Allowed, it still counts as "a profile is allowed", so a page that allows
# only a deleted profile refuses everybody rather than becoming public; denied, it
# blocks nobody (there is nothing to match, and denying all for a deleted profile
# would be an outage out of proportion to the typo).
#
# ADDRESS MATCHING is Lazysite::Util's (parse_trusted_proxies and its range matcher),
# the same code the trusted_proxies and auth_proxy_trusted_from settings use, so an
# address means the same in every profile. IPv4 and IPv6, same family only: an IPv4
# range never contains an IPv6 address. THE IPv4-MAPPED FORM (::ffff:203.0.113.5) IS
# AN IPv6 ADDRESS TO THIS MATCHER and is not converted: it is in no IPv4 range, as
# with trusted_proxies. A site whose front end hands the CGI mapped addresses lists
# them as ::ffff:... ranges. That fails closed where a profile is allowed (not
# matched, so refused) and open where it is denied, which is why check_entry accepts
# the mapped spelling so an operator can name it. A zero-length prefix (0.0.0.0/0,
# ::/0) is refused, as parse_trusted_proxies refuses it: "every address" is not an
# address profile, and allowing everyone is no rule.

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

# 'unreadable', 'undecodable' or 'unconverted' for the last read; 0 when it read,
# or is absent.
my $FAULT = 0;

my $NAME_RE = qr/\A[a-z0-9_-]{1,64}\z/;

sub _dir {
    return $AUTH_DIR if defined $AUTH_DIR && length $AUTH_DIR;
    return $Lazysite::Auth::Settings::AUTH_DIR;
}

sub store_path { my $d = _dir(); return defined $d ? "$d/address-profiles.json" : undef }

# SM1345: the store the upgrade converts from. Named here only to tell an
# unconverted site from one with no profiles (see UNCONVERTED above).
sub _unconverted_path { my $d = _dir(); return defined $d ? "$d/address-lists.json" : undef }

sub store_fault { return $FAULT }

# The fault as a sentence, for a refusal or a page that cannot list the profiles.
sub fault_text ($fault) {
    return 'lazysite/auth/address-lists.json (the address lists of a release before 0.16.5) has not been converted to '
        . 'address profiles: run the upgrade again, which converts it (SM1345)'
        if $fault eq 'unconverted';
    return 'lazysite/auth/address-profiles.json '
        . ( $fault eq 'undecodable' ? 'does not decode as a JSON object' : 'could not be read' );
}
# n818 (SM1440): for an unreadable store, the user this ran as and the one that
# owns it, to follow the refusal. '' for every other fault.
sub fault_note ($fault) {
    return $fault eq 'unreadable' ? Lazysite::Util::unreadable_note( store_path() ) : '';
}


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
# ({} with the flag clear) unless the unconverted store is beside it; the open
# decides, not a -f guard (SM770).
sub _read_raw ($path) {
    $FAULT = 0;
    open my $fh, '<:raw', $path or do {
        $FAULT = $!{ENOENT} ? 0 : 'unreadable';    # errno first: cannot_read clobbers $!
        cannot_read( 'address-profiles.json', $path );
        my $old = _unconverted_path();
        if ( !$FAULT && defined $old && -e $old ) {
            $FAULT = 'unconverted';
            _warn_once( 'unconverted',
                'address-lists.json has not been converted to address-profiles.json - every rule naming '
                    . 'an address profile denies until the upgrade converts it',
                file => 'lazysite/auth/address-lists.json' );
        }
        return $FAULT ? undef : {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    unless ( ref $d eq 'HASH' ) {
        $FAULT = 'undecodable';
        _warn_once( 'undecodable',
            'address-profiles.json does not decode as a JSON object - every rule naming '
                . 'an address profile denies until it is repaired',
            file => 'lazysite/auth/address-profiles.json' );
        return undef;
    }
    return $d;
}

# THE STORE EXACTLY AS WRITTEN, uncached, for the one writer: it changes one
# profile and must hand every other record back untouched (a hand-edited entry
# that profiles() skips is still there to be repaired). {} when absent; undef and
# store_fault() set when it faulted.
sub raw_profiles () {
    my $path = store_path();
    return undef unless defined $path;
    return _read_raw($path);
}

{
    # Decoded once per change: keyed on (path, mtime, size) with the one-second
    # guard Auth::Acl uses (a file younger than a second is read fresh, since a
    # same-second same-length rewrite carries the same key). write_profiles clears it.
    my ( $cache_key, $cache_profiles, $cache_sets ) = ( '', undef, undef );
    my %WARNED;

    sub _clear_cache { ( $cache_key, $cache_profiles, $cache_sets ) = ( '', undef, undef ); return }

    sub _warn_once ( $what, $msg, %f ) {
        return if $WARNED{$what}++;
        log_event( 'WARN', 'address-profiles', $msg, %f );
        return;
    }

    # ( \%profiles, \%sets ): the decoded map and, per name, the parsed ranges.
    sub _load {
        my $path = store_path();
        $FAULT = 0;
        return ( {}, {} ) unless defined $path;
        my @st  = stat $path;
        my $key = @st ? "$path:$st[9]:$st[7]" : '';
        if ( length $key && $key eq $cache_key && $cache_profiles ) {
            $FAULT = 0;
            return ( $cache_profiles, $cache_sets );
        }
        my $d = _read_raw($path);
        return ( {}, {} ) unless $d;
        my ( %profiles, %sets );
        for my $name ( keys %{$d} ) {
            my $rec = $d->{$name};
            next unless valid_name($name) && ref $rec eq 'HASH';
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
                        "address profile '$name' has an entry that is not an address or range; it matches nothing",
                        entry => ( $text // '' ) );
                }
            }
            $profiles{$name} = {
                entries => \@entries,
                ( map { $_ => $rec->{$_} } grep { defined $rec->{$_} && !ref $rec->{$_} } qw(
                        created_by
                        updated_by
                        updated ) ),
                ( @rejected ? ( rejected => \@rejected ) : () ),
            };
            $sets{$name} = \@set;
        }
        if ( length $key && @st && $st[9] < time() - 1 ) {
            ( $cache_key, $cache_profiles, $cache_sets ) = ( $key, \%profiles, \%sets );
        }
        return ( \%profiles, \%sets );
    }

    sub _warn_unknown ( $name, $why ) {
        _warn_once( "unknown:$name:$why", "address profile '$name' $why; it matches no address", profile => $name );
    }
}

sub _copy ($profiles) {
    return {
        map {
            my $r = $profiles->{$_};
            $_ => {
                %{$r},
                entries => [ map { { %$_ } } @{ $r->{entries} } ],
                ( $r->{rejected} ? ( rejected => [ @{ $r->{rejected} } ] ) : () ),
            }
        } keys %{$profiles}
    };
}

sub profiles () { my ($p) = _load(); return _copy($p) }

sub profile_names () { my ($p) = _load(); my @n = sort keys %{$p}; return @n }

# The address as the matcher sees it: ( packed bytes ) or ''.
sub _packed ($address) {
    return '' unless defined $address && !ref $address;
    ( my $a = $address ) =~ s/\A\s+|\s+\z//g;
    return Lazysite::Util::_packed_address($a); ## no critic (Subroutines::ProtectPrivateSubs)
}

sub _in_set ( $packed, $set ) {
    return Lazysite::Util::_address_in_set( $packed, $set ) ? 1 : 0; ## no critic (Subroutines::ProtectPrivateSubs)
}

sub in_profile ( $address, $name ) {
    my ( $profiles, $sets ) = _load();
    return 0 if $FAULT;
    unless ( defined $name && exists $profiles->{$name} ) {
        _warn_unknown( $name // '', 'is not in the store' );
        return 0;
    }
    my $p = _packed($address);
    return 0 unless length $p;
    return _in_set( $p, $sets->{$name} );
}

# SM1343: the slot a rule names a profile in is the whole of its meaning - `allow`
# admits only the addresses of the profiles it names, `deny` refuses theirs - so a
# profile is never "of the wrong kind" for a slot, and the SM1189 refusal of one
# went with the kind.
sub decide ( $address, %o ) {
    my @allow = grep { defined } @{ $o{allow} || [] };
    my @deny  = grep { defined } @{ $o{deny}  || [] };
    return ( 'allow', 'no-rules' ) unless @allow || @deny;
    my ( $profiles, $sets ) = _load();
    return ( 'deny', 'store-fault' ) if $FAULT;
    my $p = _packed($address);
    return ( 'deny', 'no-address' ) unless length $p;

    for my $name (@deny) {
        unless ( $profiles->{$name} ) { _warn_unknown( $name, 'is named by a rule and is not in the store' ); next }
        return ( 'deny', 'deny-profile' ) if _in_set( $p, $sets->{$name} );
    }
    if (@allow) {
        for my $name (@allow) {
            unless ( $profiles->{$name} ) { _warn_unknown( $name, 'is named by a rule and is not in the store' ); next }
            return ( 'allow', 'allow-profile' ) if _in_set( $p, $sets->{$name} );
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
# map, and a faulted read answered {}, so the write would erase every other
# profile. An unconverted site is refused too: a first profile written there would
# leave the lists its rules name unread.
sub write_profiles ($ref) {
    my $path = store_path();
    die "no auth directory is set\n" unless defined $path;
    # Read first so the fault flag is this store's, not a stale one.
    _read_raw($path);
    die 'Refusing to write the address profiles: ' . fault_text($FAULT)
        . ( $FAULT eq 'unconverted' ? ".\n"
        : ", so this write would replace every other profile with the one being changed. Repair the file and retry.\n" )
        if $FAULT;
    my $json = JSON::PP->new->canonical->pretty->encode($ref);
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:utf8', $tmp or die "cannot write $tmp: $!\n";
    flock( $fh, LOCK_EX );
    print {$fh} $json;
    flock( $fh, LOCK_UN );
    close $fh;
    secure_write_perms( $tmp, 0660 );
    rename( $tmp, $path ) or die "cannot replace address-profiles.json: $!\n";
    _clear_cache();
    return 1;
}

1;

__END__

=head1 NAME

Lazysite::Auth::AddressProfiles - the named address profiles (lazysite/auth/address-profiles.json) and the one reader of them

=head1 SYNOPSIS

    use Lazysite::Auth::AddressProfiles ();
    local $Lazysite::Auth::AddressProfiles::AUTH_DIR = "$lazysite_dir/auth";  # or Auth::Settings' AUTH_DIR

    my $addr = Lazysite::Auth::AddressProfiles::client_address();
    if ( Lazysite::Auth::AddressProfiles::in_profile( $addr, 'office' ) ) { ... }

    my ( $verdict, $reason ) = Lazysite::Auth::AddressProfiles::decide(
        $addr, allow => ['office'], deny => ['blocked'] );

=head1 DESCRIPTION

SM1138, slice A of SM1134; SM1343 made the lists profiles. A profile has a name
(C<[a-z0-9_-]{1,64}>) and entries: a single address or a CIDR range, IPv4 or
IPv6, each with a note. It has no kind: a rule that names it allows or denies it
by the slot it names it in. The store is written only by the users tool
(C<address-profile-set>, C<address-profile-delete>) and only for the operator.
This module enforces nothing by itself; the rules that apply a profile to a page,
a folder, a group or the manager call it and nothing else.

=head1 FUNCTIONS

=over 4

=item profiles()

Hashref C<< name => { entries => [ { cidr, note } ], rejected, ... } >>.
A fresh copy each call. A record also says who made it, who last changed it and
when. C<rejected> names stored entries that are not addresses (they match
nothing). Empty for an absent store and for a faulted one; ask
C<store_fault()> which.

=item profile_names()

The names, sorted.

=item in_profile( $address, $name )

1 or 0. 0 for an unknown name (logged once per name per process), for something
that is not an address, and for a faulted store. It answers membership only.

=item decide( $address, allow =E<gt> [names], deny =E<gt> [names] )

Returns C<( 'allow' | 'deny', $reason )>. In order: nothing named is
C<allow, no-rules>; a faulted store is C<deny, store-fault>; no usable address
is C<deny, no-address>; in a profile denied is C<deny, deny-profile> (DENY WINS,
even over a profile allowed that also matches); a profile allowed and the
address in none of them is C<deny, not-allowed>; in a profile allowed is
C<allow, allow-profile>; only profiles denied and no match is
C<allow, not-denied>.

An unknown name contributes no addresses and is logged once. Allowed, it still
counts as "a profile is allowed", so a rule allowing only a deleted profile
admits nobody; denied, it blocks nobody.

=item client_address()

The visitor's address, from C<Lazysite::Util::request_address> with the
instance's C<trusted_proxies>. C<X-Forwarded-For> is believed only from a listed
proxy (rightmost untrusted hop), never directly.

=item store_fault(), fault_text( $fault )

0, or C<unreadable>, C<undecodable> or C<unconverted> for the last read;
C<fault_text> says one as a sentence.

=item valid_name( $name ), check_entry( $text )

C<check_entry> returns C<( $canonical, '' )> or C<( undef, $reason )>. An entry
is one address or one CIDR; a prefix of 0 (C<0.0.0.0/0>, C<::/0>), a word list,
C<none>, an empty string and a prefix longer than the address are refused.
C</32> and C</128> are stored as the bare address.

=item raw_profiles(), write_profiles( \%profiles )

For the users tool: the store as written (uncached), and an atomic write
(temp, lock, rename; 0660 owned as the directory). C<write_profiles> dies rather
than write over a store whose last read faulted.

=back

=head1 FAILURE BEHAVIOUR

Fails closed (SM1024). A store that exists and will not open, or opens and does
not decode to a JSON object, is unknown and not empty: C<decide> denies whenever
a rule names a profile, allowed or denied. So does a site whose address-lists.json from
before 0.16.5 was never converted (C<unconverted>, SM1345). An absent store is an
answer (no profiles).

=head1 ADDRESS MATCHING

C<Lazysite::Util>'s matcher, as C<trusted_proxies> uses it: same family only,
and the IPv4-mapped form (C<::ffff:203.0.113.5>) is an IPv6 address that no IPv4
range contains. List mapped ranges as IPv6 entries (C<::ffff:203.0.113.0/120>)
if the front end hands them over.

=cut
