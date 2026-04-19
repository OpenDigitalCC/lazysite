#!/usr/bin/perl
# lazysite-users.pl - user management for lazysite built-in auth
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Path qw(make_path);

my $LOG_COMPONENT = 'users';

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
make_path($AUTH_DIR) unless -d $AUTH_DIR;
chmod 0750, $AUTH_DIR;

my $USERS_FILE  = "$AUTH_DIR/users";
my $GROUPS_FILE = "$AUTH_DIR/groups";

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
else {
    print STDERR "Unknown command: $cmd\n\n" if $cmd;
    usage();
    exit 1;
}

# --- Commands ---

sub cmd_add {
    my ( $user, $pass ) = @_;
    die "Username and password required\n" unless $user && $pass;
    $user =~ s/[^a-zA-Z0-9_.-]//g;

    my %users = read_users();
    die "User '$user' already exists\n" if $users{$user};

    $users{$user} = sha256_hex($pass);
    write_users(%users);
    log_event('INFO', $user, 'user added');
    print "User '$user' added.\n" unless $API_MODE;
}

sub cmd_passwd {
    my ( $user, $pass ) = @_;
    die "Username and password required\n" unless $user && $pass;

    my %users = read_users();
    die "User '$user' not found\n" unless $users{$user};

    $users{$user} = sha256_hex($pass);
    write_users(%users);
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

Options:
  --docroot PATH              Path to web document root (required)
  --api                       JSON API mode (read from stdin, write to stdout)
  --help                      Show this help
USAGE
}
