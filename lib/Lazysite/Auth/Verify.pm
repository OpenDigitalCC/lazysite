package Lazysite::Auth::Verify;

# SM685: CREDENTIAL VERIFICATION WITHOUT THE SUBPROCESS.
#
# Every authenticated request used to spawn a perl interpreter and compile the
# whole of tools/lazysite-users.pl - three thousand statements - to answer one
# question: does this secret belong to this account, and what may it do. That
# is what drives verify_token_ms, and it is why the bench grew a work counter
# on the tool's LINE COUNT (work_users_tool_statements): the file's size is a
# per-request cost, so adding a statement anywhere in it made every login
# slower. A capability added in SM666 was refused a release for exactly that.
#
# The three callers - lazysite-auth.pl, lazysite-manager-api.pl and
# lazysite-mcp.pl - now `use` this module and call verify_credential directly.
# The subprocess was never needed for privilege reasons on this path: it reads
# the same files the CGI can already read, as the same user, and its only
# write is the last-used timestamp, which write_settings makes atomic.
#
# WHAT DELIBERATELY DID NOT COME ACROSS: _ensure_groups_seeded. The tool calls
# it from its own effective_settings wrapper and keeps doing so, because group
# SEEDING AND MIGRATION IS A MUTATION and does not belong on the hottest read
# path in the system. See the note on effective_settings below - the narrowing
# of SM645's healing trigger is real and is written down rather than absorbed.
#
# Context is $Lazysite::Auth::Settings::AUTH_DIR, set by each script after
# `use`, exactly as every other consumer of that module does it.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(read_users read_groups effective_settings verify_credential store_readable);

use JSON::PP                   ();
use Lazysite::Util             qw(cannot_read);
use Lazysite::Auth::Credential qw(verify_secret);
use Lazysite::Auth::Settings   qw(read_settings caps_for @CAP_KEYS);

# SM770/SM800: a store that could not be READ is not a store that says "no
# accounts". The flag records that distinction for a caller that needs to tell
# an empty answer from an unreadable one; cannot_read does the logging.
our $STORE_READABLE = 1;
sub store_readable { return $STORE_READABLE }

# SM800: NO -f GUARD, on either reader. A stat the process may not make fails
# like an open it may not make, and an auth directory without its search bit
# answered "no accounts" in silence. Lint 121 exists to catch exactly this.
sub _read_colon_file {
    my ( $file, $label, $split ) = @_;
    my %out;
    open( my $fh, '<:utf8', $file ) or do {
        $STORE_READABLE = 0 unless $!{ENOENT};    # errno first: cannot_read clobbers $!
        cannot_read( $label, $file );
        return %out;
    };
    # Read into a LEXICAL, not $_. This module is loaded into the CGIs now, so
    # a global the caller was mid-way through iterating is not this reader's to
    # borrow (lint 66).
    while ( defined( my $line = <$fh> ) ) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || !length $line;
        my ( $k, $v ) = split $split, $line, 2;
        next unless defined $k && defined $v;
        $out{$k} = $v;
    }
    close $fh;
    return %out;
}

sub read_users {
    return _read_colon_file( Lazysite::Auth::Settings::users_file(), 'users', qr/:/ );
}

sub read_groups {
    my %raw = _read_colon_file( Lazysite::Auth::Settings::groups_file(), 'groups', qr/:\s*/ );
    return map { $_ => [ map { s/^\s+|\s+$//gr } split /,/, $raw{$_} ] } keys %raw;
}

# The account's resolved settings: what it is, what it may do, where it is
# confined. A PURE DERIVATION from the settings store, the group store and the
# domain access rules - no seeding, no migration, no healing.
#
# SM645 PUT _ensure_groups_seeded ON THIS PATH so that an upgraded site adopted
# a new release's capabilities "the next time anybody touches it", and a login
# is the commonest touch there is. Moving verification off the subprocess takes
# that trigger away from the login path, and that is a real narrowing, not a
# no-op: the tool still heals from group-add, setup-sysop, the permissions
# grid, the capability-holders report and its own group reads, so a site whose
# manager UI is ever opened still adopts the release - but a site that is only
# ever logged into does not. It is written down in docs/decision-register.md
# because the fix has two defensible shapes (heal behind a once-per-release
# stamp, or accept the narrower trigger) and that is the release manager's
# call, not a choice to make silently inside a performance change.
sub effective_settings {
    my ( $docroot, $user ) = @_;
    my $all = read_settings();
    my $s   = $all->{$user} || {};

    # SM095: capability bools come from the ONE resolver (caps_for) - the same
    # one the manager API, MCP and the WebDAV endpoint consult, so a grant
    # resolves identically everywhere. Group-only since the clean cut (0.5.20).
    my $caps     = caps_for($user);
    my %g        = read_groups();
    my @mygroups = sort grep { grep { $_ eq $user } @{ $g{$_} || [] } } keys %g;

    # SM165: the effective scope comes from DOMAIN access, resolved against the
    # user's compound-expanded groups. The domain owns access; a lock narrows;
    # an empty result for a locked user is deny-all, not unconfined.
    my @scopes = Lazysite::Auth::Settings::resolve_user_scopes( $docroot, $user );
    my $hd     = Lazysite::Auth::Settings::resolve_home_domain( $docroot, $user );

    # SM233: the ancestors currently capping this account's content access,
    # walked exactly as resolve_user_scopes walks it. Empty means nothing caps it.
    my @ceiling;
    unless ( $s->{scope_independent} ) {
        my %seen = ( $user => 1 );
        my $anc  = $s->{created_by};
        while ( defined $anc && length $anc && !$seen{$anc}++ ) {
            push @ceiling, $anc;
            $anc = ( $all->{$anc} || {} )->{created_by};
        }
    }
    return {
        groups => \@mygroups,

        # EVERY CAPABILITY, FROM THE ONE LIST. A capability that reaches
        # caps_for but not this map is a grant that resolves and then reports
        # as absent - SEC-2026-07 (F3), and again in SM666: an operator would
        # grant run_jobs, see no sign of it, and grant it again. Derived, so
        # that is true by construction rather than by remembering.
        #
        # TWO KEYS ARE NOT DERIVABLE: `ui`, which comes from $s with an
        # inverted default and means "interactive login is allowed", and
        # `manager_ui`, which is $caps->{ui} under another name (SM127).
        ( map { $_ => $caps->{$_} ? JSON::PP::true() : JSON::PP::false() }
            grep { $_ ne 'ui' } @CAP_KEYS ),
        ui => ( exists $s->{ui} && !$s->{ui} ) ? JSON::PP::false() : JSON::PP::true(),
        manager_ui => $caps->{ui}              ? JSON::PP::true()  : JSON::PP::false(),

        dav_scopes  => \@scopes,
        home_domain => ( length $hd ) ? $hd : undef,

        # SM071 phase 2: sub-user provenance. created_by/created_at are
        # immutable; managed_by defaults to created_by and changes on reassign.
        created_by => $s->{created_by},
        created_at => $s->{created_at},
        managed_by => ( defined $s->{managed_by} ? $s->{managed_by} : $s->{created_by} ),

        # SM194: top-level-managed and scope-emancipated - two distinct sysop
        # decisions, reported apart.
        top_level => ( defined $s->{managed_by} && length $s->{managed_by} )
        ? JSON::PP::false()
        : JSON::PP::true(),
        scope_independent => $s->{scope_independent} ? JSON::PP::true() : JSON::PP::false(),
        scope_ceiling     => \@ceiling,
        disabled          => $s->{disabled} ? JSON::PP::true() : JSON::PP::false(),

        token_expires_at => $s->{token_expires_at},
        token_ttl        => $s->{token_ttl},
        display_name     => $s->{display_name},
        comment          => $s->{comment},

        # SM072: an outstanding setup/reset claim (the hash is never exposed).
        claim_pending => $s->{claim_hash} ? JSON::PP::true() : JSON::PP::false(),
        claim_purpose => ( $s->{claim_hash} ? $s->{claim_purpose} : undef ),
        expires_at    => $s->{expires_at},

        # SM148: "enrolled" means CONFIRMED - a secret that is enforced. A
        # pending, unconfirmed enrolment reports mfa_pending instead, so the UI
        # can show setup in progress without claiming 2FA is on.
        mfa_enrolled => ( $s->{totp_secret} && !$s->{mfa_pending} )
        ? JSON::PP::true()
        : JSON::PP::false(),
        mfa_pending => ( $s->{totp_secret} && $s->{mfa_pending} )
        ? JSON::PP::true()
        : JSON::PP::false(),
        mfa_required => $s->{mfa_required} ? JSON::PP::true() : JSON::PP::false(),
        email        => $s->{email},
    };
}

# Does this secret belong to this account, and what may the account do?
#
# The answer is the same hash the --api verb has always returned, because the
# verb now calls this. first_use is "the credential has not been used since it
# was issued", which is how a pairing key tells a first exchange from a replay.
sub verify_credential {
    my ( $docroot, $user, $secret ) = @_;
    return { ok => 0 } unless defined $user && length $user && defined $secret;

    # THIS MODULE VERIFIES; IT DOES NOT DELEGATE. An earlier draft honoured
    # LAZYSITE_USERS_TOOL here, reasoning that a deployment which nominates a
    # users tool has nominated the authority on credentials. That reasoning is
    # sound and it belongs in the CALLERS, because this module is also loaded
    # INSIDE the tool: cmd_verify_credential calls straight into here, the child
    # inherits the variable that named it, and the tool asks itself. It is not a
    # deep recursion - each hop is a fresh interpreter, so it is a fork bomb, and
    # it took the host out under the full suite (t/unit/manager/112 and 114 and
    # t/integration/18 point the variable at the real tool).
    #
    # The rule that cannot fail this way: the surfaces decide whether to shell
    # out, and the tool never consults the variable that named it.

    my %users  = read_users();
    my $stored = $users{$user};
    return { ok => 0 } unless defined $stored && verify_secret( $secret, $stored );

    my $eff = effective_settings( $docroot, $user );
    return { ok => 0 } if $eff->{disabled};

    my $exp = $eff->{token_expires_at};
    return { ok => 0, reason => 'expired' } if $exp && time() > $exp;
    my $aexp = $eff->{expires_at};    # SM072: account-level expiry
    return { ok => 0, reason => 'expired' } if $aexp && time() > $aexp;

    my $before    = read_settings()->{$user}  || {};
    my $iss       = $before->{cred_issued_at} || 0;
    my $first_use = ( ( $before->{cred_used_at} || 0 ) < $iss ) ? 1 : 0;
    Lazysite::Auth::Settings::touch_credential($user);

    return { ok => 1, username => $user, settings => $eff, first_use => $first_use };
}

1;
