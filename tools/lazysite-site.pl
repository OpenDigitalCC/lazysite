#!/usr/bin/perl
# lazysite-site.pl - portable per-domain SITE packages (SM158). Package one
# domain's SITE (its content root + nav + bundled theme/layout + a manifest of
# the presentation keys) into a .tar.gz for hand-off to a client's own instance,
# or to move a site between domains/instances. Same engine
# (Lazysite::Manager::SitePackage) as the manager's site-backup-* actions and
# the MCP tools, so an orchestrator can drive it identically to the UI.
#
# The package deliberately EXCLUDES plugins, instance/site settings and auth
# secrets, so it carries no secrets (unlike the whole-docroot `full` backup).
#
# Usage:
#   lazysite-site.pl --docroot DIR backup --host H [--json]
#     Writes lazysite/backups/site-<host>-<UTCstamp>.tar.gz (download it with the
#     ordinary backup tooling). Exit 0 on success, 1 on error.
use strict;
use warnings;

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Manager::SitePackage qw(package_create);

my ( %opt, @pos );
{
    my @a = @ARGV;
    while (@a) {
        my $t = shift @a;
        if ( $t =~ /^--([\w-]+)$/ ) {
            my $k = $1;
            if   ( $k eq 'json' ) { $opt{$k} = 1 }
            else                  { $opt{$k} = shift @a }
        }
        else { push @pos, $t }
    }
}

my $cmd     = shift @pos    // '';
my $docroot = $opt{docroot} // '';
die "lazysite-site: --docroot DIR is required\n"   unless length $docroot;
die "lazysite-site: docroot not found: $docroot\n" unless -d $docroot;
$Lazysite::Manager::SitePackage::DOCROOT = $docroot;
$Lazysite::Manager::SitePackage::auth_user
    = $opt{actor} // ( getpwuid($<) )[0] // 'cli';

my $result;
if ( $cmd eq 'backup' ) {
    die "lazysite-site: backup requires --host\n" unless defined $opt{host};
    $result = package_create( $opt{host} );
}
else {
    die "lazysite-site: unknown command '$cmd' (backup); run with no command for usage.\n";
}

if ( $opt{json} ) {
    require JSON::PP;
    print JSON::PP->new->canonical->encode($result), "\n";
}
elsif ( $result->{ok} ) {
    printf "packaged %s -> lazysite/backups/%s (%d bytes)\n",
        ( $result->{host} // '' ), $result->{name}, ( $result->{size} // 0 );
}
else {
    print STDERR "error: ", ( $result->{error} // 'failed' ), "\n";
    exit 1;
}
exit 0;
