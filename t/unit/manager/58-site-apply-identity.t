#!/usr/bin/perl
# SM263: applying a site package keeps the TARGET's identity unless asked
# otherwise, on every channel.
#
# SM193 set that default in SitePackage::apply_and_configure, so MCP and the CLI
# already got the safe behaviour by inheriting it - the gap was that neither
# could OPT IN. That distinction matters and the original audit row blurred it:
# it read as though those channels were stamping the source's site_url onto the
# target, which they were not.
#
# The default is the migrate case (a package moved onto a new domain must not
# advertise the source's address); adopt_identity is the clone-and-hand-over
# case, where the package IS the site.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

# --- the default lives in ONE place ----------------------------------------
# Three callers, one rule. If this moves into the callers, they can disagree -
# which is what SM255 spent a release undoing for the conf writers.
{
    my $sp = slurp("$root/lib/Lazysite/Manager/SitePackage.pm");
    like( $sp, qr/unless \( \$opt\{adopt_identity\} \)/,
        'SitePackage holds the identity rule' );
    like( $sp, qr/delete \@\{\$keys\}\{qw\(site_url site_name\)\}/,
        'and keeping the target identity means dropping those two keys' );
}

# --- every channel can ask for the other behaviour --------------------------
{
    my $api = slurp("$root/lazysite-manager-api.pl");
    like( $api, qr/adopt_identity => \( \$req->\{adopt_identity\} \? 1 : 0 \)/,
        'the control API passes adopt_identity (SM193)' );

    my $mcp = slurp("$root/lazysite-mcp.pl");
    like( $mcp, qr/adopt_identity => \{ type => 'boolean'/,
        'the MCP tool DECLARES adopt_identity' );
    like( $mcp, qr/adopt_identity => \( \$a->\{adopt_identity\} \? 1 : 0 \)/,
        'and passes it through' );

    my $cli = slurp("$root/tools/lazysite-site.pl");
    like( $cli, qr/adopt_identity => \( exists \$opt\{'adopt-source-identity'\} \? 1 : 0 \)/,
        'the CLI passes --adopt-source-identity' );
    # A flag that is not registered as a flag swallows the NEXT argument, which
    # is a quiet and confusing failure - the parser here is hand-rolled.
    like( $cli, qr/\$k eq 'adopt-source-identity'/,
        'and registers it as a FLAG, so it does not eat the following argument' );
}

# --- the MCP description states the default, not just the option -----------
# An agent choosing between two behaviours needs to know which it gets by doing
# nothing.
{
    my $mcp = slurp("$root/lazysite-mcp.pl");
    my ($desc) = $mcp =~ /adopt_identity => \{ type => 'boolean',\s*\n\s*description => "([^"]+)"/;
    ok( defined $desc, 'the adopt_identity description is present' );
    like( $desc, qr/Default false/, 'it states the default' );
    like( $desc, qr/target keeps its identity/i, 'and what the default MEANS' );
}

done_testing();
