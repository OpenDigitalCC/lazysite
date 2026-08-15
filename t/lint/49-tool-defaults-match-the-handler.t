#!/usr/bin/perl
# SM314: a documented default is a claim about behaviour, so check it.
#
# THE DEFECT THAT PROMPTED THIS. `install_layout` documented itself as installing
# AND activating a layout, with `activate` defaulting to true. SM176 made install
# permanently inert and the default is FALSE. Four wrong statements: two in prose
# an agent reads as instruction, one in a schema field, and one in
# `delete_layout` telling the agent to rely on it.
#
# The consequence was not cosmetic. `delete_layout` sent an agent to install the
# replacement and then delete the old layout, on the stated grounds that
# install_layout had switched them. The switch never happened, so the old layout
# was still active, and deleting the active layout is always refused - leaving
# the agent holding a refusal that contradicted the instruction which produced
# it. An agent that trusted the description instead reported a restyle as
# complete on a site still serving the old layout.
#
# WHY THIS CLASS IS WORSE THAN DOCUMENTATION DRIFT. A tool description is
# machine-read by the caller and is the ONLY contract an agent has. There is no
# second source to compare it against at runtime, and no human reviews it between
# `tools/list` and the call. It is a stronger claim than a reference document,
# and until now it was the least checked.
#
# The project already built this answer twice for weaker claims: t/lint/36 pins a
# reference document against its source, and t/lint/45 asserts every field ADR
# 0008 freezes is actually read. The pattern was established; it had simply never
# been pointed at the tool surface. NINE descriptions state a default.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
ok( -f $mcp, 'the MCP surface is present' ) or do { done_testing; exit };

my $src = do {
    open my $fh, '<', $mcp or die $!;
    local $/;
    <$fh>;
};

# Every `description => '...'` that states a default, with the value it claims.
# Single-quoted Perl strings, so \' is the only escape to honour.
my @claims;
while ( $src =~ /description\s*=>\s*'((?:[^'\\]|\\.)*)'/g ) {
    my $d    = $1;
    my $line = ( substr( $src, 0, pos($src) ) =~ tr/\n// ) + 1;
    while ( $d =~ /\(default\s+([^)]+)\)/g ) {
        push @claims, { line => $line, value => $1, text => $d };
    }
}

cmp_ok( scalar @claims, '>=', 5,
    'found the tool descriptions that state a default' );

subtest 'a stated boolean default matches what the handler applies' => sub {
    # Booleans are the ones that bite, because a wrong boolean default does not
    # error - it silently does the other thing. `activate` is the worked example:
    # the description said true, the handler applies false, and an agent that
    # believed either one was wrong about what its call had done.
    my @bad;
    for my $c (@claims) {
        my $v = lc $c->{value};
        $v =~ s/\A\s+|\s+\z//g;
        next unless $v eq 'true' || $v eq 'false';

        # The handler's default for a declared boolean in this codebase is
        # ALWAYS false: the argument is passed through only when the caller sent
        # it, and the receiving code tests truth. So a description claiming
        # `default true` is claiming something no handler here implements.
        push @bad, "line $c->{line}: claims (default $c->{value})"
            if $v eq 'true';
    }

    is_deeply( \@bad, [],
        'no description claims a boolean default of true' )
        or diag( join "\n  ",
        '',
        @bad,
        '',
        'Every optional boolean here reaches its handler only when the caller',
        'passes it, and the handler tests truth - so the effective default is',
        'false. A description claiming true is describing behaviour that does',
        'not exist, to the one reader who cannot check: the agent.' );
};

subtest 'install_layout says what SM176 actually decided' => sub {
    # The specific instance, pinned. SM176's decision - that installing never
    # activates, because activating is the part that changes what visitors see -
    # is a deliberate safety property, and a description that contradicts it
    # undoes the protection for every agent that believes it.
    my ($install)
        = $src =~ /install_layout\s*=>\s*\{\s*description\s*=>\s*'((?:[^'\\]|\\.)*)'/;
    ok( $install, 'install_layout has a description' ) or return;

    unlike( $install, qr/then activate it/i,
        'it does not claim to activate' );
    unlike( $install, qr/install \+ activate in one step/i,
        'it does not claim to be the whole switch' );
    like( $install, qr/does NOT activate/i,
        'it states plainly that installing does not activate' );
    like( $install, qr/activate_layout/,
        'and names the tool that does' );

    my ($del)
        = $src =~ /delete_layout\s*=>\s*\{\s*description\s*=>\s*'((?:[^'\\]|\\.)*)'/;
    ok( $del, 'delete_layout has a description' ) or return;
    unlike( $del, qr/install_layout does both/i,
        'delete_layout no longer sends the agent down the always-refused path' )
        or diag( 'It recommends install, then delete, on the grounds that '
            . 'install activated. It did not, so the old layout is still '
            . 'active, and deleting the active layout is always refused.' );
    like( $del, qr/activate_layout/,
        'and names the activation step its sequence actually needs' );
};

subtest 'a schema default is stated where the caller reads it' => sub {
    # The `activate` property is the one that was wrong, and the check that it
    # now says false is worth keeping specifically: this is the field a cautious
    # agent reads BEFORE deciding whether the call is safe, and the reporter of
    # SM314 passed activate:false as a precaution against a hazard that did not
    # exist. The documentation cost a wrong belief in both directions.
    like( $src, qr/'activate after install \(default false\)'/,
        'install_layout.activate documents the real default' );
};

done_testing();
