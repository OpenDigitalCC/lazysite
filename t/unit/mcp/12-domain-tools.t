#!/usr/bin/perl
# SM238: the MCP surface had NO domain tools beyond site_backup/site_apply, while
# the control API carried the whole domain family under the SAME manage_domains
# capability. So an agent asked to style a secondary domain could reach only the
# INSTANCE-WIDE activate_theme/activate_layout, which would have restyled every
# other site on the instance. It refused to act and reported the gap - the right
# call, and the situation was backwards: the safe scoped operation was the
# missing one.
#
# These tests pin the shape of the fix rather than re-testing Domains.pm:
#   - the three tools exist, are gated by manage_domains, and are declared in
#     the capability map (so an agent can DISCOVER them);
#   - activate_theme/activate_layout take an optional host and say plainly what
#     omitting it does - the description is the safety mechanism here;
#   - the destructive domain verbs are deliberately NOT exposed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root);
use Lazysite::Capabilities qw(describe);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
    local $/;
    <$fh>;
};

# A tool block runs from its name to the NEXT tool name at the same indent.
# (A non-greedy match to the first "    }," stops inside inputSchema and silently
# truncates the block before `run => sub`, which makes every assertion about the
# run body vacuously fail - or worse, vacuously pass.)
sub tool_block {
    my ($name) = @_;
    my ($b) = $src =~ /^    \Q$name\E\s*=>\s*\{(.*?)(?=^    [a-z_]+\s*=>\s*\{|^\);)/ms;
    return $b;
}

# --- the tools exist and are gated -------------------------------------------
for my $t (qw(list_domains domain_set preview_domain)) {
    like( $src, qr/^\s+\Q$t\E\s*=>\s*\{/m, "$t is a real MCP tool" );
}
# Each must sit under manage_domains - the same capability the control-API twins
# use, so this adds a channel and not a privilege.
for my $t (qw(list_domains domain_set preview_domain)) {
    my $block = tool_block($t);
    ok( defined $block, "$t block located" );
    like( $block, qr/cap\s*=>\s*'manage_domains'/, "$t is gated by manage_domains" );
}

# --- discoverable from the capability map ------------------------------------
{
    my $map = describe();
    my $mcp = $map->{capabilities}{manage_domains}{unlocks}{mcp} || [];
    my %have = map { $_ => 1 } @$mcp;
    ok( $have{$_}, "capability map advertises $_" )
        for qw(list_domains domain_set preview_domain);
}

# --- the destructive verbs stay off the connector ----------------------------
# Creating or removing a domain has DNS and certificate consequences beyond this
# instance; those remain a deliberate operator act.
for my $t (qw(domain_add domain_remove delete_domain)) {
    unlike( $src, qr/^\s+\Q$t\E\s*=>\s*\{/m, "$t is NOT exposed over MCP" );
}

# --- host makes the instance-wide tools scoped -------------------------------
{
    my $theme = tool_block('activate_theme');
    ok( defined $theme, 'activate_theme block located' );
    like( $theme, qr/host\s*=>\s*\{\s*type\s*=>\s*'string'/,
        'activate_theme accepts an optional host' );
    like( $theme, qr/INSTANCE-WIDE/,
        'and its description SAYS so, which is the actual safety mechanism' );
    like( $theme, qr/_domain_presentation_set/,
        'a host routes through the per-domain binding, not the site-wide pointer' );

    my $lay = tool_block('activate_layout');
    ok( defined $lay, 'activate_layout block located' );
    like( $lay, qr/host\s*=>\s*\{\s*type\s*=>\s*'string'/,
        'activate_layout accepts an optional host' );
    like( $lay, qr/INSTANCE-WIDE/, 'and says what omitting it does' );
}

# --- the binding helper cannot touch the site-wide keys ----------------------
{
    my ($helper) = $src =~ /(sub _domain_presentation_set.*?^\})/ms;
    ok( defined $helper, 'the binding helper is defined' );
    like( $helper, qr/Domains::domain_set/,
        'it routes through domain_set - so it inherits the SM241 asset mirroring' );
    unlike( $helper, qr/_set_theme_pointer|action_theme_activate|action_layout_activate/,
        'and never reaches for an instance-wide activation' );
}

# --- content_root is refused, with a reason ----------------------------------
{
    my $block = tool_block('domain_set');
    like( $block, qr/content_root cannot be set/,
        'domain_set refuses content_root - repointing content is a migration' );
    like( $block, qr/site_apply/, 'and names the tool that does it safely' );
}

done_testing();
