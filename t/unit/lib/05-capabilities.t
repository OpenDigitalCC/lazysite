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
use Lazysite::Capabilities qw(describe capability_keys channel_keys action_keys action_channel_surface);

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

# --- SM225: the documentation index -----------------------------------------
# Derived from what the site publishes, so the test builds a docroot rather than
# asserting against a curated list. Absent docroot => absent index (the static
# model must still build for the generated doc).
ok( !exists $map->{docs}, 'no docs index without a docroot' );
{
    my $tmp = "$FindBin::Bin/sm225-docs-$$";
    mkdir $tmp or die "mkdir $tmp: $!";
    mkdir "$tmp/docs" or die "mkdir $tmp/docs: $!";
    my %pages = (
        'ai-briefing-publishing.md' =>
            "---\ntitle: AI briefing - publishing\nsubtitle: How a partner publishes.\n---\nbody\n",
        'forms.md'    => "---\ntitle: \"Forms\"\nsubtitle: \"Collecting things.\"\n---\nbody\n",
        'notitle.md'  => "no front matter here\n",
        'ignored.txt' => "not markdown\n",
    );
    for my $f ( sort keys %pages ) {
        open my $fh, '>', "$tmp/docs/$f" or die $!;
        print {$fh} $pages{$f};
        close $fh;
    }
    my $d = describe( caps => {}, docroot => $tmp )->{docs};
    ok( $d, 'docs index present when the docroot has a docs dir' );
    is_deeply( [ map { $_->{path} } @{ $d->{briefings} } ],
        ['/docs/ai-briefing-publishing'], 'briefings grouped separately' );
    is_deeply( [ map { $_->{path} } @{ $d->{reference} } ],
        ['/docs/forms'], 'reference holds the rest; untitled and non-md skipped' );
    is( $d->{reference}[0]{title}, 'Forms', 'quoted title unquoted' );
    is( $d->{reference}[0]{answers}, 'Collecting things.', 'subtitle becomes answers' );
    is( $d->{briefings}[0]{answers}, 'How a partner publishes.', 'briefing subtitle read' );
    ok( length( $d->{note} // '' ), 'index carries a note about reading the briefings' );

    unlink glob("$tmp/docs/*");
    rmdir "$tmp/docs";
    rmdir $tmp;
}
# A docroot with no docs dir must not invent an index.
is( describe( caps => {}, docroot => "$FindBin::Bin/no-such-docroot-$$" )->{docs},
    undef, 'no docs index when the docroot has no docs dir' );

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

# --- SM197: per-action channel surface (drives the manager permission grid) -
{
    my $surf = action_channel_surface();
    ok( $surf->{manage_content}{webdav}, 'manage_content HAS a webdav surface' );
    ok( $surf->{manage_domains}{mcp},    'manage_domains HAS an mcp surface' );
    ok( $surf->{manage_domains}{api},    'manage_domains HAS an api surface' );
    ok( !$surf->{manage_domains}{webdav}, 'manage_domains has NO webdav surface' );
    ok( !$surf->{notifications}{mcp},     'notifications has NO mcp surface' );
    ok( !$surf->{notifications}{webdav},  'notifications has NO webdav surface' );
    ok( $surf->{notifications}{ui},       'notifications HAS a ui surface' );
    ok( !$surf->{feedback}{webdav},       'feedback has NO webdav surface' );
    ok( $surf->{feedback}{mcp},           'feedback HAS an mcp surface' );
    ok( !$surf->{read_submissions}{webdav}, 'read_submissions has NO webdav surface' );

    # Coverage + honesty: every action is present, every named channel is real.
    my %is_chan = map { $_ => 1 } channel_keys();
    for my $a ( action_keys() ) {
        ok( exists $surf->{$a}, "surface map covers action '$a'" );
        for my $c ( keys %{ $surf->{$a} } ) {
            ok( $is_chan{$c}, "surface channel '$c' for '$a' is a real channel" );
        }
    }
}

done_testing();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "cannot read $p: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
