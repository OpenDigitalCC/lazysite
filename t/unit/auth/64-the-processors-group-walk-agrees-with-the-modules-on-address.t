#!/usr/bin/perl
# SM1140 (slice C of SM1134): THE PROCESSOR'S COPY OF THE GROUP WALK AND THE MODULE'S
# ANSWER THE SAME QUESTION THE SAME WAY, WITH A GROUP'S ADDRESS LIMIT IN FORCE.
#
# A request's groups are resolved in one place per side: Auth::Settings::_group_closure
# for everything that loads the library, and lazysite-processor/acl.pm's `_group_closure`
# for the render path, which loads no Lazysite:: module up front (ADR 0001). A group
# whose address list refuses the visitor is left out of the walk, and nothing is reached
# through it. If the two copies drifted, the page gate and the capability gates would
# disagree about who is in a group - the defect SM1129 and SM1135 each pinned for their
# own copy. The processor's functions are lifted out of the source by name and run
# against the same stores and the same request as the module.
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

# The sub, whole, by name (it ends at the first closing brace in column 0).
sub lift {
    my ( $src, $name ) = @_;
    my ($body) = $src =~ /^(sub \Q$name\E\b.*?^\})/ms or die "no sub $name";
    return $body;
}

open my $sf, '<', "$root/lazysite-processor/acl.pm" or die $!;
my $src = do { local $/; <$sf> };
close $sf;
my $code = join "\n", map { lift( $src, $_ ) } qw(_group_settings _group_membership_map _group_closure);
{
    package ProcCopy;
    our $LAZYSITE_DIR;
    sub _lazy_lib { ( my $f = $_[0] ) =~ s{::}{/}g; require "$f.pm"; 1 }
}
## no critic (ProhibitStringyEval)
eval "package ProcCopy; use strict; use warnings; our \$LAZYSITE_DIR; $code; 1" or die "lifting the processor's walk: $@";

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path("$lz/auth");
spit( "$lz/lazysite.conf", "trusted_proxies: 127.0.0.1\n" );
# kid -> par (limited); kid2 (limited) -> par2; solo (limited); open -> par3
spit( "$lz/auth/groups", join "\n",
    'par: kid', 'par2: kid2', 'par3: open', 'plain: x', '' );
spit( "$lz/auth/groups-settings.json", encode_json( {
    par   => { ui => 1, addresses      => ['office'] },
    par2  => { ui => 1 },
    kid2  => { addresses_deny => ['blocked'], addresses => ['office'] },
    kid   => {},
    solo  => { addresses => ['office'] },
    par3  => { ui => 1 },
    open  => {},
    plain => {},
} ) );
spit( "$lz/auth/address-lists.json", encode_json( {
    office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} ) );

require Lazysite::Auth::Settings;
no warnings 'once';
$ProcCopy::LAZYSITE_DIR = $lz;
$Lazysite::Auth::Settings::AUTH_DIR = "$lz/auth";

my @seeds = ( ['kid'], ['kid2'], ['solo'], ['open'], ['plain'], [ 'kid', 'open' ], ['par'], [], ['nosuch'] );

for my $case ( [ 'inside', '203.0.113.5' ], [ 'outside', '198.51.100.5' ], [ 'inside but denied', '203.0.113.9' ] ) {
    my ( $label, $ip ) = @$case;
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = $ip;
    for my $seed (@seeds) {
        my @mod  = sort( Lazysite::Auth::Settings::group_closure(@$seed) );
        my @proc = sort( ProcCopy::_group_closure(@$seed) );
        is_deeply( \@proc, \@mod, "$label: [@$seed] -> the processor's walk is the module's [@mod]" );
    }
}

# And the answer is the limit, not an accident of the fixture.
{
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = '203.0.113.5';
    is_deeply( [ sort( ProcCopy::_group_closure('kid') ) ], [ 'kid', 'par' ], 'inside: kid inherits par' );
    is_deeply( [ sort( ProcCopy::_group_closure('kid2') ) ], [ 'kid2', 'par2' ], 'inside: kid2 inherits par2' );
    $ENV{HTTP_X_FORWARDED_FOR} = '198.51.100.5';
    is_deeply( [ sort( ProcCopy::_group_closure('kid') ) ], ['kid'], 'outside: par is left out, kid keeps itself' );
    is_deeply( [ sort( ProcCopy::_group_closure('kid2') ) ], [], 'outside: kid2 is left out and par2 is not reached through it' );
    is_deeply( [ sort( ProcCopy::_group_closure( 'kid', 'open' ) ) ], [ 'kid', 'open', 'par3' ], 'outside: unlimited groups are untouched' );
}

# No request, no address to test: the walk is whole (the users tool, the build tools).
{
    local %ENV = %ENV;
    delete @ENV{qw(REMOTE_ADDR REQUEST_METHOD HTTP_X_FORWARDED_FOR)};
    is_deeply( [ sort( ProcCopy::_group_closure('kid2') ) ], [ 'kid2', 'par2' ], 'outside a request the limit is not applied (processor)' );
    is_deeply( [ sort( Lazysite::Auth::Settings::group_closure('kid2') ) ], [ 'kid2', 'par2' ], 'outside a request the limit is not applied (module)' );
}

# The users tool manages the stores: it switches the rules off even if it inherited a request.
{
    local $ENV{REMOTE_ADDR}          = '127.0.0.1';
    local $ENV{HTTP_X_FORWARDED_FOR} = '198.51.100.5';
    local $Lazysite::Auth::Settings::ADDRESS_RULES = 0;
    is_deeply( [ sort( Lazysite::Auth::Settings::group_closure('kid2') ) ], [ 'kid2', 'par2' ], 'ADDRESS_RULES = 0 reads the structure whole' );
}

done_testing();
