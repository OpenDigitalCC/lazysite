#!/usr/bin/perl
# SM1423: THE CONTAINER IMAGE INSTALLS EVERY PROGRAM THE ENGINE RUNS.
#
# The 0.16.1 and 0.16.9 images installed no git, so content history (SM085) could
# not be turned on in the container: the engine runs `git` and the image did not
# have it. Nothing said so until a migration walk tried to make a commit. A
# program the engine runs and the image lacks is a feature that cannot work
# there, and the Dockerfile is the one place that decides what the image holds.
#
# So this reads the Dockerfile's real package list (the lines of its one
# `apt-get install`, not a comment that happens to name a package) and holds each
# program below to it. Each row also names the engine file that runs the program,
# and checks that file still does: a row whose evidence has gone is stale, and
# says so, instead of holding the image to a program nothing runs. Add a row when
# the engine starts to run another program the base image does not carry.
#
# Modelled on t/lint/392, which reads the same Dockerfile for the marker's name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $docker = slurp("$root/installers/docker/Dockerfile");

# The packages of the one apt-get install: one bare name per line, up to the
# `&& rm` that ends the RUN. A name with a version pin (`git=1:2.47`) is not a
# bare name and is not found, so a pin fails the row below.
my ($run) = $docker =~ /apt-get install\b[^\n]*\\\n(.*?)\n\s*&& rm\b/s;
ok( defined $run, 'the Dockerfile has one apt-get install ending in the apt lists clean-up' );
my %installed = map { $_ => 1 } ( $run // '' ) =~ /^\s+([a-z0-9][a-z0-9.+-]*)\s*\\?\s*$/mg;
cmp_ok( scalar keys %installed, '>=', 10, 'and its package list was read (' . scalar( keys %installed ) . ' packages)' );

# [ program, Debian package, the feature, the file that runs it, how that file names it ]
my @runs = (
    [ 'git', 'git', 'content history (SM085)', 'lib/Lazysite/Git.pm', qr/^\s*'git',\s*$/m ],
    [ 'curl', 'curl', 'the health check and site status', 'installers/docker/lazysite-sites', qr/CURL=\$\{LAZYSITE_CURL:-curl\}/ ],
    [ 'nginx', 'nginx', 'every site is served through it', 'installers/docker/entrypoint.sh', qr/NGINX=\$\{LAZYSITE_NGINX:-nginx\}/ ],
);

for my $r (@runs) {
    my ( $prog, $pkg, $feature, $file, $how ) = @$r;
    like( slurp("$root/$file"), $how, "$file still runs $prog ($feature)" );
    ok( $installed{$pkg}, "the image installs $pkg, which gives $prog for $feature" );
}

unlike( $run // '', qr/=/, 'no package in the list is version-pinned' );

done_testing();
