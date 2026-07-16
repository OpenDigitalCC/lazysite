#!/usr/bin/perl
# lazysite-domains.pl - manage the domains one lazysite instance serves, from
# the command line. Same engine (Lazysite::Manager::Domains) as the manager UI's
# domain-* actions, so an external control panel can drive the lazysite side of
# a deploy identically to the UI - after it (or Hestia) has set up DNS, the
# web-server domain alias and TLS, which are NOT lazysite's concern.
#
# Usage:
#   lazysite-domains.pl --docroot DIR list [--json]
#   lazysite-domains.pl --docroot DIR add    --host H --content-root R \
#       [--site-url U] [--site-name N] [--theme T] [--layout L] \
#       [--nav-file F] [--search-default S] [--seed]
#   lazysite-domains.pl --docroot DIR set    --host H --key K --value V
#   lazysite-domains.pl --docroot DIR remove --host H [--purge]
#   lazysite-domains.pl --docroot DIR alias  --host H --of CANONICAL_HOST
#
# Exit 0 on success, 1 on error. --json prints the raw result object.
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
use Lazysite::Manager::Domains
    qw(domains_list domain_add domain_add_alias domain_remove domain_set);

my %opt;
my @pos;
{
    my @a = @ARGV;
    while (@a) {
        my $t = shift @a;
        if ( $t =~ /^--([\w-]+)$/ ) {
            my $k = $1;
            # boolean flags take no value
            if   ( $k eq 'seed' || $k eq 'purge' || $k eq 'json' ) { $opt{$k} = 1 }
            else                                                   { $opt{$k} = shift @a }
        }
        else { push @pos, $t }
    }
}

my $cmd     = shift @pos    // '';
my $docroot = $opt{docroot} // '';
die "lazysite-domains: --docroot DIR is required\n"   unless length $docroot;
die "lazysite-domains: docroot not found: $docroot\n" unless -d $docroot;
$Lazysite::Manager::Domains::DOCROOT   = $docroot;
$Lazysite::Manager::Domains::auth_user = $opt{actor} // ( getpwuid($<) )[0] // 'cli';

# Map --content-root => content_root, --nav-file => nav_file, etc.
sub _kv {
    my (@keys) = @_;
    my %h;
    for my $k (@keys) {
        ( my $flag = $k ) =~ s/_/-/g;
        $h{$k} = $opt{$flag} if defined $opt{$flag};
    }
    return %h;
}

my $result;
if ( $cmd eq 'list' ) {
    $result = domains_list();
}
elsif ( $cmd eq 'add' ) {
    die "lazysite-domains: add requires --host and --content-root\n"
        unless defined $opt{host} && defined $opt{'content-root'};
    my %o = _kv(
        qw(content_root site_url site_name theme layout nav_file search_default));
    $o{seed} = 1 if $opt{seed};
    $result = domain_add( $opt{host}, %o );
}
elsif ( $cmd eq 'set' ) {
    die "lazysite-domains: set requires --host --key --value\n"
        unless defined $opt{host} && defined $opt{key};
    $result = domain_set( $opt{host}, $opt{key}, $opt{value} );
}
elsif ( $cmd eq 'remove' ) {
    die "lazysite-domains: remove requires --host\n" unless defined $opt{host};
    $result = domain_remove( $opt{host}, purge => ( $opt{purge} ? 1 : 0 ) );
}
elsif ( $cmd eq 'alias' ) {
    die "lazysite-domains: alias requires --host and --of\n"
        unless defined $opt{host} && defined $opt{of};
    $result = domain_add_alias( $opt{host}, $opt{of} );
}
else {
    die "lazysite-domains: unknown command '$cmd' "
        . "(list|add|alias|set|remove); run with no command for usage.\n";
}

if ( $opt{json} ) {
    require JSON::PP;
    print JSON::PP->new->canonical->encode($result), "\n";
}
elsif ( $result->{ok} ) {
    if ( $cmd eq 'list' ) {
        printf "%-28s %-22s %s\n", 'HOST', 'CONTENT_ROOT', 'SITE_URL';
        for my $d ( @{ $result->{domains} } ) {
            printf "%-28s %-22s %s\n", $d->{host}, ( $d->{content_root} // '' ),
                ( $d->{site_url} // '' );
        }
    }
    else {
        print "ok: $cmd ", ( $result->{host} // '' ), "\n";
    }
}
else {
    print STDERR "error: ", ( $result->{error} // 'failed' ), "\n";
    exit 1;
}
exit 0;
