#!/usr/bin/perl
# SM121: the group-nest command makes one group a member of another, and the
# capability resolver then has the sub-group's members inherit the parent's caps
# (end to end: command writes membership -> caps_for reflects it).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Settings qw(caps_for);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";

sub repo_root { my $d = $FindBin::Bin; $d =~ s{/t/unit/users$}{}; return $d }
sub w         { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; $t }

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d    = tempdir( CLEANUP => 1 );
my $auth = "$d/lazysite/auth";
make_path($auth);
$Lazysite::Auth::Settings::AUTH_DIR = $auth;

# Two groups with distinct caps.
w( "$auth/groups-settings.json",
    encode_json( { editors => { manage_content => 1, label => 'editors' },
            admins => { manage_config => 1, label => 'admins' } } ) );

# Nest editors inside admins (the command under test).
my $r = uapi( $d, { action => 'group-nest', sub => 'editors', parent => 'admins' } );
ok( $r->{ok}, 'group-nest succeeds' ) or diag encode_json($r);
like( slurp("$auth/groups"), qr/^admins:.*\beditors\b/m,
    'editors is recorded as a member of admins' );

# A user in editors now inherits the admin capability too.
uapi( $d, { action => 'add',       username => 'alice', password => 'x' } );
uapi( $d, { action => 'group-add', username => 'alice', group    => 'editors' } );
my $c = caps_for('alice');
ok( $c->{manage_content}, 'alice keeps her own group capability' );
ok( $c->{manage_config},  'alice inherits the parent group capability via the nest' );

# Nesting is idempotent (no duplicate member on the parent's line).
uapi( $d, { action => 'group-nest', sub => 'editors', parent => 'admins' } );
my ($admins_line) = slurp("$auth/groups") =~ /^(admins:.*)$/m;
my @count = ( $admins_line // '' ) =~ /\beditors\b/g;
is( scalar @count, 1, 'nesting the same group twice does not duplicate it' );

# Guard rails.
ok( !uapi( $d, { action => 'group-nest', sub => 'admins', parent => 'admins' } )->{ok},
    'a group cannot be nested inside itself' );
ok( !uapi( $d, { action => 'group-nest', sub => 'ghost', parent => 'admins' } )->{ok},
    'nesting a non-existent group is refused' );

done_testing;
