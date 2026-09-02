#!/usr/bin/perl
# SM728: what a control DOES is declared, so rules about it can be checked.
#
# WHY THIS LINT COULD NOT EXIST BEFORE. The style guide has said "steel
# confirms, copper changes, red destroys" since SM-DS1, and "a destructive
# action must ALSO be confirmed - the colour is a warning, not the guard". Both
# were unenforceable, for the same reason: nothing enumerated what an action
# does. `data-impact` is that subject, so the rules below can finally be asked.
#
# A RATCHET, NOT A WALL. 234 buttons predate the declaration. Converting them in
# one change would be a wide, untestable UI edit of exactly the shape that
# produced ninety-five review items last time. So each page carries a ceiling of
# UNDECLARED controls: it may fall, never rise. A new control declares itself or
# this fails, while the backlog is paid down page by page.
#
# The same treatment t/lint/95 gave unstyled classes and t/lint/108 gave inline
# styles, and for the same reason - both of those held, where the two expander
# idioms drifted because nothing counted them.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my %VALID = map { $_ => 1 } qw(commit change edit destroy retrieve inert);

# The appearance each impact owns. A control declaring one impact must not wear
# another's class: the declaration and the look would then disagree, which is
# the whole thing the attribute exists to prevent.
my %CLASS_OF = (
    commit   => 'mg-btn-primary',
    change   => 'mg-btn-change',
    destroy  => 'mg-btn-danger',
    retrieve => 'mg-btn-copy',
);

# Undeclared controls per page, as they stand. LOWER IS THE ONLY DIRECTION.
my %CEILING = (
    'appearance.md' => 17,     'audit.md' => 4,          'backups.md' => 12,
    'cache.md' => 3,           'config.md' => 4,         'data.md' => 25,
    'domains.md' => 13,        'edit.md' => 7,           'files.md' => 27,
    'groups.md' => 6,          'index.md' => 0,          'nav.md' => 9,
    'plugin-config.md' => 30,  'plugins.md' => 0,        'sessions.md' => 0,
    'stats.md' => 2,           'themes.md' => 0,         'users.md' => 36,
);

my @pages = sort glob("$root/starter/manager/*.md");
cmp_ok( scalar @pages, '>=', 15, 'the manager pages are present' );

my ($declared_total, $undeclared_total) = (0, 0);

for my $f (@pages) {
    ( my $n = $f ) =~ s{.*/}{};
    next if $n eq 'style-guide.md';    # the guide demonstrates, it does not act
    open my $fh, '<', $f or do { fail("$n: unreadable"); next };
    my $c = do { local $/; <$fh> };
    close $fh;

    my ($undeclared, @bad_value, @bad_class) = (0);
    while ( $c =~ /<button\b([^>]*\bmg-btn\b[^>]*)>/g ) {
        my $attrs = $1;
        if ( $attrs =~ /data-impact=\\?["']?([a-z]+)/ ) {
            my $imp = $1;
            $declared_total++;
            push @bad_value, $imp unless $VALID{$imp};
            # Declared one impact, wearing another's clothes.
            for my $other ( keys %CLASS_OF ) {
                next if $other eq $imp;
                push @bad_class, "$imp wears $CLASS_OF{$other}"
                    if $attrs =~ /\Q$CLASS_OF{$other}\E/;
            }
        }
        else { $undeclared++; $undeclared_total++ }
    }

    is( scalar @bad_value, 0, "$n: every declared impact is in the vocabulary" )
        or diag( "not in [" . join( '|', sort keys %VALID ) . "]: @bad_value" );
    is( scalar @bad_class, 0, "$n: a declared impact does not wear another's class" )
        or diag( join( '; ', @bad_class ) );

    my $ceil = $CEILING{$n};
    if ( defined $ceil ) {
        cmp_ok( $undeclared, '<=', $ceil,
            "$n: undeclared controls $undeclared <= ceiling $ceil" )
            or diag( "A NEW control must declare data-impact. If you have "
                . "converted some, LOWER the ceiling in this file to $undeclared." );
    }
    else {
        is( $undeclared, 0,
            "$n: a page with no ceiling declares every control" );
    }
}

# SM726 and SM728 meet here: a control that changes what will be saved must say
# so, or the dirty note it is supposed to trigger never appears.
subtest 'a declared edit marks the form dirty' => sub {
    my @silent;
    for my $f (@pages) {
        ( my $n = $f ) =~ s{.*/}{};
        next if $n eq 'style-guide.md';
        open my $fh, '<', $f or next;
        my $c = do { local $/; <$fh> };
        close $fh;
        while ( $c =~ /<button\b[^>]*data-impact=\\?["']?edit[^>]*onclick=\\?["']([A-Za-z_]\w*)\s*\(/g ) {
            my $fn = $1;
            my ($body) = $c =~ /function\s+\Q$fn\E\s*\([^)]*\)\s*\{(.{0,2000})/s;
            push @silent, "$n -> $fn()"
                unless $body && $body =~ /[Dd]irty|cfgMark|markTargets/;
        }
    }
    is( scalar @silent, 0, 'every editing control marks the form dirty' )
        or diag( "changes what will be saved without saying so:\n  "
            . join( "\n  ", @silent ) );
};

# The rule the whole exercise was for: a destroying control must reach a
# confirmation. Only askable now that destroying controls can be enumerated.
subtest 'a declared destroy reaches a confirmation' => sub {
    my @unconfirmed;
    for my $f (@pages) {
        ( my $n = $f ) =~ s{.*/}{};
        next if $n eq 'style-guide.md';
        open my $fh, '<', $f or next;
        my $c = do { local $/; <$fh> };
        close $fh;
        while ( $c =~ /<button\b[^>]*data-impact=\\?["']?destroy[^>]*onclick=\\?["']([A-Za-z_]\w*)\s*\(/g ) {
            my $fn = $1;
            my ($body) = $c =~ /function\s+\Q$fn\E\s*\([^)]*\)\s*\{(.{0,2000})/s;
            # mgConfirm is the shared helper; prompt() is the stronger
            # type-it-back form data.md uses for a rebuild that drops columns.
            push @unconfirmed, "$n -> $fn()"
                unless $body
                && $body =~ /mgConfirm\s*\(|\bconfirm\s*\(|\bprompt\s*\(|typeToConfirm/i;
        }
    }
    is( scalar @unconfirmed, 0,
        'every destroying control confirms before it destroys' )
        or diag( "the colour is a warning, not the guard:\n  "
            . join( "\n  ", @unconfirmed ) );
};

diag("controls: $declared_total declared, $undeclared_total not yet");
done_testing();
