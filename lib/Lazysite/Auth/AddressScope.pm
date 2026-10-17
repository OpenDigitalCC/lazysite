package Lazysite::Auth::AddressScope;

# SM1140 (slice C of SM1134, ruled 2026-10-17): WHERE THE VISITOR'S ADDRESS LIMITS A
# GROUP, AND THE MANAGER. Slice A (Lazysite::Auth::AddressLists) answers "is this
# address allowed by these lists"; this module asks it for the two rules that are
# about a REQUEST rather than a page:
#
#   a group's `addresses` / `addresses_deny` (groups-settings.json)
#       limit only what that group grants. blocked_groups() names the groups the
#       current request's address is refused for; the group-membership walks
#       (Auth::Settings::_group_closure, the processor's copy, Auth::Identity) leave
#       them, and everything that reaches them through nesting, out of the request.
#       So the group's capabilities, its page and file access (auth_groups, ACL
#       @group entries) and operator status all go together, at every gate, because
#       every gate resolves membership through those walks.
#
#   lazysite.conf `manager_addresses:` / `manager_addresses_deny:`
#       limit /manager/ and the manager API for everyone, independent of groups.
#       manager_refused() is the one test.
#
# A REQUEST CONTEXT IS REQUIRED. The users tool at a terminal, the build tools and
# the tests that call the library directly have no visitor, so there is no address
# to test and the rules are silent. A web request always carries REMOTE_ADDR (and the
# method); either one present makes this a request, and then an address that cannot
# be worked out is a deny (decide's `no-address`), never a pass.
#
# FAILS CLOSED, because decide() does: an address-list store that will not read denies
# wherever a rule names a list, so a faulted store drops every address-limited group
# and refuses the manager, and never quietly widens either.
#
# Audit: one `address-refused <target>` row per target per address per hour (the
# SM1115 pattern: the first refusal in the hour is recorded, so a scan cannot fill the
# trail), detail = the reason decide() gave and the list names.

use strict;
use warnings;
use Lazysite::Auth::AddressLists ();
use Lazysite::Util               qw(log_event);

our $LAZYSITE_DIR; # optional; the audit and the conf are found from here, else from the auth dir

# 1 when this process is serving a web request.
sub request_context {
    return ( defined $ENV{REMOTE_ADDR} || defined $ENV{REQUEST_METHOD} ) ? 1 : 0;
}

sub names { return _names(@_) }

sub _names {
    my ($v) = @_;
    return () unless defined $v;
    my @n = ref $v eq 'ARRAY' ? @$v : split /\s*,\s*/, $v;
    return grep { defined && !ref && length } map { s/\A\s+|\s+\z//gr } @n;
}

# The address, worked out once per (peer, forwarded, instance): client_address reads the
# conf for trusted_proxies and a request asks it for every group walk.
my %ADDR_MEMO;

sub _address {
    my ($auth_dir) = @_;
    my $key = join "\0", map { $_ // '' } $auth_dir, @ENV{qw(REMOTE_ADDR HTTP_X_FORWARDED_FOR)};
    return $ADDR_MEMO{$key} if exists $ADDR_MEMO{$key};
    %ADDR_MEMO = () if keys %ADDR_MEMO > 8;
    local $Lazysite::Auth::AddressLists::AUTH_DIR = $auth_dir;
    return $ADDR_MEMO{$key} = Lazysite::Auth::AddressLists::client_address();
}

sub _decide {
    my ( $auth_dir, $allow, $deny ) = @_;
    local $Lazysite::Auth::AddressLists::AUTH_DIR = $auth_dir;
    return Lazysite::Auth::AddressLists::decide( _address($auth_dir), allow => $allow, deny => $deny );
}

# { group => 1 } for the groups whose own address lists refuse this request. {} when
# no group carries a list (the common case: nothing is read), and when there is no
# request. $gs is the group-settings map the caller already holds.
sub blocked_groups {
    my ( $gs, $auth_dir ) = @_;
    return {} unless ref $gs eq 'HASH';
    # The users tool manages the stores: it reads what a group GRANTS, not what this
    # request may use of it, and says so by switching the rules off (it may have
    # inherited a web request's environment from the manager API that ran it).
    return {} if defined $Lazysite::Auth::Settings::ADDRESS_RULES && !$Lazysite::Auth::Settings::ADDRESS_RULES;
    my @limited = grep {
        ref $gs->{$_} eq 'HASH'
            && ( _names( $gs->{$_}{addresses} ) || _names( $gs->{$_}{addresses_deny} ) )
    } keys %$gs;
    return {} unless @limited && request_context() && defined $auth_dir;
    my %blocked;
    for my $g (@limited) {
        my @allow = _names( $gs->{$g}{addresses} );
        my @deny  = _names( $gs->{$g}{addresses_deny} );
        my ( $verdict, $why ) = _decide( $auth_dir, \@allow, \@deny );
        next unless $verdict eq 'deny';
        $blocked{$g} = [ $why, join( ',', @allow, @deny ) ];
    }
    return \%blocked;
}

# The hash blocked_groups returns, for the groups a walk actually left out of this
# request: one audit row each (once an hour per address).
sub note_dropped {
    my ( $blocked, $auth_dir, @names ) = @_;
    for my $g (@names) {
        next unless ref $blocked->{$g} eq 'ARRAY';
        audit_refusal( $auth_dir, "group $g", @{ $blocked->{$g} } );
    }
    return;
}

# The site-wide rule. Undef when the manager may be reached from this address, else
# [ reason, list names ].
sub manager_refused {
    my ($lz) = @_;
    return undef unless request_context() && defined $lz && length $lz;
    my $conf  = _conf($lz);
    my @allow = _names( $conf->{manager_addresses} );
    my @deny  = _names( $conf->{manager_addresses_deny} );
    return undef unless @allow || @deny;
    my ( $verdict, $why ) = _decide( "$lz/auth", \@allow, \@deny );
    return undef unless $verdict eq 'deny';
    return [ $why, join( ',', @allow, @deny ) ];
}

# Would this request itself be refused the manager under these lists? For the Config
# page: a setting that shuts the person making it out of the manager cannot be undone
# from the manager, so it is refused instead of written.
sub would_refuse {
    my ( $lz, $allow, $deny ) = @_;
    return 0 unless request_context() && defined $lz && length $lz;
    return 0 unless @$allow || @$deny;
    my ($verdict) = _decide( "$lz/auth", $allow, $deny );
    return $verdict eq 'deny' ? 1 : 0;
}

# manager_refused plus the audit row, for the doors.
sub refuse_manager {
    my ( $lz, $target, $user, $origin ) = @_;
    my $r = manager_refused($lz) or return 0;
    audit_refusal( "$lz/auth", $target, @$r, $user, $origin );
    return 1;
}

my %CONF_MEMO;

sub _conf {
    my ($lz) = @_;
    my $file = "$lz/lazysite.conf";
    my @st   = stat $file or return {};
    my $sig  = join "\0", @st[ 9, 7 ];
    return $CONF_MEMO{$file}{conf} if $CONF_MEMO{$file} && $CONF_MEMO{$file}{sig} eq $sig;
    my %c;
    if ( open my $fh, '<:utf8', $file ) {
        while ( my $l = <$fh> ) {
            $c{$1} = $2 if $l =~ /^(manager_addresses(?:_deny)?)\h*:\h*(.+?)\h*$/;
        }
        close $fh;
    }
    return ( $CONF_MEMO{$file} = { sig => $sig, conf => \%c } )->{conf};
}

# One row per target and address per hour, written by Lazysite::Auth::AddressAudit,
# the one writer every refusal by address goes through (SM1139's pages and files,
# these groups and the manager): one marker store (auth/.address-refused.db) and one
# row shape (detail "REASON; lists NAMES"), so the trail reads the same whichever
# rule refused. SM1140 first kept its own marker under logs/; the stack unified them.
#
# The memo saves reopening the marker store for every walk of one request (a request
# walks the group graph once per gate); the store is still what decides across
# processes. `our` so a test can stand in for a fresh process.
our %SEEN_THIS_PROCESS;

sub audit_refusal {
    my ( $auth_dir, $target, $why, $lists, $user, $origin ) = @_;
    my $lz = $LAZYSITE_DIR;
    unless ( defined $lz ) {
        ( $lz = $auth_dir // '' ) =~ s{/auth/?\z}{};
    }
    return unless length $lz;
    my $addr = _address($auth_dir) // '';
    my $key  = "$target|$addr";
    my $hour = int( time() / 3600 );
    return if ( $SEEN_THIS_PROCESS{$key} // -1 ) == $hour;
    $SEEN_THIS_PROCESS{$key} = $hour;
    eval {
        require Lazysite::Auth::AddressAudit;
        Lazysite::Auth::AddressAudit::refused(
            lazysite_dir => $lz,
            target       => $target,
            address      => $addr,
            reason       => $why,
            lists        => [ _names($lists) ],
            origin       => ( $origin // 'web' ),
            user         => $user,
        );
        1;
    } or log_event( 'WARN', $target, 'address refusal not audited', error => "$@" );
    return;
}

1;

__END__

=head1 NAME

Lazysite::Auth::AddressScope - the visitor's address as it limits a group and the manager (SM1140)

=head1 FUNCTIONS

C<blocked_groups($group_settings, $auth_dir)> the groups whose address lists refuse the
current request; C<note_dropped> audits the ones a walk left out; C<manager_refused($lazysite_dir)>
and C<refuse_manager> the site-wide C<manager_addresses> rule. See the comments above.

=cut
