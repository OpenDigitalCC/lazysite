#!/usr/bin/perl
# SM1341 (ruling 80): THE AI DOCS SAY EACH THING ONCE, AND SAY WHO THEY ARE FOR.
#
# An owner following the docs from "let an AI agent run your website" met the
# connect steps three times (the site's guide, Onboard an AI agent, Connect an AI
# assistant), authentication and the grant model twice (the publishing briefing
# and the tools reference, 8,400 words between them), and the layouts machinery
# on two pages that did not link each other. Only the briefings said who they
# were for. The fix was to give each topic one home and point at it, which holds
# only while nobody writes the steps back into a second page - so:
#
#   - the connect steps (the client's own menus) are in ai-connector-setup only;
#   - endpoints, connection modes and authentication, the pairing-key exchange
#     with them, are in ai-connector-setup only (the onboarding-brief template is
#     the brief itself, which carries the exchange); capabilities and denied paths
#     are in ai-connector-tools (rulings 113, 115);
#   - the publishing briefing has no Authentication, Endpoints, Connection modes
#     or Scope section of its own, and points at each one's home;
#   - the two layouts pages link each other;
#   - the index is by reader, and lists the Figma integration;
#   - every page of the set opens with "Who this is for".
#
# The field-practice briefing is generated (lint 89) and opens with "What this
# is, and what it is not"; it is not in the set.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $DOCS = repo_root() . '/starter/lazysite/templates/docs';

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', "$DOCS/$f" or die "cannot read $f: $!\n";
    local $/;
    return scalar <$fh>;
}

my @manual;
my @queue = ('');
while ( defined( my $dir = shift @queue ) ) {
    opendir my $dh, "$DOCS/$dir" or die "$dir: $!";
    for my $e ( sort readdir $dh ) {
        next if $e =~ /\A\./;
        my $rel = length $dir ? "$dir/$e" : $e;
        if ( -d "$DOCS/$rel" ) { push @queue, $rel; next }
        push @manual, $rel if $e =~ /\.md\z/;
    }
    closedir $dh;
}
cmp_ok( scalar @manual, '>', 70, 'the whole manual was read' );

sub pages_saying {
    my ($re) = @_;
    return [ grep { slurp($_) =~ $re } @manual ];
}

subtest 'the connect steps are on one page' => sub {
    for my $step ( 'Add custom connector', 'Developer mode', 'CIMD' ) {
        is_deeply( pages_saying(qr/\Q$step\E/), ['ai-connector-setup.md'], "'$step' is in ai-connector-setup only" );
    }
    my $onboard = slurp('onboard-ai-agent.md');
    like( $onboard, qr{\]\(/docs/ai-connector-setup\)}, 'Onboard an AI agent links there for the steps' );
    unlike( $onboard, qr/Settings\s*→/, 'and names no client menu itself' );
};

# Rulings 113 + 115: connecting and authenticating live in ai-connector-setup, which
# is public so a client can read it before it holds a credential; the grant model and
# the tools stay in the signed-in tools reference.
subtest 'connecting is in the setup page, the grant model in the tools reference' => sub {
    is_deeply( pages_saying(qr/action=exchange/), [ 'ai-connector-setup.md', 'onboarding-brief-template.md' ],
        'the pairing-key exchange is explained in the setup page (and carried by the brief)' );
    for my $h ( 'Endpoints', 'Connection modes' ) {
        is_deeply( pages_saying(qr/^## \Q$h\E$/m), ['ai-connector-setup.md'], "$h has one home, the setup page" );
    }
    # "## Authentication" also heads the site sign-in material (configuration,
    # auth, SMTP); the connector's is the one beside the pairing key.
    is_deeply( pages_saying(qr/^## Authentication\n.*^### The pairing key/ms), ['ai-connector-setup.md'],
        'the connector\'s Authentication has one home, the setup page' );
    my $tools = slurp('ai-connector-tools.md');
    like( $tools, qr/^## $_$/m, "the tools reference has $_" ) for ( 'Capabilities', 'Scope and denied paths' );
    like( $tools, qr{\(/docs/ai-connector-setup#$_\)}, "and points at the setup page's #$_" )
        for qw(endpoints connectionmodes authentication);
    my $pub = slurp('ai-briefing-publishing.md');
    unlike( $pub, qr/^## $_$/m, "the publishing briefing has no $_ section" ) for ( 'Endpoints', 'Authentication',
        'Connection modes', 'Scope and denied paths' );
    like( $pub, qr{\(/docs/ai-connector-setup#$_\)}, "and points at the setup page's #$_" )
        for qw(endpoints connectionmodes authentication);
    like( $pub, qr{\(/docs/ai-connector-tools#$_\)}, "and at the tools reference's #$_" )
        for qw(capabilities scopeanddeniedpaths);
};

subtest 'the setup page is public and carries placeholders only' => sub {
    my ($fm) = slurp('ai-connector-setup.md') =~ /\A---\n(.*?)^---\n/ms;
    unlike( $fm // '', qr/^auth\s*:/m, 'ai-connector-setup sets no auth: it is public' );
    my ($tfm) = slurp('ai-connector-tools.md') =~ /\A---\n(.*?)^---\n/ms;
    like( $tfm // '', qr/^auth:\s*required\s*$/m, 'ai-connector-tools stays signed-in' );

    my $setup = slurp('ai-connector-setup.md');
    my @hosts = $setup =~ m{https?://([^/\s)`"]+)}g;
    cmp_ok( scalar @hosts, '>', 4, 'the endpoint addresses were read' );
    is_deeply( [ grep { $_ ne 'YOUR-SITE' } @hosts ], [], 'every address on it is YOUR-SITE' );
    my @creds = $setup =~ /\b(lz[sp]_[A-Za-z0-9]+)/g;
    is_deeply( \@creds, [], 'and no lzs_ / lzp_ value, only the prefixes' );
};

subtest 'the two layouts pages link each other' => sub {
    like( slurp('layouts.md'),             qr{\]\(/docs/ai-briefing-layouts[)#]}, 'layouts links the briefing' );
    like( slurp('ai-briefing-layouts.md'), qr{\]\(/docs/layouts[)#]},             'the briefing links layouts' );
    is_deeply( pages_saying(qr/^## Minimum layout\.tt$/m), ['ai-briefing-layouts.md'], 'one minimum layout.tt' );
};

subtest 'the index is by reader and lists the Figma integration' => sub {
    my $idx = slurp('index.md');
    my @readers = $idx =~ /^## (.+?): (?:the operator|an AI agent|a developer)$/mg;
    is( scalar @readers, 3, 'three reader sections: the operator, an AI agent, a developer' );
    like( $idx, qr{\]\(/docs/integrations/figma\)}, 'it lists integrations/figma' );
};

subtest 'every page of the set opens with who it is for' => sub {
    my @set = (
        qw(index.md onboard-ai-agent.md ai-connector-setup.md ai-connector-tools.md layouts.md
            integrations/index.md integrations/figma.md),
        grep { m{\Aai-briefing-} && $_ ne 'ai-briefing-practice.md' } @manual
    );
    for my $p (@set) {
        my $body = slurp($p);
        $body =~ s/\A---\n.*?^---\n//ms;
        my ($first) = $body =~ /^(#{1,6} .+)$/m;
        is( $first, '## Who this is for', "$p opens with Who this is for" );
    }
};

done_testing();
