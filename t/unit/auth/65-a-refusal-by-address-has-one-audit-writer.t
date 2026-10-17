#!/usr/bin/perl
# SM1134 (stacking slices B and C): A REFUSAL BY ADDRESS HAS ONE AUDIT WRITER.
#
# Slice B (SM1139) wrote `address-refused <target>` for a page or a file through
# Lazysite::Auth::AddressAudit, its markers in lazysite/auth/.address-refused.db.
# Slice C (SM1140) wrote the same row for a group and the manager through its own
# marker, logs/.address-refused.json, in another detail spelling. SM1140's filing:
# "The two write the same row (`address-refused <target>`), and should share one
# writer once both land." Now they do: a group refusal and a page refusal for the
# same address in the same hour each write their own row, once, in one shape, and
# the once-an-hour marker for both is the one store.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
local @INC = ( "$root/lib", @INC );

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path( "$lz/auth", "$lz/logs" );
spit( "$lz/lazysite.conf", "trusted_proxies: 127.0.0.1\nmanager_addresses: office\n" );
spit( "$lz/auth/groups", "g-ed: ed\n" );
spit( "$lz/auth/groups-settings.json", encode_json( { 'g-ed' => { ui => 1, addresses => ['office'] } } ) );
spit( "$lz/auth/address-lists.json", encode_json( {
    office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
} ) );

require Lazysite::Auth::Settings;
require Lazysite::Auth::AddressScope;
require Lazysite::Auth::AddressAudit;
no warnings 'once';
$Lazysite::Auth::Settings::AUTH_DIR = "$lz/auth";

my $OUT = '198.51.100.5';
local $ENV{REMOTE_ADDR}          = '127.0.0.1';
local $ENV{HTTP_X_FORWARDED_FOR} = $OUT;

# The page refusal, as every page door writes it (processor, manager API, WebDAV).
my $page = sub {
    Lazysite::Auth::AddressAudit::refused( lazysite_dir => $lz, target => '/rota', address => $OUT,
        reason => 'not-allowed', lists => ['office'], origin => 'web' );
};
# The group refusal, through the real walk every capability gate goes through.
my $group = sub { Lazysite::Auth::Settings::group_closure('g-ed') };

for ( 1 .. 2 ) { $page->(); $group->(); Lazysite::Auth::AddressScope::refuse_manager( $lz, 'manager' ) }

my $log  = slurp("$lz/logs/audit.log");
my @rows = grep { /\| address-refused \|/ } split /\n/, $log;
my %by   = map { ( /\| address-refused \| ([^|]+?) \|/ )[0] => 1 } @rows;
is( scalar( grep { /\| address-refused \| \/rota \| \Q$OUT\E \|/ } @rows ),       1, 'the page refusal is one row' );
is( scalar( grep { /\| address-refused \| group g-ed \| \Q$OUT\E \|/ } @rows ),   1, 'the group refusal is its own row, once' );
is( scalar( grep { /\| address-refused \| manager \| \Q$OUT\E \|/ } @rows ),      1, 'the manager refusal is its own row, once' );
is( scalar @rows, 3, 'and nothing else' ) or diag($log);

# One shape: user | address-refused | target | address | fail | origin | reason; lists NAMES
for my $r (@rows) {
    like( $r, qr/\| address-refused \| [^|]+ \| \Q$OUT\E \| fail \| \w+ \| not-allowed; lists office\z/,
        "one row shape: $r" );
}

# One store of markers: the group's and the manager's markers are the page's.
ok( !-e "$lz/logs/.address-refused.json", 'no second marker file under logs/' );
ok( -e "$lz/auth/.address-refused.db",     'the markers are in the one store' );

# Proof the group's once-an-hour marker IS that store: drop it (and the process memo),
# and the next group refusal writes again; with the store in place it does not.
{
    local %Lazysite::Auth::AddressScope::SEEN_THIS_PROCESS = ();
    $group->();
    is( scalar( () = slurp("$lz/logs/audit.log") =~ /\| address-refused \| group g-ed \|/g ), 1,
        'a fresh process in the same hour writes no second group row' );
    unlink "$lz/auth/.address-refused.db";
    %Lazysite::Auth::AddressScope::SEEN_THIS_PROCESS = ();
    $group->();
    is( scalar( () = slurp("$lz/logs/audit.log") =~ /\| address-refused \| group g-ed \|/g ), 2,
        'with the one store cleared, the group row is written again' );
}

done_testing();
