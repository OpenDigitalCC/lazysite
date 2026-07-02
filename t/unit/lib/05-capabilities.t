#!/usr/bin/perl
# SM126: the capability-map builder (Lazysite::Capabilities). Two things matter:
# the structure is what an agent expects, and the curated tool/action names in
# the map do not drift from the real MCP tools and control-API actions.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";      # t/lib
use lib "$FindBin::Bin/../../../lib";   # repo lib
use TestHelper qw(repo_root);
use Lazysite::Capabilities qw(describe capability_keys channel_keys action_keys);

my $root = repo_root();

# --- Structure --------------------------------------------------------------
my $map = describe( caps => { api => 1, manage_themes => 1, mcp => 0 },
                    account => 'p', groups => ['role-p'] );

my @ch = channel_keys();
is_deeply( [ sort @ch ], [qw(api mcp ui webdav)], 'four channels' );
ok( $map->{channels}{api}{enforced}, 'api channel reports enforced' );
ok( $map->{channels}{$_}{enforced}, "$_ channel enforced" ) for channel_keys();

for my $a ( action_keys() ) {
    ok( exists $map->{capabilities}{$a}, "capability map covers action $a" );
    ok( length( $map->{capabilities}{$a}{title} // '' ), "$a has a title" );
}

ok( @{ $map->{tasks} } >= 3, 'task recipes present' );
ok( @{ $map->{engine_owned} } >= 3, 'engine-owned boundary present' );

# holds reflects the caller's grant
ok(  $map->{holds}{capabilities}{manage_themes}, 'holds shows a granted cap true' );
ok( !$map->{holds}{capabilities}{mcp},           'holds shows an ungranted cap false' );
is( $map->{holds}{account}, 'p', 'holds carries the account' );
# every @CAP_KEYS key is present under holds (no drift - this is what the old
# whoami block got wrong by omitting delegate_sub_user_creation)
ok( exists $map->{holds}{capabilities}{$_}, "holds includes $_" ) for capability_keys();
ok( exists $map->{holds}{capabilities}{delegate_sub_user_creation},
    'holds includes delegate_sub_user_creation (the previously-dropped key)' );

# Static form (no caps) omits holds
my $static = describe();
ok( !exists $static->{holds}, 'static map (no caps) omits holds' );

# --- Consistency: named tools/actions must really exist ---------------------
my $mcp_src = slurp("$root/lazysite-mcp.pl");
my $api_src = slurp("$root/lazysite-manager-api.pl");

my ( %mcp_named, %api_named );
for my $a ( action_keys() ) {
    my $u = $map->{capabilities}{$a}{unlocks} || {};
    $mcp_named{$_} = $a for @{ $u->{mcp} || [] };
    $api_named{$_} = $a for @{ $u->{api} || [] };
}

for my $tool ( sort keys %mcp_named ) {
    like( $mcp_src, qr/^\s+\Q$tool\E\s*=>\s*\{/m,
        "map's MCP tool '$tool' (for $mcp_named{$tool}) is a real \%TOOLS entry" );
}
for my $act ( sort keys %api_named ) {
    like( $api_src, qr/'\Q$act\E'/,
        "map's control-API action '$act' (for $api_named{$act}) exists in the API" );
}

# describe_capabilities itself is a real MCP tool and control-API action.
like( $mcp_src, qr/^\s+describe_capabilities\s*=>\s*\{/m, 'describe_capabilities is an MCP tool' );
like( $api_src, qr/'describe-capabilities'/, 'describe-capabilities is a control-API action' );

done_testing();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "cannot read $p: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
