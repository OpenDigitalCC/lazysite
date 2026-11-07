#!/usr/bin/perl
# SM1273 (ruling 25, 2026-10-23): `lazysite repair` runs the SM645 top-up.
#
# After an upgrade a manager group lacks the capabilities the release added
# until the next use of the users tool (SM685: not at upgrade, not on sign-in).
# The check says so (SM1272), and repair filed every such site under "awaiting
# your decision", though there is nothing to decide. Repair now runs
# `lazysite-users.pl --docroot D group-reach <group>` for each manager group
# before its re-check, so the top-up fills the gap and the site lands in
# repaired. The top-up never fills a declined (0) capability.
#
# Driven through the real CLI and the real users tool, in a payload whose
# check is a stand-in: it warns while a manager group lacks a capability, and
# is otherwise clean, so the site's verdict turns on the top-up alone. The
# real check's wording is t/tools/59's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $t    = site_tempdir();
$t =~ s{/site/public_html\z}{};

sub spit { my ( $p, $s ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $s; close $f; chmod 0755, $p }
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$f>; close $f; $s }

# A payload: the real CLI and lib, a stand-in check, and the users tool given.
sub payload {
    my ( $name, $users ) = @_;
    my $p = "$t/$name";
    make_path("$p/tools");
    spit( "$p/install.pl", "1;\n" );
    spit( "$p/VERSION", "0.0.0\n" );    # payload_root asks only that it exists
    spit( "$p/tools/lazysite-cli.pl", slurp("$root/tools/lazysite-cli.pl") );
    symlink "$root/lib", "$p/lib" or die $!;
    spit( "$p/tools/lazysite-check.pl", <<'CHECK' );
use strict;
use warnings;
use JSON::PP;
use Lazysite::Paths;
use Lazysite::Auth::Settings ();
my %o = @ARGV % 2 ? ( @ARGV, 1 ) : @ARGV;
my $gs = decode_json( do {
    open my $f, '<', Lazysite::Paths::lazysite_dir( $o{'--docroot'} ) . '/auth/groups-settings.json' or die $!;
    local $/; <$f>;
} );
my @gap;
for my $g ( sort keys %$gs ) {
    next unless ref $gs->{$g} eq 'HASH' && $gs->{$g}{manager};
    push @gap, map { "$g/$_" } grep { !exists $gs->{$g}{$_} }
        grep { my $c = $_; !grep { $_ eq $c } @Lazysite::Auth::Settings::OFF_BY_DEFAULT }    # SM1354, as the real check
        grep { $_ ne 'api' && $_ ne 'mcp' } @Lazysite::Auth::Settings::CAP_KEYS;
}
print @gap
    ? "[ warn ] manager group(s) do not hold capabilities this release has yet: @gap\n"
    : "[  ok  ] manager group(s) carry a decision on every capability\n";
CHECK
    if ( ref $users ) { spit( "$p/tools/lazysite-users.pl", $$users ) }
    else              { symlink "$root/tools/lazysite-users.pl", "$p/tools/lazysite-users.pl" or die $! }
    return $p;
}
my $real   = payload( 'payload', undef );
my $broken = payload( 'payload-broken', \"print STDERR \"cannot open the group store\\n\"; exit 3;\n" );

# A site made the way a real one is, then aged: sysops lacks maintenance_access
# (added after it was seeded) and has declined feedback.
my $n = 0;
sub site {
    my $d = "$t/sites/" . ++$n . '/public_html';
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    qx($^X -I\Q$root/lib\E \Q$root/tools/lazysite-users.pl\E --docroot \Q$d\E setup-sysop --user sjm pw123456789-long-enough 2>/dev/null);
    my $p  = "$d/lazysite/auth/groups-settings.json";
    my $gs = decode_json( slurp($p) );
    die "setup-sysop made no sysops group\n" unless ref $gs->{sysops} eq 'HASH';
    delete $gs->{sysops}{maintenance_access};
    $gs->{sysops}{feedback} = 0;
    spit( $p, JSON::PP->new->canonical->encode($gs) );
    make_path("$t/reg$n");
    spit( "$t/reg$n/site.example", "docroot=$d\n" );
    return ( $d, "$t/reg$n" );
}
sub sysops { return decode_json( slurp("$_[0]/lazysite/auth/groups-settings.json") )->{sysops} }

sub repair {
    my ( $payload, $reg, @args ) = @_;
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    my $cmd = join ' ', map { quotemeta } $^X, "$payload/tools/lazysite-cli.pl", 'repair',
        '--domain', 'site.example', @args;
    return scalar `$cmd 2>&1`;
}

subtest 'a site whose only gap is the top-up\'s ends repaired, holding it' => sub {
    my ( $d, $reg ) = site();
    my $out = repair( $real, $reg );
    is( sysops($d)->{maintenance_access}, 1, 'sysops holds maintenance_access' )
        or diag $out;
    like( $out, qr/repaired; the site is clean/, 'the re-check is clean' );
    like( $out, qr/0 clean, 1 repaired, 0 awaiting your decision, 0 need a human/,
        'and it is counted repaired, not awaiting a decision' );
};

subtest 'a declined capability stays declined' => sub {
    my ( $d, $reg ) = site();
    my $out = repair( $real, $reg );
    is( sysops($d)->{maintenance_access}, 1, 'the top-up ran (the absent one is granted)' )
        or diag $out;
    is( sysops($d)->{feedback}, 0, 'and feedback, declined, is still 0' );
};

subtest 'the dry run says it would run the top-up, and runs nothing' => sub {
    my ( $d, $reg ) = site();
    my $before = slurp("$d/lazysite/auth/groups-settings.json");
    my $out = repair( $real, $reg, '--dry-run' );
    like( $out, qr/would run the capability top-up: .*group-reach sysops/,
        'it names the top-up it would run' )
        or diag $out;
    is( slurp("$d/lazysite/auth/groups-settings.json"), $before, 'the group store is unchanged' );
    ok( !exists sysops($d)->{maintenance_access}, 'nothing was granted' );
};

subtest 'a top-up that fails is reported, and the repair goes on' => sub {
    my ( $d, $reg ) = site();
    my $out = repair( $broken, $reg );
    like( $out, qr/the capability top-up for sysops did not run \(exit 3\): .*cannot open the group store/,
        'the failure is named, with what the users tool said' )
        or diag $out;
    like( $out, qr/awaiting your decision, 0 need a human/, 'and the repair still reports its tally' );
};

done_testing();
