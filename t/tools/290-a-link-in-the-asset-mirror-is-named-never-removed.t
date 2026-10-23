#!/usr/bin/perl
# SM1304 (ruling 42): A SYMBOLIC LINK IN THE SERVED ASSET MIRROR IS NAMED, NEVER REMOVED.
#
# Before 0.16.2 the manager's theme upload copied a zip's symbolic link into
# /lazysite-assets/ as a link (SM1303), so a public URL there served whatever it
# pointed at - lazysite/auth/.secret, the session-signing secret, among them.
# The upload refuses one now; a link planted before stays, and nothing looked.
#
# `lazysite check` warns for every link under lazysite-assets/, naming it and
# its target, and the warning line itself says to remove it and rotate the
# secret - a deploy report keeps that line and drops the hint under it. Neither
# the check nor its --fix removes it. And `lazysite repair` does not count the
# site as repaired: the link is not a decision to take later, it is a human's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root  = repo_root();
my $check = "$root/tools/lazysite-check.pl";
my $cli   = "$root/tools/lazysite-cli.pl";
plan skip_all => "no $check" unless -f $check;

sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

# A site with a theme's asset mirror, and a planted link in it when asked.
sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite-assets/default/plain" );
    spit( "$d/lazysite/lazysite.conf",        "site_name: T\n" );
    spit( "$d/lazysite/auth/.secret",         "0123456789abcdef\n" );
    spit( "$d/lazysite-assets/default/plain/main.css", "body{}\n" );
    symlink( "$d/lazysite/auth/.secret", "$d/lazysite-assets/default/plain/s.css" ) or die "symlink: $!"
        if $o{link};
    return $d;
}

sub check {
    my ( $d, @a ) = @_;
    my $r = run_child( [ $^X, "-I$root/lib", $check, '--docroot', $d, @a ], stderr => 'merge' );
    return $r->{out};
}

subtest 'a clean mirror says so' => sub {
    my $out = check( site() );
    like( $out, qr/\[  ok  \] no symbolic link in the served asset mirror/, 'an ok line' ) or diag $out;
    unlike( $out, qr/SYMBOLIC LINK/, 'and no warning' );
};

subtest 'a planted link is warned, named with its target and the remedy' => sub {
    my $d   = site( link => 1 );
    my $out = check($d);
    my ($line) = $out =~ /^(\[ warn \] SYMBOLIC LINK in the served asset mirror:[^\n]*)$/m;
    ok( $line, 'a warn line' ) or return diag $out;
    like( $line, qr{lazysite-assets/default/plain/s\.css -> \Q$d\E/lazysite/auth/\.secret},
        'naming the link and its target' );
    like( $line, qr/public at \/lazysite-assets\/default\/plain\/s\.css/, 'and the URL that serves it' );
    like( $line, qr/Remove it, and rotate \Q$d\E\/lazysite\/auth\/\.secret/,
        'and saying, on the line itself, to remove it and rotate the secret' );
    like( $out, qr/^\s+-> .*rm '\Q$d\E\/lazysite-assets\/default\/plain\/s\.css'.*Log out all users.*rotate-auth-secret/m,
        'the hint spells the removal and the rotation' );
    ok( -l "$d/lazysite-assets/default/plain/s.css", 'and the link is still there' );
};

subtest 'every link is named, and --fix removes none' => sub {
    my $d = site( link => 1 );
    symlink( '/etc/passwd', "$d/lazysite-assets/default/passwd" ) or die $!;
    my $out = check( $d, '--fix' );
    my @w = $out =~ /^\[ warn \] SYMBOLIC LINK in the served asset mirror: (\S+) -> /mg;
    is_deeply( [ sort @w ], [ 'lazysite-assets/default/passwd', 'lazysite-assets/default/plain/s.css' ],
        'one warning per link' ) or diag $out;
    ok( -l "$d/lazysite-assets/default/passwd" && -l "$d/lazysite-assets/default/plain/s.css",
        'both are still there after --fix' );
};

# The repair as it ships, over a payload whose doctor is the real check with
# only its asset-mirror lines kept: a scratch site, not root and not in
# www-data, fails on ownership and modes, and those failures would put it among
# the sites needing a human whatever the link did.
subtest 'repair does not count the site as repaired' => sub {
    my $p = tempdir( CLEANUP => 1 );
    make_path("$p/tools");
    spit( "$p/install.pl", "1;\n" );
    spit( "$p/VERSION",    "9.9.9\n" );
    {
        open my $in, '<', $cli or die $!;
        spit( "$p/tools/lazysite-cli.pl", do { local $/; <$in> } );
    }
    spit( "$p/tools/lazysite-check.pl", <<"PL" );
my \$out = qx(\Q$^X\E -I\Q$root/lib\E \Q$check\E \@{[ join ' ', map { quotemeta } \@ARGV ]} 2>&1);
print grep { /asset mirror/ } split /^/, \$out;
PL
    my $reg = tempdir( CLEANUP => 1 );
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    my $repair = sub {
        my $r = run_child( [ $^X, "$p/tools/lazysite-cli.pl", 'repair', '--domain', 't.example' ], stderr => 'merge' );
        return ( $r->{status} >> 8, $r->{out} );
    };

    my $c = site();
    spit( "$reg/t.example", "docroot=$c\n" );
    my ( $rc, $out ) = $repair->();
    like( $out, qr/^1 clean, 0 repaired, 0 awaiting your decision, 0 need a human\.$/m,
        'a site with no link is clean (the stand-in doctor reports what the real one does)' ) or diag $out;

    my $d = site( link => 1 );
    spit( "$reg/t.example", "docroot=$d\n" );
    ( $rc, $out ) = $repair->();
    like( $out, qr/\[ warn \] SYMBOLIC LINK in the served asset mirror/, 'the finding is in the repair report' )
        or diag $out;
    like( $out, qr/^0 clean, 0 repaired, 0 awaiting your decision, 1 need a human\.$/m,
        'counted as needing a human: not repaired, and not a decision to take later' ) or diag $out;
    like( $out, qr/^NEEDS A HUMAN: t\.example$/m, 'named' );
    is( $rc, 1, 'and the run is not green' );
    ok( -l "$d/lazysite-assets/default/plain/s.css", 'the link is still there' );
};

done_testing();
