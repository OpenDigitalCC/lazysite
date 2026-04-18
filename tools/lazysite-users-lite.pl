#!/usr/bin/perl
# lazysite-users-lite.pl - user management for lazysite built-in auth
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Path qw(make_path);

my $DOCROOT;
my @args;

# Parse --docroot
while (@ARGV) {
    my $arg = shift @ARGV;
    if ( $arg eq '--docroot' ) {
        $DOCROOT = shift @ARGV;
    }
    elsif ( $arg eq '--help' ) {
        usage();
        exit 0;
    }
    else {
        push @args, $arg;
    }
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
    die "Usage: add USERNAME PASSWORD\n" unless $user && $pass;
    $user =~ s/[^a-zA-Z0-9_.-]//g;

    my %users = read_users();
    die "User '$user' already exists\n" if $users{$user};

    $users{$user} = sha256_hex($pass);
    write_users(%users);
    print "User '$user' added.\n";
}

sub cmd_passwd {
    my ( $user, $pass ) = @_;
    die "Usage: passwd USERNAME NEWPASSWORD\n" unless $user && $pass;

    my %users = read_users();
    die "User '$user' not found\n" unless $users{$user};

    $users{$user} = sha256_hex($pass);
    write_users(%users);
    print "Password updated for '$user'.\n";
}

sub cmd_remove {
    my ($user) = @_;
    die "Usage: remove USERNAME\n" unless $user;

    my %users = read_users();
    die "User '$user' not found\n" unless delete $users{$user};

    write_users(%users);

    # Also remove from all groups
    if ( -f $GROUPS_FILE ) {
        my %groups = read_groups();
        for my $g ( keys %groups ) {
            $groups{$g} = [ grep { $_ ne $user } @{ $groups{$g} } ];
        }
        write_groups(%groups);
    }

    print "User '$user' removed.\n";
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
    die "Usage: group-add USERNAME GROUPNAME\n" unless $user && $group;

    my %users = read_users();
    die "User '$user' not found\n" unless $users{$user};

    my %groups = read_groups();
    $groups{$group} //= [];
    unless ( grep { $_ eq $user } @{ $groups{$group} } ) {
        push @{ $groups{$group} }, $user;
    }
    write_groups(%groups);
    print "User '$user' added to group '$group'.\n";
}

sub cmd_group_remove {
    my ( $user, $group ) = @_;
    die "Usage: group-remove USERNAME GROUPNAME\n" unless $user && $group;

    my %groups = read_groups();
    die "Group '$group' not found\n" unless $groups{$group};

    $groups{$group} = [ grep { $_ ne $user } @{ $groups{$group} } ];
    write_groups(%groups);
    print "User '$user' removed from group '$group'.\n";
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

sub usage {
    print <<'USAGE';
lazysite-users-lite.pl - user management for lazysite built-in auth

Usage: perl tools/lazysite-users-lite.pl --docroot PATH COMMAND [ARGS]

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
  --help                      Show this help
USAGE
}
