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
#     Package one domain's site into lazysite/backups/lazysite-site-<host>-<UTC>.
#   lazysite-site.pl --docroot DIR apply --package FILE [--host H] [--clean] [--json]
#     Apply a package (a path, or a name already in lazysite/backups/) to a target
#     domain's content root - or the default site when --host is omitted. Writes
#     the target domain's presentation keys from the package manifest. This is a
#     system/operator operation (no manager scope check); take a backup first if
#     you want a rollback point.
# Exit 0 on success, 1 on error.
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
            if   ( $k eq 'json' || $k eq 'clean' ) { $opt{$k} = 1 }
            else                                   { $opt{$k} = shift @a }
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
elsif ( $cmd eq 'apply' ) {
    die "lazysite-site: apply requires --package FILE\n" unless defined $opt{package};
    # --package may be a path, or a bare name already in lazysite/backups/.
    my $pkg = $opt{package};
    $pkg = "$docroot/lazysite/backups/$pkg" if !-f $pkg && -f "$docroot/lazysite/backups/$pkg";
    die "lazysite-site: package not found: $opt{package}\n" unless -f $pkg;
    $result = Lazysite::Manager::SitePackage::apply_and_configure(
        $pkg,
        host         => ( $opt{host}           // '' ),
        content_root => ( $opt{'content-root'} // '' ),
        clean        => ( exists $opt{clean} ? 1 : 0 ) );
}
else {
    die "lazysite-site: unknown command '$cmd' (backup|apply); "
        . "run with no command for usage.\n";
}

if ( $opt{json} ) {
    require JSON::PP;
    print JSON::PP->new->canonical->encode($result), "\n";
}
elsif ( $result->{ok} && $cmd eq 'backup' ) {
    printf "packaged %s -> lazysite/backups/%s (%d bytes)\n",
        ( $result->{host} // '' ), $result->{name}, ( $result->{size} // 0 );
}
elsif ( $result->{ok} && $cmd eq 'apply' ) {
    printf "applied to %s (content root %s, nav %s%s)\n",
        ( $result->{applied_to} // '' ), ( $result->{content_root} // '' ),
        ( $result->{nav}        // '' ),
        ( $result->{layout_installed} ? ", layout $result->{layout_installed} installed" : '' );
}
else {
    print STDERR "error: ", ( $result->{error} // 'failed' ), "\n";
    exit 1;
}
exit 0;
