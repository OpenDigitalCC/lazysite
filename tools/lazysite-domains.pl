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
#   lazysite-domains.pl --docroot DIR group-add    --host H --group G
#   lazysite-domains.pl --docroot DIR group-remove --host H --group G
#   lazysite-domains.pl --docroot DIR user-add     --host H --user U
#   lazysite-domains.pl --docroot DIR user-remove  --host H --user U
#   lazysite-domains.pl --docroot DIR remove --host H [--purge]
#   lazysite-domains.pl --docroot DIR check  --host H [--self-ip PUBLIC_IP]
#
# The full text is usage() below, printed by --help or with no command.
#
# Exit 0 on success, 1 on error. `check` exits 2 when the domain is not yet
# fully configured (some check failed), so a caller can gate on it. --json
# prints the raw result object.
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
    qw(domains_list domain_add domain_remove domain_set domain_access_edit domain_check);

sub usage {
    print <<'USAGE';
lazysite-domains.pl - manage the domains one lazysite instance serves

Usage: lazysite-domains.pl --docroot DIR COMMAND [OPTIONS]

Commands:
  list [--json]                   the primary site and every domain
  add --host H --content-root R   register a domain
      [--site-url U] [--site-name N] [--theme T] [--layout L]
      [--nav-file F] [--search-default S] [--seed]
  set --host H --key K --value V  set one key on one domain (the whole value)
  group-add --host H --group G    add ONE group to the domain's allowed_groups,
                                  keeping the others; G is @name or name, and
                                  must be a group on this site
  group-remove --host H --group G take ONE group out of allowed_groups
  user-add --host H --user U      add ONE account to the domain's locked_users;
                                  U must be an account on this site
  user-remove --host H --user U   take ONE account out of locked_users
  remove --host H [--purge]       remove a domain (--purge: its content too)
  check --host H [--self-ip IP]   DNS, TLS and vhost checks; exits 2 until the
                                  domain is fully configured. --self-ip
                                  overrides this server's public IP, which is
                                  otherwise discovered from canonical_ip or the
                                  install's own domain

group-add, group-remove, user-add and user-remove write through the same
path as `set` (validation, the content-history commit, the log line). Adding
a name already there, or removing one that is not, changes nothing, says so
and exits 0.

Options:
  --docroot DIR   the site's document root (required)
  --json          print the raw result object
  --actor NAME    the name the change is recorded under (default: the login)
  --help          this text

Exit 0 on success, 1 on error, 2 from `check` when a check fails.
USAGE
    return;
}

my %opt;
my @pos;
{
    my @a = @ARGV;
    while (@a) {
        my $t = shift @a;
        if ( $t =~ /^--([\w-]+)$/ ) {
            my $k = $1;
            # boolean flags take no value
            if ( $k eq 'seed' || $k eq 'purge' || $k eq 'json' || $k eq 'help' ) { $opt{$k} = 1 }
            else { $opt{$k} = shift @a }
        }
        else { push @pos, $t }
    }
}

my $cmd = shift @pos // '';
if ( $opt{help} || $cmd eq '' || $cmd eq 'help' ) { usage(); exit 0 }
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
elsif ( $cmd =~ /\A(group|user)-(add|remove)\z/ ) {
    # SM1015: one name in, or out, of a domain's access list.
    my ( $what, $op ) = ( $1, $2 );
    my ( $flag, $key ) = $what eq 'group' ? ( 'group', 'allowed_groups' ) : ( 'user', 'locked_users' );
    die "lazysite-domains: $cmd requires --host and --$flag\n"
        unless defined $opt{host} && defined $opt{$flag};
    $result = domain_access_edit( $opt{host}, $key, $op, $opt{$flag} );
}
elsif ( $cmd eq 'remove' ) {
    die "lazysite-domains: remove requires --host\n" unless defined $opt{host};
    $result = domain_remove( $opt{host}, purge => ( $opt{purge} ? 1 : 0 ) );
}
elsif ( $cmd eq 'check' ) {
    die "lazysite-domains: check requires --host\n" unless defined $opt{host};
    require Digest::SHA;
    my $base = Cwd::realpath($docroot) // $docroot;
    my $instance = substr( Digest::SHA::hmac_sha256_hex( $base, 'lazysite-instance' ), 0, 32 );
    # --self-ip, when given, is an explicit canonical-IP override; otherwise the
    # public address is discovered from config / the install's own domain.
    my @self = Lazysite::Manager::Domains::instance_public_ips(
        canonical_ip => ( $opt{'self-ip'} // '' ) );
    $result = domain_check(
        $opt{host},
        self_ips    => \@self,
        instance_id => $instance,
    );
}
else {
    die "lazysite-domains: unknown command '$cmd' "
        . "(list|add|set|group-add|group-remove|user-add|user-remove|remove|check); "
        . "run with --help for usage.\n";
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
    elsif ( $cmd eq 'check' ) {
        printf "domain %s: %s\n", $result->{host},
            ( $result->{all_pass} ? 'OK - live' : 'NOT READY' );
        for my $c ( @{ $result->{checks} } ) {
            my $mark = !defined $c->{pass} ? '?' : $c->{pass} ? 'PASS' : 'FAIL';
            printf "  [%-4s] %-24s %s\n", $mark, $c->{label}, $c->{detail};
        }
    }
    elsif ( defined $result->{changed} ) {
        # group-add & co: the sentence says what happened, including nothing.
        print( ( $result->{changed} ? 'ok: ' : 'unchanged: ' ), $result->{message}, "\n" );
        my $now = $result->{value} // '';
        $now = join ', ', map { "\@$_" } grep { length } split /\s*,\s*/, $now
            if ( $result->{key} // '' ) eq 'allowed_groups';
        print "  $result->{key}: ", ( length $now ? $now : '(none)' ), "\n";
    }
    else {
        print "ok: $cmd ", ( $result->{host} // '' ), "\n";
    }
}
else {
    print STDERR "error: ", ( $result->{error} // 'failed' ), "\n";
    exit 1;
}

# `check` gates on readiness: 0 = fully configured, 2 = something still failing.
exit( $result->{all_pass} ? 0 : 2 ) if $cmd eq 'check' && $result->{ok};
exit 0;
