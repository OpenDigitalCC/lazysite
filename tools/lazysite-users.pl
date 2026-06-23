#!/usr/bin/perl
# lazysite-users.pl - user management for lazysite built-in auth
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Path qw(make_path);

# H-2 / M-6: salted iterated SHA-256 hashing, CSPRNG fail-closed.
sub generate_random_hex {
    my ($bytes) = @_;
    open my $fh, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $fh, $raw, $bytes );
    close $fh;
    die "Short read from /dev/urandom ($got of $bytes bytes)\n"
        unless defined $got && $got == $bytes;
    return unpack( 'H*', $raw );
}

sub hash_password {
    my ($password) = @_;
    my $salt  = generate_random_hex(16);   # 32 hex chars = 16 bytes
    my $iters = 100_000;
    my $hash  = $password;
    $hash = sha256_hex( $salt . $hash ) for 1 .. $iters;
    return "sha256iter:$salt:$iters:$hash";
}

# SM070: a generated credential is a 256-bit random token, so a single
# SHA-256 round is enough - the iterated stretching that protects
# low-entropy human passwords buys nothing against a 256-bit secret,
# and WebDAV verifies the credential on every request. Stored in the
# same sha256iter format with iterations=1; verify_password reads the
# iteration count from the row, so no verifier changes are needed.
# Only this path writes iterations=1.
sub hash_token {
    my ($token) = @_;
    my $salt = generate_random_hex(16);
    my $hash = sha256_hex( $salt . $token );
    return "sha256iter:$salt:1:$hash";
}

sub generate_token {
    return 'lzs_' . generate_random_hex(32);   # 64 hex chars = 32 bytes
}

my $LOG_COMPONENT = 'users';

# SM071 Phase 2: token lifecycle (model A). A single-use pairing key is
# exchanged for a short-lived access token that the client rotates before
# it expires. TTLs in seconds.
my $PAIRING_TTL      = 900;     # 15 minutes
my $ACCESS_TOKEN_TTL = 86_400;  # 24 hours

my $DOCROOT;
my $API_MODE = 0;
my @args;

while (@ARGV) {
    my $arg = shift @ARGV;
    if    ( $arg eq '--docroot' ) { $DOCROOT = shift @ARGV }
    elsif ( $arg eq '--api' )     { $API_MODE = 1 }
    elsif ( $arg eq '--help' )    { usage(); exit 0 }
    else                          { push @args, $arg }
}

unless ($DOCROOT) {
    print STDERR "Error: --docroot is required\n\n";
    usage();
    exit 1;
}

my $AUTH_DIR = "$DOCROOT/lazysite/auth";
# Only set the default mode when we create the dir. Re-chmodding on every
# run would clobber an operator's deliberate perms (e.g. 2770 group-write
# for a www-data CGI that must mint .secret / rate DBs here).
unless ( -d $AUTH_DIR ) {
    make_path($AUTH_DIR);
    chmod 0750, $AUTH_DIR;
}

my $USERS_FILE    = "$AUTH_DIR/users";
my $GROUPS_FILE   = "$AUTH_DIR/groups";
my $SETTINGS_FILE = "$AUTH_DIR/user-settings.json";

# --- API mode ---

if ( $API_MODE ) {
    require JSON::PP;
    JSON::PP->import(qw(encode_json decode_json));

    my $input = do { local $/; <STDIN> };
    my $req   = eval { decode_json($input // '{}') } or do {
        print encode_json({ ok => 0, error => "Invalid JSON input" });
        exit 0;
    };

    my $action = $req->{action} // '';
    my $result;

    eval {
        if    ( $action eq 'add' ) {
            cmd_add( $req->{username}, $req->{password} );
            $result = { ok => 1, message => "User added" };
        }
        elsif ( $action eq 'passwd' ) {
            cmd_passwd( $req->{username}, $req->{password} );
            $result = { ok => 1, message => "Password updated" };
        }
        elsif ( $action eq 'remove' ) {
            cmd_remove( $req->{username} );
            $result = { ok => 1, message => "User removed" };
        }
        elsif ( $action eq 'list' ) {
            my %users = read_users();
            $result = { ok => 1, users => [ sort keys %users ] };
        }
        elsif ( $action eq 'group-add' ) {
            cmd_group_add( $req->{username}, $req->{group} );
            $result = { ok => 1, message => "User added to group" };
        }
        elsif ( $action eq 'group-remove' ) {
            cmd_group_remove( $req->{username}, $req->{group} );
            $result = { ok => 1, message => "User removed from group" };
        }
        elsif ( $action eq 'groups' ) {
            my %groups = read_groups();
            $result = { ok => 1, groups => \%groups };
        }
        elsif ( $action eq 'settings-get' ) {
            my %users = read_users();
            die "User '" . ( $req->{username} // '' ) . "' not found\n"
                unless $req->{username} && exists $users{ $req->{username} };
            $result = { ok => 1, settings => effective_settings( $req->{username} ) };
        }
        elsif ( $action eq 'settings-set' ) {
            cmd_set( $req->{username}, $req->{key}, $req->{value},
                     force => ( $req->{force} ? 1 : 0 ) );
            $result = { ok => 1, message => "Setting updated" };
        }
        elsif ( $action eq 'token' ) {
            my $token = cmd_token( $req->{username} );
            $result = { ok => 1, token => $token };
        }
        elsif ( $action eq 'account-create' ) {
            cmd_account_create( $req->{username}, $req->{password},
                created_by  => $req->{created_by},
                actor       => $req->{actor},
                create_subs => ( $req->{create_sub_users} ? 1 : 0 ) );
            $result = { ok => 1, message => "Sub-user created" };
        }
        elsif ( $action eq 'account-disable' ) {
            cmd_account_set_disabled( $req->{username}, 1,
                actor => $req->{actor}, cascade => ( $req->{cascade} ? 1 : 0 ) );
            $result = { ok => 1, message => "Account disabled" };
        }
        elsif ( $action eq 'account-enable' ) {
            cmd_account_set_disabled( $req->{username}, 0,
                actor => $req->{actor}, cascade => ( $req->{cascade} ? 1 : 0 ) );
            $result = { ok => 1, message => "Account enabled" };
        }
        elsif ( $action eq 'account-reassign' ) {
            cmd_account_reassign( $req->{username}, $req->{to},
                actor => $req->{actor} );
            $result = { ok => 1, message => "Account reassigned" };
        }
        elsif ( $action eq 'pairing-key' ) {
            my $key = cmd_pairing_key( $req->{username} );
            $result = { ok => 1, pairing_key => $key };
        }
        elsif ( $action eq 'token-exchange' ) {
            my $token = cmd_token_exchange( $req->{username}, $req->{pairing_key} );
            $result = { ok => 1, token => $token };
        }
        elsif ( $action eq 'token-rotate' ) {
            my $token = cmd_token_rotate( $req->{username} );
            $result = { ok => 1, token => $token };
        }
        elsif ( $action eq 'verify-credential' ) {
            $result = cmd_verify_credential( $req->{username}, $req->{secret} );
        }
        elsif ( $action eq 'onboarding' ) {
            my $r = cmd_onboarding( $req->{username} );
            $result = { ok => 1, %$r };
        }
        elsif ( $action eq 'partner-create' ) {
            my $r = cmd_partner_create( $req->{username},
                created_by  => $req->{created_by},
                themes      => ( exists $req->{manage_themes}
                                 ? ( $req->{manage_themes} ? 1 : 0 ) : 1 ),
                layouts     => ( $req->{manage_layouts}   ? 1 : 0 ),
                config      => ( $req->{manage_config}    ? 1 : 0 ),
                scope       => $req->{dav_scope},
                create_subs => ( $req->{create_sub_users} ? 1 : 0 ) );
            $result = { ok => 1, %$r };
        }
        else {
            $result = { ok => 0, error => "Unknown action: $action" };
        }
    };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        $result = { ok => 0, error => $err };
    }

    print encode_json($result);
    exit 0;
}

# --- CLI mode ---

my $cmd = shift @args // '';

if    ( $cmd eq 'add' )          { cmd_add(@args) }
elsif ( $cmd eq 'passwd' )       { cmd_passwd(@args) }
elsif ( $cmd eq 'remove' )       { cmd_remove(@args) }
elsif ( $cmd eq 'list' )         { cmd_list() }
elsif ( $cmd eq 'group-add' )    { cmd_group_add(@args) }
elsif ( $cmd eq 'group-remove' ) { cmd_group_remove(@args) }
elsif ( $cmd eq 'groups' )       { cmd_groups() }
elsif ( $cmd eq 'settings' )     { cmd_settings(@args) }
elsif ( $cmd eq 'set' )          { cmd_set_cli(@args) }
elsif ( $cmd eq 'token' )        { cmd_token(@args) }
elsif ( $cmd eq 'account-create' )   { cmd_account_create_cli(@args) }
elsif ( $cmd eq 'account-disable' )  { cmd_account_disable_cli(@args) }
elsif ( $cmd eq 'account-enable' )   { cmd_account_enable_cli(@args) }
elsif ( $cmd eq 'account-reassign' ) { cmd_account_reassign_cli(@args) }
elsif ( $cmd eq 'pairing-key' )    { cmd_pairing_key(@args) }
elsif ( $cmd eq 'token-exchange' ) { cmd_token_exchange(@args) }
elsif ( $cmd eq 'token-rotate' )   { cmd_token_rotate(@args) }
elsif ( $cmd eq 'partner-create' ) { cmd_partner_create_cli(@args) }
else {
    print STDERR "Unknown command: $cmd\n\n" if $cmd;
    usage();
    exit 1;
}

# --- Commands ---

sub cmd_add {
    my ( $user, $pass ) = @_;
    die "Username required\n" unless defined $user && length $user;
    $user =~ s/[^a-zA-Z0-9_.-]//g;
    die "Username required\n" unless length $user;
    $pass = '' unless defined $pass;

    my %users = read_users();
    die "User '$user' already exists\n" if $users{$user};

    # Empty password => empty hash: a token-only account (no interactive
    # login; generate a token for WebDAV/API). Same form as the seed.
    $users{$user} = length($pass) ? hash_password($pass) : '';
    write_users(%users);
    log_event('INFO', $user, 'user added');
    print "User '$user' added.\n" unless $API_MODE;
}

sub cmd_passwd {
    my ( $user, $pass ) = @_;
    die "Username and password required\n" unless $user && $pass;

    my %users = read_users();
    # exists, not truthiness: a seeded account with an empty password hash
    # ('user:') is present but falsey - passwd must still set its password.
    die "User '$user' not found\n" unless exists $users{$user};

    $users{$user} = hash_password($pass);
    write_users(%users);
    clear_token_expiry($user);   # SM071: a password has no token expiry
    log_event('INFO', $user, 'password changed');
    print "Password updated for '$user'.\n" unless $API_MODE;
}

sub cmd_remove {
    my ($user) = @_;
    die "Username required\n" unless $user;

    my %users = read_users();
    die "User '$user' not found\n" unless delete $users{$user};

    write_users(%users);
    log_event('INFO', $user, 'user removed');

    if ( -f $GROUPS_FILE ) {
        my %groups = read_groups();
        for my $g ( keys %groups ) {
            $groups{$g} = [ grep { $_ ne $user } @{ $groups{$g} } ];
        }
        write_groups(%groups);
    }

    # SM070: drop the user's access-mechanism settings too.
    my $settings = read_settings();
    if ( exists $settings->{$user} ) {
        delete $settings->{$user};
        write_settings($settings);
    }

    print "User '$user' removed.\n" unless $API_MODE;
}

sub cmd_list {
    my %users = read_users();
    if ( %users ) {
        print "$_\n" for sort keys %users;
    }
    else {
        print "No users.\n";
    }
}

sub cmd_group_add {
    my ( $user, $group ) = @_;
    die "Username and group required\n" unless $user && $group;

    my %users = read_users();
    die "User '$user' not found\n" unless $users{$user};

    my %groups = read_groups();
    $groups{$group} //= [];
    unless ( grep { $_ eq $user } @{ $groups{$group} } ) {
        push @{ $groups{$group} }, $user;
    }
    write_groups(%groups);
    print "User '$user' added to group '$group'.\n" unless $API_MODE;
}

sub cmd_group_remove {
    my ( $user, $group ) = @_;
    die "Username and group required\n" unless $user && $group;

    my %groups = read_groups();
    die "Group '$group' not found\n" unless $groups{$group};

    $groups{$group} = [ grep { $_ ne $user } @{ $groups{$group} } ];
    write_groups(%groups);
    print "User '$user' removed from group '$group'.\n" unless $API_MODE;
}

sub cmd_groups {
    my %groups = read_groups();
    if ( %groups ) {
        for my $g ( sort keys %groups ) {
            printf "%-20s %s\n", "$g:", join( ', ', @{ $groups{$g} } );
        }
    }
    else {
        print "No groups.\n";
    }
}

# --- SM070: access-mechanism settings and credential generation ---

# Effective settings for a user, defaults applied:
#   ui:        on  (preserve existing behaviour for users with no row)
#   webdav:    off (new surface is opt-in per user)
#   dav_scope: undef (docroot-wide, still subject to endpoint denials)
sub effective_settings {
    my ($user) = @_;
    my $all = read_settings();
    my $s   = $all->{$user} || {};
    my $scope = $s->{dav_scope};
    $scope = undef unless defined $scope && length $scope;
    return {
        webdav    => $s->{webdav} ? JSON::PP::true() : JSON::PP::false(),
        ui        => ( exists $s->{ui} && !$s->{ui} ) ? JSON::PP::false() : JSON::PP::true(),
        dav_scope => $scope,
        # SM071 Phase 2: sub-user provenance and delegation. created_by /
        # created_at are immutable; managed_by defaults to created_by and
        # changes only on reassign. Top-level (operator-created) accounts
        # have no provenance row, so these are null/false for them.
        created_by => $s->{created_by},
        created_at => $s->{created_at},
        managed_by => ( defined $s->{managed_by} ? $s->{managed_by} : $s->{created_by} ),
        create_sub_users           => $s->{create_sub_users}           ? JSON::PP::true() : JSON::PP::false(),
        delegate_sub_user_creation => $s->{delegate_sub_user_creation} ? JSON::PP::true() : JSON::PP::false(),
        disabled                   => $s->{disabled}                   ? JSON::PP::true() : JSON::PP::false(),
        # SM071 Phase 2: theme/layout/config management capabilities.
        manage_themes  => $s->{manage_themes}  ? JSON::PP::true() : JSON::PP::false(),
        manage_layouts => $s->{manage_layouts} ? JSON::PP::true() : JSON::PP::false(),
        manage_config  => $s->{manage_config}  ? JSON::PP::true() : JSON::PP::false(),
        # SM071 Phase 2: access-token expiry (null = no expiry, e.g. a
        # human password or an operator-minted permanent credential).
        token_expires_at => $s->{token_expires_at},
        # Free-text operator annotation (what this account is for).
        comment => $s->{comment},
    };
}

sub cmd_settings {
    my ($user) = @_;
    die "Username required\n" unless $user;
    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $eff = effective_settings($user);
    printf "%-11s %s\n", 'webdav:', $eff->{webdav}        ? 'on' : 'off';
    printf "%-11s %s\n", 'ui:',     $eff->{ui}            ? 'on' : 'off';
    printf "%-11s %s\n", 'dav_scope:',
        defined $eff->{dav_scope} ? $eff->{dav_scope} : '(unset)';
}

# CLI wrapper: pull an optional --force flag out of the positional args.
sub cmd_set_cli {
    my @pos;
    my $force = 0;
    for my $a (@_) {
        if   ( $a eq '--force' ) { $force = 1 }
        else                     { push @pos, $a }
    }
    cmd_set( $pos[0], $pos[1], $pos[2], force => $force );
}

sub cmd_set {
    my ( $user, $key, $value, %opt ) = @_;
    die "Usage: set USERNAME (webdav|ui|dav_scope) VALUE\n"
        unless defined $user && length $user && defined $key && length $key;

    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $all = read_settings();
    $all->{$user} ||= {};

    # SM071 Phase 2: create_sub_users / delegate_sub_user_creation join
    # the boolean settings. Provenance keys (created_by / created_at /
    # managed_by) are deliberately NOT settable here - they are stamped at
    # creation and changed only by account-create / account-reassign.
    my %bool_key = map { $_ => 1 }
        qw(webdav ui create_sub_users delegate_sub_user_creation
           manage_themes manage_layouts manage_config);

    if ( $bool_key{$key} ) {
        my $bool = parse_onoff($value);
        if ( $key eq 'ui' && !$bool && !$opt{force} ) {
            die "would disable last manager-capable UI account\n"
                if is_last_manager_ui( $user, $all );
        }
        $all->{$user}{$key} = $bool ? JSON::PP::true() : JSON::PP::false();
    }
    elsif ( $key eq 'dav_scope' ) {
        my $scope = normalise_scope($value);
        if ( defined $scope ) { $all->{$user}{dav_scope} = $scope }
        else                  { delete $all->{$user}{dav_scope} }
    }
    elsif ( $key eq 'comment' ) {
        # Free-text operator annotation (single line, length-capped).
        my $c = defined $value ? "$value" : '';
        $c =~ s/[\r\n\t]+/ /g;
        $c =~ s/^\s+|\s+$//g;
        $c = substr( $c, 0, 200 ) if length($c) > 200;
        if ( length $c ) { $all->{$user}{comment} = $c }
        else             { delete $all->{$user}{comment} }
    }
    else {
        die "Unknown setting '$key' (expected webdav, ui, dav_scope, comment, "
          . "create_sub_users, delegate_sub_user_creation, "
          . "manage_themes, manage_layouts, or manage_config)\n";
    }

    write_settings($all);
    log_event( 'INFO', $user, 'settings changed', key => $key );
    print "Set $key for '$user'.\n" unless $API_MODE;
}

# Generate and store a fresh credential. Returns the plaintext token
# (shown to the caller exactly once); never logged, never stored in
# the clear.
sub cmd_token {
    my ($user) = @_;
    die "Username required\n" unless $user;

    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $token = generate_token();
    $users{$user} = hash_token($token);
    write_users(%users);
    clear_token_expiry($user);   # SM071: operator credential is permanent
    log_event( 'INFO', $user, 'credential generated' );

    unless ($API_MODE) {
        print "Generated credential for '$user' (shown once, store it now):\n";
        print "$token\n";
    }
    return $token;
}

# SM071 Phase 2: create a sub-user with provenance. Unlike `add` (an
# operator bootstrap that creates a top-level account with no settings
# row), account-create records who created the account and gates on the
# creator's permissions:
#   - the creator must hold create_sub_users;
#   - granting the new account create_sub_users requires the creator to
#     also hold delegate_sub_user_creation (the right to pass on the right).
# created_by and managed_by are set to the creator; created_at to now.
sub cmd_account_create {
    my ( $user, $pass, %opt ) = @_;
    my $creator = $opt{created_by};
    die "Username and password required\n"
        unless defined $user && length $user && defined $pass && length $pass;
    die "Creator (--by USERNAME) required\n"
        unless defined $creator && length $creator;
    $user =~ s/[^a-zA-Z0-9_.-]//g;
    die "Username and password required\n" unless length $user;

    my %users = read_users();
    die "User '$user' already exists\n" if $users{$user};
    die "Creator '$creator' not found\n" unless exists $users{$creator};

    my $all = read_settings();
    my $cs  = $all->{$creator} || {};
    die "Creator '$creator' lacks create_sub_users permission\n"
        unless $cs->{create_sub_users};
    if ( $opt{create_subs} ) {
        die "Creator '$creator' lacks delegate_sub_user_creation permission\n"
            unless $cs->{delegate_sub_user_creation};
    }

    # Authorise the actor: you may create an account owned by yourself or by
    # anyone in your sub-tree (the parent must still hold create_sub_users,
    # checked above). The operator ('local', no manager_groups) is
    # unrestricted.
    my $actor = $opt{actor};
    if ( defined $actor && length $actor && $actor ne 'local' ) {
        die "Not authorised to create an account under '$creator'\n"
            unless $actor eq $creator || is_ancestor( $actor, $creator, $all );
    }

    $users{$user} = hash_password($pass);
    write_users(%users);

    $all->{$user} ||= {};
    $all->{$user}{created_by} = $creator;
    $all->{$user}{managed_by} = $creator;
    $all->{$user}{created_at} = time();
    $all->{$user}{create_sub_users} = JSON::PP::true() if $opt{create_subs};
    write_settings($all);

    log_event( 'INFO', $user, 'sub-user created', created_by => $creator );
    print "Sub-user '$user' created (parent '$creator').\n" unless $API_MODE;
}

# CLI wrapper: account-create USER PASS --by PARENT [--create-subs]
sub cmd_account_create_cli {
    my @pos;
    my ( $created_by, $create_subs );
    my @a = @_;
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '--by' )          { $created_by  = shift @a }
        elsif ( $x eq '--create-subs' ) { $create_subs = 1 }
        else                            { push @pos, $x }
    }
    cmd_account_create( $pos[0], $pos[1],
        created_by => $created_by, create_subs => $create_subs );
}

# SM071 Phase 2: sub-user tree helpers (managed_by edges).

sub _managed_by {
    my ($s) = @_;
    return defined $s->{managed_by} ? $s->{managed_by} : $s->{created_by};
}

# All accounts in $user's sub-tree (transitive children via managed_by).
sub descendants {
    my ( $user, $all ) = @_;
    my %children;
    for my $u ( keys %$all ) {
        my $p = _managed_by( $all->{$u} );
        push @{ $children{$p} }, $u if defined $p;
    }
    my @queue = ($user);
    my ( %seen, @out );
    while (@queue) {
        my $cur = shift @queue;
        for my $c ( @{ $children{$cur} || [] } ) {
            next if $seen{$c}++;
            push @out, $c;
            push @queue, $c;
        }
    }
    return @out;
}

# Is $actor an ancestor of $target via the managed_by chain?
sub is_ancestor {
    my ( $actor, $target, $all ) = @_;
    return 0 unless defined $actor && defined $target;
    my %seen;
    my $cur = $target;
    while ( defined $cur && !$seen{$cur}++ ) {
        my $p = _managed_by( $all->{$cur} || {} );
        return 0 unless defined $p;
        return 1 if $p eq $actor;
        $cur = $p;
    }
    return 0;
}

# Authorise a management action. CLI (no actor) is the unrestricted
# operator; an API actor may only manage accounts in its own sub-tree.
sub _authorise_manage {
    my ( $actor, $target, $all ) = @_;
    return if !defined $actor || !length $actor;   # operator / CLI
    die "Not authorised to manage '$target'\n"
        unless is_ancestor( $actor, $target, $all );
}

# SM071 Phase 2: disable / enable, optionally cascading over the
# sub-tree. Disabling leaves the tree structure intact so enable can
# reverse it. A disabled account fails authentication everywhere.
sub cmd_account_set_disabled {
    my ( $user, $disabled, %opt ) = @_;   # opt: actor, cascade
    die "Username required\n" unless defined $user && length $user;
    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $all = read_settings();
    _authorise_manage( $opt{actor}, $user, $all );

    my @targets = ($user);
    push @targets, descendants( $user, $all ) if $opt{cascade};

    for my $t (@targets) {
        $all->{$t} ||= {};
        if   ($disabled) { $all->{$t}{disabled} = JSON::PP::true() }
        else             { delete $all->{$t}{disabled} }
    }
    write_settings($all);
    log_event( 'INFO', $user, ( $disabled ? 'account disabled' : 'account enabled' ),
        cascade => ( $opt{cascade} ? 1 : 0 ), count => scalar(@targets) );
    print( ( $disabled ? 'Disabled ' : 'Enabled ' )
         . scalar(@targets) . " account(s).\n" ) unless $API_MODE;
}

# SM071 Phase 2: reassign an account (and its sub-tree, which follows
# via managed_by) to a new parent. created_by is left as immutable
# provenance; only managed_by changes.
sub cmd_account_reassign {
    my ( $user, $new_parent, %opt ) = @_;   # opt: actor
    die "Usage: account-reassign USER --to NEWPARENT\n"
        unless defined $user && length $user
            && defined $new_parent && length $new_parent;
    die "Cannot reassign an account to itself\n" if $user eq $new_parent;

    my %users = read_users();
    die "User '$user' not found\n"        unless exists $users{$user};
    die "New parent '$new_parent' not found\n" unless exists $users{$new_parent};

    my $all = read_settings();
    _authorise_manage( $opt{actor}, $user, $all );

    my %desc = map { $_ => 1 } descendants( $user, $all );
    die "Cannot reassign '$user' under its own sub-tree (cycle)\n"
        if $desc{$new_parent};

    $all->{$user} ||= {};
    $all->{$user}{managed_by} = $new_parent;   # created_by untouched
    write_settings($all);
    log_event( 'INFO', $user, 'account reassigned', to => $new_parent );
    print "Reassigned '$user' to '$new_parent'.\n" unless $API_MODE;
}

# CLI wrappers: pull --actor / --cascade / --to out of positional args.
sub cmd_account_disable_cli {
    my ( @pos, $actor, $cascade );
    my @a = @_;
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '--actor' )   { $actor   = shift @a }
        elsif ( $x eq '--cascade' ) { $cascade = 1 }
        else                        { push @pos, $x }
    }
    cmd_account_set_disabled( $pos[0], 1, actor => $actor, cascade => $cascade );
}

sub cmd_account_enable_cli {
    my ( @pos, $actor, $cascade );
    my @a = @_;
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '--actor' )   { $actor   = shift @a }
        elsif ( $x eq '--cascade' ) { $cascade = 1 }
        else                        { push @pos, $x }
    }
    cmd_account_set_disabled( $pos[0], 0, actor => $actor, cascade => $cascade );
}

sub cmd_account_reassign_cli {
    my ( @pos, $actor, $to );
    my @a = @_;
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '--actor' ) { $actor = shift @a }
        elsif ( $x eq '--to' )    { $to    = shift @a }
        else                      { push @pos, $x }
    }
    cmd_account_reassign( $pos[0], $to, actor => $actor );
}

# SM071 Phase 2: token lifecycle (model A).
#
# Verify a plaintext secret against a stored sha256iter hash (the format
# hash_token / hash_password write). Constant-time on the digest.
sub verify_secret {
    my ( $plain, $stored ) = @_;
    return 0 unless defined $plain && defined $stored;
    return 0 unless $stored =~ /\Asha256iter:([0-9a-f]+):(\d+):([0-9a-f]{64})\z/;
    my ( $salt, $iters, $want ) = ( $1, $2, $3 );
    my $h = $plain;
    $h = sha256_hex( $salt . $h ) for 1 .. $iters;
    return 0 unless length $h == length $want;
    my $diff = 0;
    $diff |= ord( substr $h, $_, 1 ) ^ ord( substr $want, $_, 1 )
        for 0 .. length($h) - 1;
    return $diff == 0;
}

# Drop any access-token expiry for a user (the credential is now a
# password or a permanent operator credential, neither of which expires).
sub clear_token_expiry {
    my ($user) = @_;
    my $all = read_settings();
    return unless exists $all->{$user} && exists $all->{$user}{token_expires_at};
    delete $all->{$user}{token_expires_at};
    write_settings($all);
}

# Mint a single-use, short-lived pairing key for a user. The hash and an
# expiry are stored in the user's settings; the plaintext is returned
# once. This is the bootstrap secret an automated partner exchanges for
# an access token on first connection.
# Issue a single-use pairing key into the in-memory settings (the caller
# writes). Returns the plaintext key.
sub _issue_pairing_key {
    my ( $all, $user ) = @_;
    my $key = 'lzp_' . generate_random_hex(24);
    $all->{$user} ||= {};
    $all->{$user}{pairing_key_hash}       = hash_token($key);
    $all->{$user}{pairing_key_expires_at} = time() + $PAIRING_TTL;
    return $key;
}

sub cmd_pairing_key {
    my ($user) = @_;
    die "Username required\n" unless defined $user && length $user;
    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $all = read_settings();
    my $key = _issue_pairing_key( $all, $user );
    write_settings($all);
    log_event( 'INFO', $user, 'pairing key issued' );

    unless ($API_MODE) {
        print "Pairing key for '$user' (single use, expires in "
            . int( $PAIRING_TTL / 60 ) . " min; shown once):\n$key\n";
    }
    return $key;
}

# Exchange a valid pairing key for a fresh access token. The pairing key
# is single-use (consumed on success). The access token replaces the
# user's credential and is stamped with an expiry.
sub cmd_token_exchange {
    my ( $user, $key ) = @_;
    die "Username and pairing key required\n"
        unless defined $user && length $user && defined $key && length $key;

    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $all = read_settings();
    my $s   = $all->{$user} || {};
    die "No pairing key issued for '$user'\n" unless $s->{pairing_key_hash};
    die "Pairing key expired\n"
        if !$s->{pairing_key_expires_at} || time() > $s->{pairing_key_expires_at};
    die "Invalid pairing key\n" unless verify_secret( $key, $s->{pairing_key_hash} );

    delete $all->{$user}{pairing_key_hash};         # single use
    delete $all->{$user}{pairing_key_expires_at};

    my $token = generate_token();
    $users{$user} = hash_token($token);
    write_users(%users);
    $all->{$user}{token_expires_at} = time() + $ACCESS_TOKEN_TTL;
    write_settings($all);
    log_event( 'INFO', $user, 'access token issued via pairing exchange' );

    unless ($API_MODE) {
        print "Access token for '$user' (expires in "
            . int( $ACCESS_TOKEN_TTL / 3600 ) . "h; shown once):\n$token\n";
    }
    return $token;
}

# Rotate the access token: mint a new one and reset the expiry. The old
# token is replaced immediately (no overlap window - a grace window is a
# deferred refinement; the client rotates before expiry and uses the new
# token from the rotate response).
sub cmd_token_rotate {
    my ($user) = @_;
    die "Username required\n" unless defined $user && length $user;
    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};

    my $token = generate_token();
    $users{$user} = hash_token($token);
    write_users(%users);
    my $all = read_settings();
    $all->{$user} ||= {};
    $all->{$user}{token_expires_at} = time() + $ACCESS_TOKEN_TTL;
    write_settings($all);
    log_event( 'INFO', $user, 'access token rotated' );

    unless ($API_MODE) {
        print "Rotated access token for '$user' (expires in "
            . int( $ACCESS_TOKEN_TTL / 3600 ) . "h; shown once):\n$token\n";
    }
    return $token;
}

# Read a scalar value from lazysite.conf (for the onboarding brief).
sub read_conf_value {
    my ($key) = @_;
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    return undef unless -f $conf;
    open my $fh, '<', $conf or return undef;
    my $val;
    while (<$fh>) { if (/^\Q$key\E\s*:\s*(.+)/) { $val = $1; last } }
    close $fh;
    return undef unless defined $val;
    $val =~ s/^\s+|\s+$//g;
    return $val;
}

# Build the partner onboarding brief (plain Markdown) - the file a human
# hands to their automated partner. Accurate to what exists now; notes
# the control-API surface as forthcoming.
sub _onboarding_brief {
    my ( $name, $key, $s ) = @_;
    my $base = read_conf_value('site_url') // 'https://YOUR-SITE';
    # Resolve ${REQUEST_SCHEME}/${SERVER_NAME} - set in the CGI env when the
    # brief is generated via the manager API; sensible fallbacks otherwise.
    $base =~ s/\$\{REQUEST_SCHEME\}/$ENV{REQUEST_SCHEME} || 'https'/ge;
    $base =~ s/\$\{SERVER_NAME\}/$ENV{SERVER_NAME} || $ENV{HTTP_HOST} || 'YOUR-SITE'/ge;
    my @caps;
    push @caps, 'publish content over WebDAV (`/dav`)' if $s->{webdav};
    push @caps, 'manage themes'             if $s->{manage_themes};
    push @caps, 'manage layouts'            if $s->{manage_layouts};
    push @caps, 'set allowlisted site config' if $s->{manage_config};
    my $caps = join "\n", map { "- $_" } @caps;
    my $scope = ( defined $s->{dav_scope} && length $s->{dav_scope} )
        ? $s->{dav_scope} : 'whole docroot (minus denied paths)';

    return <<"BRIEF";
# Automated partner: $name

You are an automated publishing partner for $base.

## Your capabilities

$caps
- Content scope: $scope

## Getting connected

Your operator exchanges this one-time pairing key for an access token:

    pairing key: $key

The key is single-use and short-lived. Exchange yields an access token
(prefix `lzs_`) that you present as HTTP Basic auth to the WebDAV
endpoint:

    $base/dav/

Rotate the token before it expires; an expired token returns HTTP 401.

## Documentation

All publishing and management docs live on this site - fetch them over HTTP:

- Agent briefings (start here):
    $base/docs/ai-briefing-authoring
    $base/docs/ai-briefing-configuration
    $base/docs/ai-briefing-layouts
- Every page, machine-readable (discover the rest from here):
    $base/llms.txt

## Notes

- HTTP-based token exchange/rotation and theme/layout management over the
  control API arrive with the control-API release. Until then your
  operator performs the exchange and hands you the access token.
BRIEF
}

# SM071 Phase 3: verify a presented credential (used by the control-API
# front-path in lazysite-manager-api.pl). Verifies the secret against the
# stored hash, rejects disabled accounts and expired access tokens, and
# returns the effective settings (capabilities) for the caller to gate on.
sub cmd_verify_credential {
    my ( $user, $secret ) = @_;
    return { ok => 0 } unless defined $user && length $user && defined $secret;
    my %users  = read_users();
    my $stored = $users{$user};
    return { ok => 0 } unless defined $stored && verify_secret( $secret, $stored );

    my $eff = effective_settings($user);
    return { ok => 0 } if $eff->{disabled};
    my $exp = $eff->{token_expires_at};
    return { ok => 0 } if $exp && time() > $exp;

    return { ok => 1, username => $user, settings => $eff };
}

# SM071 Phase 2: one-step partner provisioning. Creates a sub-user with a
# locked password (a partner authenticates with a token, not a password),
# applies the partner capability defaults (webdav + manage_themes, plus
# any requested extras), mints a pairing key, and returns the onboarding
# brief.
# SM071: mint a fresh pairing key + onboarding brief for an existing user
# (the manager Users-page "download onboarding" affordance).
sub cmd_onboarding {
    my ($user) = @_;
    die "Username required\n" unless defined $user && length $user;
    my %users = read_users();
    die "User '$user' not found\n" unless exists $users{$user};
    my $all = read_settings();
    my $key = _issue_pairing_key( $all, $user );
    write_settings($all);
    log_event( 'INFO', $user, 'onboarding brief issued' );
    return {
        username    => $user,
        pairing_key => $key,
        onboarding  => _onboarding_brief( $user, $key, $all->{$user} || {} ),
    };
}

sub cmd_partner_create {
    my ( $name, %opt ) = @_;
    die "Partner name required\n" unless defined $name && length $name;
    die "Creator (--by USERNAME) required\n"
        unless defined $opt{created_by} && length $opt{created_by};

    my $locked = generate_random_hex(32);
    cmd_account_create( $name, $locked,
        created_by => $opt{created_by}, create_subs => $opt{create_subs} );

    my $all = read_settings();
    $all->{$name}{webdav}         = JSON::PP::true();
    $all->{$name}{manage_themes}  = JSON::PP::true()
        unless defined $opt{themes} && !$opt{themes};
    $all->{$name}{manage_layouts} = JSON::PP::true() if $opt{layouts};
    $all->{$name}{manage_config}  = JSON::PP::true() if $opt{config};
    if ( defined $opt{scope} && length $opt{scope} ) {
        my $sc = normalise_scope( $opt{scope} );
        $all->{$name}{dav_scope} = $sc if defined $sc;
    }
    my $key = _issue_pairing_key( $all, $name );
    write_settings($all);
    log_event( 'INFO', $name, 'partner created', created_by => $opt{created_by} );

    my $brief = _onboarding_brief( $name, $key, $all->{$name} );
    print $brief unless $API_MODE;
    return { username => $name, pairing_key => $key, onboarding => $brief };
}

sub cmd_partner_create_cli {
    my @a = @_;
    my ( @pos, %opt );
    $opt{themes} = 1;   # partner default
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '--by' )          { $opt{created_by}  = shift @a }
        elsif ( $x eq '--themes' )      { $opt{themes}      = 1 }
        elsif ( $x eq '--no-themes' )   { $opt{themes}      = 0 }
        elsif ( $x eq '--layouts' )     { $opt{layouts}     = 1 }
        elsif ( $x eq '--config' )      { $opt{config}      = 1 }
        elsif ( $x eq '--scope' )       { $opt{scope}       = shift @a }
        elsif ( $x eq '--create-subs' ) { $opt{create_subs} = 1 }
        else                            { push @pos, $x }
    }
    cmd_partner_create( $pos[0], %opt );
}

sub parse_onoff {
    my ($v) = @_;
    $v = lc( $v // '' );
    return 1 if $v eq 'on'  || $v eq 'true'  || $v eq '1' || $v eq 'yes';
    return 0 if $v eq 'off' || $v eq 'false' || $v eq '0' || $v eq 'no';
    die "Value must be 'on' or 'off'\n";
}

# Normalise a dav_scope value. Returns undef to mean "clear / unset"
# (empty string or '/'), a normalised site-absolute path otherwise.
sub normalise_scope {
    my ($v) = @_;
    $v //= '';
    $v =~ s/^\s+|\s+$//g;
    return undef if $v eq '' || $v eq '/';
    $v = "/$v" unless $v =~ m{^/};
    $v =~ s{/+}{/}g;
    $v =~ s{/$}{};
    die "Invalid scope path\n"
        if $v =~ m{(?:^|/)\.\.(?:/|$)} || $v =~ /[\0<>"']/;
    return $v;
}

# Would setting ui:off on $user leave no manager-capable account that
# can still log in interactively? $all is the in-progress settings
# hashref (pre-write).
sub is_last_manager_ui {
    my ( $user, $all ) = @_;
    my @mgroups = read_manager_groups();
    my %users   = read_users();
    my %groups  = read_groups();

    my %manager_user;
    if (@mgroups) {
        for my $g (@mgroups) {
            next unless $groups{$g};
            $manager_user{$_} = 1 for @{ $groups{$g} };
        }
    }
    else {
        # Empty manager_groups: any authenticated user has manager access.
        $manager_user{$_} = 1 for keys %users;
    }

    return 0 unless $manager_user{$user};   # target isn't manager-capable

    my $cur = $all->{$user} || {};
    my $cur_ui = ( exists $cur->{ui} && !$cur->{ui} ) ? 0 : 1;
    return 0 unless $cur_ui;                 # already off, no reduction

    for my $u ( keys %manager_user ) {
        next if $u eq $user;
        next unless exists $users{$u};
        my $s  = $all->{$u} || {};
        my $ui = ( exists $s->{ui} && !$s->{ui} ) ? 0 : 1;
        return 0 if $ui;                     # someone else still covers it
    }
    return 1;                                # $user is the last one
}

sub read_manager_groups {
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    return () unless -f $conf;
    open my $fh, '<', $conf or return ();
    my $line;
    while (<$fh>) {
        if (/^manager_groups\s*:\s*(.+)/) { $line = $1; last }
    }
    close $fh;
    return () unless defined $line;
    $line =~ s/^\s+|\s+$//g;
    return grep { length } split /[,\s]+/, $line;
}

# --- File I/O ---

sub read_users {
    my %users;
    return %users unless -f $USERS_FILE;
    open( my $fh, '<:utf8', $USERS_FILE ) or die "Cannot read $USERS_FILE: $!\n";
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $u, $h ) = split /:/, $_, 2;
        $users{$u} = $h if defined $u && defined $h;
    }
    close $fh;
    return %users;
}

sub write_users {
    my (%users) = @_;
    open( my $fh, '>:utf8', $USERS_FILE ) or die "Cannot write $USERS_FILE: $!\n";
    flock( $fh, LOCK_EX );
    for my $u ( sort keys %users ) {
        print $fh "$u:$users{$u}\n";
    }
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0640, $USERS_FILE;
}

sub read_groups {
    my %groups;
    return %groups unless -f $GROUPS_FILE;
    open( my $fh, '<:utf8', $GROUPS_FILE ) or die "Cannot read $GROUPS_FILE: $!\n";
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $g, $members ) = split /:\s*/, $_, 2;
        next unless defined $members;
        $groups{$g} = [ map { s/^\s+|\s+$//gr } split /,/, $members ];
    }
    close $fh;
    return %groups;
}

sub write_groups {
    my (%groups) = @_;
    open( my $fh, '>:utf8', $GROUPS_FILE ) or die "Cannot write $GROUPS_FILE: $!\n";
    flock( $fh, LOCK_EX );
    for my $g ( sort keys %groups ) {
        next unless @{ $groups{$g} };
        print $fh "$g: " . join( ', ', @{ $groups{$g} } ) . "\n";
    }
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0644, $GROUPS_FILE;
}

# SM070: per-user access-mechanism settings, JSON object keyed by
# username. Single writer (this tool), write-temp-then-rename.
# Unparseable content yields defaults (empty) plus a WARN, so a
# corrupt file cannot wedge user management.
sub read_settings {
    require JSON::PP;
    return {} unless -f $SETTINGS_FILE;
    open my $fh, '<:utf8', $SETTINGS_FILE or do {
        log_event( 'WARN', 'settings', 'cannot read user-settings.json', error => "$!" );
        return {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    if ( !$data || ref $data ne 'HASH' ) {
        log_event( 'WARN', 'settings', 'user-settings.json unparseable; using defaults' );
        return {};
    }
    return $data;
}

sub write_settings {
    my ($data) = @_;
    require JSON::PP;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $tmp  = "$SETTINGS_FILE.tmp.$$";
    open my $fh, '>:utf8', $tmp or die "Cannot write $SETTINGS_FILE: $!\n";
    flock( $fh, LOCK_EX );
    print $fh $json;
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0640, $tmp;
    rename $tmp, $SETTINGS_FILE
        or die "Cannot rename settings file into place: $!\n";
}

# --- Logging ---

sub log_event {
    my ($level, $context, $message, %extra) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map  { '"' . _json_str($_) . '":"' . _json_str($extra{$_}) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"'     . _json_str($level)          . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT)  . '"'
            . ',"context":"'   . _json_str($context)        . '"'
            . ',"message":"'   . _json_str($message)        . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

sub usage {
    print <<'USAGE';
lazysite-users.pl - user management for lazysite built-in auth

Usage: perl tools/lazysite-users.pl --docroot PATH COMMAND [ARGS]
       perl tools/lazysite-users.pl --api --docroot PATH < request.json

Commands:
  add USERNAME PASSWORD       Add a new user
  passwd USERNAME NEWPASSWORD Change a user's password
  remove USERNAME             Remove a user (and from all groups)
  list                        List all users
  group-add USERNAME GROUP    Add user to a group
  group-remove USERNAME GROUP Remove user from a group
  groups                      List all groups and members
  settings USERNAME           Show a user's access-mechanism settings
  set USERNAME KEY VALUE      Set a boolean (on/off): webdav, ui,
                              create_sub_users, delegate_sub_user_creation,
                              manage_themes, manage_layouts, manage_config;
                              or dav_scope (/path). (set ui off honours a
                              last-manager guard; pass --force to override)
  token USERNAME              Generate a strong permanent credential (shown once)
  pairing-key USERNAME        Mint a single-use, short-lived pairing key (shown once)
  token-exchange USER KEY     Exchange a pairing key for a fresh access token
  token-rotate USERNAME       Rotate the access token and reset its expiry
  partner-create NAME --by PARENT [--layouts] [--config] [--scope /p] [--no-themes] [--create-subs]
                              Provision an automated partner: sub-user with
                              partner capability defaults (webdav +
                              manage_themes), a pairing key, and a printed
                              onboarding brief.
  account-create USER PASS --by PARENT [--create-subs]
                              Create a sub-user owned by PARENT (records
                              provenance; PARENT needs create_sub_users,
                              and --create-subs needs delegate_sub_user_creation)
  account-disable USER [--cascade] [--actor U]
                              Disable USER (and its sub-tree with --cascade).
                              A disabled account fails authentication.
  account-enable USER [--cascade] [--actor U]
                              Re-enable USER (and its sub-tree with --cascade).
  account-reassign USER --to PARENT [--actor U]
                              Move USER (and its sub-tree) to a new parent.
                              --actor restricts to the actor's own sub-tree
                              (omit for unrestricted operator use).

Options:
  --docroot PATH              Path to web document root (required)
  --api                       JSON API mode (read from stdin, write to stdout)
  --help                      Show this help
USAGE
}
