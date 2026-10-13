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
# that front end - or `uses:MODULE`, every test that loads a t/lib/ helper (the
# t/lib/ rows, derived from the tree, n562). The rows were derived from the tree
# (which test directories name each area) and sized from a prove --timer run, so
# a typical change costs minutes, not the suite: see SM1061 for the measurement.
# A change to t/lib/TestHelper.pm selects nearly the whole suite: it is the
# whole suite's helper, and that is the right answer.
use strict;
use warnings;

my $ROOT = $0 =~ m{^(.*)/tools/[^/]+$} ? $1 : '.';

# PREFIX                      SELECTORS
my @MAP = (
    [ 'lazysite-processor.pl' => qw(t/unit/processor/ t/unit/render/ integration:run_processor integration:lazysite-processor) ],
    [ 'lazysite-processor/' => qw(t/unit/processor/ t/unit/render/ integration:run_processor integration:lazysite-processor) ],
    [ 'lazysite-manager-api.pl' => qw(t/unit/manager/ integration:lazysite-manager-api integration:ManagerSession) ],
    [ 'lib/Lazysite/Manager/' => qw(t/unit/manager/ integration:lazysite-manager-api integration:ManagerSession) ],
    [ 'lib/Lazysite/ControlApi/' => qw(t/unit/manager/ integration:ControlApi integration:ManagerSession) ],
    [ 'lazysite-auth.pl' => qw(t/unit/auth/ integration:lazysite-auth) ],
    [ 'lib/Lazysite/Auth/' => qw(t/unit/auth/ t/unit/users/ integration:Lazysite::Auth integration:ManagerSession) ],
    [ 'lazysite-oauth.pl'    => qw(t/unit/oauth/ integration:lazysite-oauth) ],
    [ 'lazysite-data.pl'     => qw(t/unit/data/ integration:lazysite-data) ],
    [ 'lib/Lazysite/Data/'   => qw(t/unit/data/ integration:Lazysite::Data) ],
    [ 'lazysite-dav.pl'      => qw(t/unit/dav/ integration:lazysite-dav) ],
    [ 'lazysite-mcp.pl'      => qw(t/unit/mcp/ integration:lazysite-mcp) ],
    [ 'lazysite-front.pl'    => qw(integration:lazysite-front) ],
    [ 'lib/Lazysite/Daemon/' => qw(t/unit/daemon/) ],
    [ 'lib/Lazysite/Odoo/'   => qw(t/unit/odoo/) ],
    # SM747: the engine file beside that directory, and the page endpoint.
    [ 'lib/Lazysite/Odoo.pm' => qw(t/unit/odoo/ integration:lazysite-odoo integration:OdooTest) ],
    [ 'lazysite-odoo.pl'        => qw(t/unit/odoo/ integration:lazysite-odoo) ],
    [ 'lib/Lazysite/Plugins/'   => qw(t/unit/plugins/ t/unit/odoo/) ],
    [ 'lib/Lazysite/'           => qw(t/unit/lib/) ],
    [ 'plugins/'                => qw(t/unit/plugins/) ],
    [ 'tools/lazysite-users.pl' => qw(t/unit/users/) ],
    [ 'tools/'                  => qw(t/unit/tools/) ],
    helper_rows(),
);

sub rows { return @MAP }

# n562: t/lib/ - one row a helper, derived from the tree, so a new helper has
# its row the day it is added. The selector `uses:MODULE` is every test that
# loads the helper, directly or through another helper that does. The manager
# integration tests reach the API only through ManagerSession.pm and name no
# front end, so before this a change to that helper selected nothing.
sub helper_rows {
    return map {
        my $mod = s{^t/lib/}{}r =~ s{\.pm$}{}r =~ s{/}{::}gr;
        [ $_ => "uses:$mod" ]
    } helper_files();
}

sub helper_files { return files_under( 't/lib', qr/\.pm$/ ) }
sub all_tests    { return files_under( 't',     qr/\.t$/ ) }

# Every file under DIR whose name matches RE, relative to the root, sorted.
sub files_under {
    my ( $dir, $re ) = @_;
    my @hit;
    my @dirs = ("$ROOT/$dir");
    while ( my $d = shift @dirs ) {
        opendir my $dh, $d or next;
        for my $e ( grep { !/^\./ } readdir $dh ) {
            push @dirs, "$d/$e" if -d "$d/$e";
            push @hit,  "$d/$e" if $e =~ $re && -f "$d/$e";
        }
        closedir $dh;
    }
    my @rel = sort map { s{^\Q$ROOT\E/}{}r } @hit;
    return @rel;
}

my %SRC;

sub source_of {
    my ($path) = @_;
    return $SRC{$path} //= do {
        open my $fh, '<', "$ROOT/$path" or return '';
        local $/;
        my $s = <$fh>;
        close $fh;
        $s // '';
    };
}

# Does SRC load MODULE: `use`, `require` or `-M` (a PERL5OPT preload), or name a
# namespace the module lives in as a quoted string (OdooTest hands the shop's
# packs to the server as 'LazysiteTest::OdooOps').
sub loads {
    my ( $src, $mod ) = @_;
    return 1 if $src =~ /(?:\buse\s+|\brequire\s+|-M)\Q$mod\E(?![\w:])/;
    my @ns = split /::/, $mod;
    pop @ns;
    while ( @ns >= 2 ) {
        my $ns = join '::', @ns;
        return 1 if $src =~ /(['"])\Q$ns\E\1/;
        pop @ns;
    }
    return 0;
}

# The tests that load MODULE, directly or through the helpers that load it.
sub tests_using {
    my ($mod) = @_;
    my %helper = map { my $p = $_; ( s{^t/lib/}{}r =~ s{\.pm$}{}r =~ s{/}{::}gr => $p ) } helper_files();
    my %via  = ( $mod => 1 );
    my $grew = 1;
    while ($grew) {
        $grew = 0;
        for my $h ( sort keys %helper ) {
            next if $via{$h};
            my $src = source_of( $helper{$h} );
            next unless grep { loads( $src, $_ ) } keys %via;
            $via{$h} = 1;
            $grew = 1;
        }
    }
    my @hit;
    for my $t ( all_tests() ) {
        my $src = source_of($t);
        push @hit, $t if grep { loads( $src, $_ ) } keys %via;
    }
    return @hit;
}

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
    return tests_using($1) if $sel =~ /^uses:(.+)$/;
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
