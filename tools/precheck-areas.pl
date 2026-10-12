#!/usr/bin/perl
# tools/precheck-areas.pl - the tests that cover each code AREA (SM1061).
#
#   perl tools/precheck-areas.pl FILE...   # the test files for the areas FILE... touch
#   perl tools/precheck-areas.pl --rows    # the map, one row a line: PREFIX<TAB>SELECTORS
#
# The precheck ran the tests that NAME a changed file. That missed the case that
# mattered on 2026-10-12: a change to lazysite-processor/sources.pm broke
# t/unit/processor/101, which names no file of the change, and it went unseen
# until a whole-suite run on main. So the precheck also runs the tests that cover
# each area a change touches, from the map below - the one declared place, so
# t/lint/255 can check that every top-level code area has a row.
#
# A changed file takes the row with the LONGEST prefix it starts with (a manager
# module is the manager's area, not lib/Lazysite/'s). A selector is a test
# directory (t/unit/x/, every .t in it) or `integration:TEXT`, every
# t/integration/*.t whose source contains TEXT - the integration tests that run
# that front end. The rows were derived from the tree (which test directories
# name each area) and sized from a prove --timer run, so a typical change costs
# minutes, not the suite: see SM1061 for the measurement.
use strict;
use warnings;

my $ROOT = $0 =~ m{^(.*)/tools/[^/]+$} ? $1 : '.';

# PREFIX                      SELECTORS
my @MAP = (
    [ 'lazysite-processor.pl' => qw(t/unit/processor/ t/unit/render/ integration:run_processor integration:lazysite-processor) ],
    [ 'lazysite-processor/' => qw(t/unit/processor/ t/unit/render/ integration:run_processor integration:lazysite-processor) ],
    [ 'lazysite-manager-api.pl' => qw(t/unit/manager/ integration:lazysite-manager-api) ],
    [ 'lib/Lazysite/Manager/'   => qw(t/unit/manager/ integration:lazysite-manager-api) ],
    [ 'lib/Lazysite/ControlApi/' => qw(t/unit/manager/ integration:ControlApi) ],
    [ 'lazysite-auth.pl'         => qw(t/unit/auth/ integration:lazysite-auth) ],
    [ 'lib/Lazysite/Auth/' => qw(t/unit/auth/ t/unit/users/ integration:Lazysite::Auth) ],
    [ 'lazysite-oauth.pl'  => qw(t/unit/oauth/ integration:lazysite-oauth) ],
    [ 'lazysite-data.pl'   => qw(t/unit/data/ integration:lazysite-data) ],
    [ 'lib/Lazysite/Data/' => qw(t/unit/data/ integration:Lazysite::Data) ],
    [ 'lazysite-dav.pl'    => qw(t/unit/dav/ integration:lazysite-dav) ],
    [ 'lazysite-mcp.pl'    => qw(t/unit/mcp/ integration:lazysite-mcp) ],
    [ 'lazysite-front.pl'  => qw(integration:lazysite-front) ],
    [ 'lib/Lazysite/Daemon/'    => qw(t/unit/daemon/) ],
    [ 'lib/Lazysite/Odoo/'      => qw(t/unit/odoo/) ],
    [ 'lib/Lazysite/Plugins/'   => qw(t/unit/plugins/ t/unit/odoo/) ],
    [ 'lib/Lazysite/'           => qw(t/unit/lib/) ],
    [ 'plugins/'                => qw(t/unit/plugins/) ],
    [ 'tools/lazysite-users.pl' => qw(t/unit/users/) ],
    [ 'tools/'                  => qw(t/unit/tools/) ],
);

sub rows { return @MAP }

# The .t files one selector names, sorted, relative to the root.
sub select_tests {
    my ($sel) = @_;
    if ( $sel =~ /^integration:(.+)$/ ) {
        my $text = $1;
        my @hit;
        for my $t ( sort glob("$ROOT/t/integration/*.t") ) {
            open my $fh, '<', $t or next;
            my $src = do { local $/; <$fh> };
            close $fh;
            push @hit, $t if index( $src, $text ) >= 0;
        }
        return map { s{^\Q$ROOT\E/}{}r } @hit;
    }
    return map { s{^\Q$ROOT\E/}{}r } sort glob("$ROOT/$sel*.t");
}

# The row a path belongs to: the longest prefix it starts with, or none.
sub row_for {
    my ($path) = @_;
    my ($best) = sort { length $b->[0] <=> length $a->[0] } grep { index( $path, $_->[0] ) == 0 } @MAP;
    return $best;
}

sub main {
    my @args = @_;
    if ( @args && $args[0] eq '--rows' ) {
        print join( "\t", $_->[0], @{$_}[ 1 .. $#$_ ] ), "\n" for @MAP;
        return 0;
    }
    my %want;
    for my $path (@args) {
        my $row = row_for($path) or next;
        $want{$_} = 1 for map { select_tests($_) } @{$row}[ 1 .. $#$row ];
    }
    print "$_\n" for sort keys %want;
    return 0;
}

exit main(@ARGV) unless caller;
1;
