#!/usr/bin/perl
# n818 (SM1440, field finding O-5 of the 0.16.11 pass): the check's last line ended
# "(re-run with --fix to apply the chmod/chown fixes)" on any run with a warning or
# failure, including one where --fix then reported "nothing to change". The hint is
# shown only when the run queued a chmod/chown repair that --fix would apply.
#
# Sabotage: restore `( $fails || $warns )` as the hint's condition in
# tools/lazysite-check.pl and the first subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
my $GROUP  = getgrgid( $) + 0 ) // ( $) + 0 );

sub run { run_child( [ $^X, $script, '--docroot', $_[0], '--cgibin', dirname($_[0]) . '/cgi-bin', '--group', $GROUP, @_[ 1 .. $#_ ] ], stderr => 'merge' )->{out} // '' }
sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $doc = site_tempdir();
make_path( dirname($doc) . '/cgi-bin' );
my $r = run_child(
    [   $^X, "$root/install.pl", '--mode', 'provision', '--docroot', $doc,
        '--cgibin', dirname($doc) . '/cgi-bin', '--serving-group', $GROUP, '--no-starter'
    ],
    stderr => 'merge',
);
is( $r->{status} >> 8, 0, 'provisioned' ) or diag $r->{out};
run( $doc, '--fix' );
run( $doc, '--fix' );

{
    # A warning only a human can settle: a page names a profile the store lacks.
    spit( "$doc/p.md", "---\ntitle: P\naddresses: [zz-none]\n---\nbody\n" );
    my $out = run($doc);
    like( $out, qr/the store does not hold: zz-none/, 'the run has a warning' ) or diag $out;
    like( run( $doc, '--fix' ), qr/^--fix: nothing to change$/m, '--fix has nothing to change' );
    unlike( $out, qr/re-run with --fix/, 'so the summary does not offer --fix' ) or diag $out;
}

{
    # A repair --fix does apply: the configuration file the CGI cannot read.
    chmod 0600, "$doc/lazysite/lazysite.conf" or die $!;
    my $out = run($doc);
    like( $out, qr/lazysite\.conf .* is not readable by the CGI/, 'the run finds a mode to fix' ) or diag $out;
    like( $out, qr/failure\(s\)  \(re-run with --fix to apply the chmod\/chown fixes\)/, 'and offers --fix' );
}

done_testing();
