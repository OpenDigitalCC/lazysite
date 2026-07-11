#!/usr/bin/perl
# tools/lazysite-nginx-vhost.pl - nginx vhost glue (SM139 glue debs).
# The lazysite-nginx deb installs this as /usr/bin/lazysite-nginx-vhost.
#
# A host-integrator in the lazysite-hestia-domain mould: it renders one of
# the shipped server-block examples (vhost-cgi / vhost-fcgi) into
# /etc/nginx/sites-available/<domain>.conf and tells the operator the
# enable/test/reload steps - it deliberately does NOT run them (linking
# sites-enabled and reloading nginx are the operator's visible actions).
# It never writes into a site tree; `remove` deletes the vhost file only,
# never content. Root is required because /etc is root territory; input
# is validated BEFORE the privilege check so error messages are usable
# regardless of privilege.
#
# Core-only Perl; no CPAN deps.

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use Getopt::Long   ();

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

# LAZYSITE_NGINX_SITES_DIR relocates the output directory - for the test
# suite and non-Debian layouts. When set, the root requirement is waived
# (the override points somewhere the caller can write; the default /etc
# does not).
my $SITES_DIR_OVERRIDDEN = length( $ENV{LAZYSITE_NGINX_SITES_DIR} // '' ) ? 1 : 0;
my $SITES_DIR
    = $SITES_DIR_OVERRIDDEN
    ? $ENV{LAZYSITE_NGINX_SITES_DIR}
    : '/etc/nginx/sites-available';

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';

if    ( $verb eq '' )                                     { usage(2) }
elsif ( $verb eq 'help' || $verb =~ /^-{0,2}help$|^-h$/ ) { usage(0) }
elsif ( $verb eq 'add' )                                  { exit cmd_add() }
elsif ( $verb eq 'remove' )                               { exit cmd_remove() }
else {
    print {*STDERR} "lazysite-nginx-vhost: unknown verb '$verb'\n\n";
    usage(2);
}

# ---------- usage / errors ----------

sub usage {
    my ($rc) = @_;
    my $fh = ( $rc // 0 ) == 0 ? *STDOUT : *STDERR;
    print {$fh} <<'USAGE';
Usage: lazysite-nginx-vhost VERB [options]

Render the shipped lazysite nginx server-block templates into
/etc/nginx/sites-available/. Writes the vhost file only - it never
touches site content and never links sites-enabled or reloads nginx for
you (the required commands are printed instead).

Verbs:
  add DOMAIN --docroot D [--cgibin C] [--fcgi] [--port N] [--force]
        Render the server block for DOMAIN to
        sites-available/DOMAIN.conf. --docroot is the site's
        public_html; --cgibin defaults to the cgi-bin sibling next to
        it. --fcgi renders the FastCGI-pool pattern (RECOMMENDED on
        nginx; default is plain CGI via fcgiwrap); --port sets the
        listen port (default 80). Refuses to overwrite an existing
        vhost file without --force. Provision the site first (as the
        site user: `lazysite provision`), then wire the vhost.
  remove DOMAIN
        Delete sites-available/DOMAIN.conf. NEVER deletes site content;
        the sites-enabled unlink is printed, not run.
  help
        This help.

Environment:
  LAZYSITE_NGINX_SITES_DIR    Output directory override (tests,
                              non-Debian layouts); also waives the root
                              requirement, since the default /etc target
                              is what needs root.

Full documentation: man lazysite-nginx-vhost.
USAGE
    exit( $rc // 0 );
}

sub fail {
    my ($msg) = @_;
    $msg =~ s/\n?$/\n/;
    print {*STDERR} "lazysite-nginx-vhost: $msg";
    exit 1;
}

sub require_root {
    my ($what) = @_;
    return if $> == 0;
    return if $SITES_DIR_OVERRIDDEN;
    fail( "'$what' must run as root: it writes $SITES_DIR.\n"
            . 'Re-run with sudo (it never touches site content).' );
}

# ---------- shared helpers ----------

# Templates ship at /usr/share/lazysite-nginx (deb) or installers/nginx
# (checkout/tarball, relative to this script).
sub template_dir {
    my $bin = dirname( abs_path($0) );
    for my $cand ( "$bin/../installers/nginx", '/usr/share/lazysite-nginx' ) {
        return $cand if -f "$cand/vhost-cgi.conf.example";
    }
    fail( 'cannot locate the vhost templates (vhost-*.conf.example) - '
            . 'is lazysite-nginx installed?' );
}

# Domain names become file names and server_name values - allow only the
# safe hostname alphabet (no traversal, no config injection).
sub check_domain {
    my ($domain) = @_;
    fail('DOMAIN is required') unless length( $domain // '' );
    fail("invalid domain '$domain' (allowed: [A-Za-z0-9._-], no leading dot/dash)")
        if $domain !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
    return $domain;
}

# Paths land verbatim in config directives: require absolute, existing
# directories with no whitespace/quotes (which would change the config's
# parse) - the vhost is only correct if the tree it points at is real.
sub check_dir_opt {
    my ( $what, $path, $hint ) = @_;
    fail("$what is required") unless length( $path // '' );
    my $abs = abs_path($path);
    fail("$what '$path' does not resolve to a directory$hint")
        unless defined $abs && -d $abs;
    fail("$what '$abs' contains whitespace or quotes - not representable in a vhost")
        if $abs =~ /[\s"']/;
    return $abs;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or fail("cannot read $path: $!");
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub write_conf {
    my ( $path, $text ) = @_;
    fail("$SITES_DIR does not exist (is nginx installed?)")
        unless -d $SITES_DIR;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or fail("write $tmp: $!");
    print {$fh} $text;
    close $fh or fail("close $tmp: $!");
    rename $tmp, $path or do {
        unlink $tmp;
        fail("rename $tmp -> $path: $!");
    };
    return;
}

sub vhost_path {
    my ($domain) = @_;
    return "$SITES_DIR/$domain.conf";
}

# ---------- add ----------

sub cmd_add {
    my %o = ( docroot => '', cgibin => '', fcgi => 0, port => 80, force => 0 );
    Getopt::Long::GetOptions(
        'docroot=s' => \$o{docroot},
        'cgibin=s'  => \$o{cgibin},
        'fcgi'      => \$o{fcgi},
        'port=i'    => \$o{port},
        'force'     => \$o{force},
    ) or usage(2);
    my ($domain) = @ARGV;
    check_domain($domain);
    fail('add needs --docroot (the site public_html)') unless length $o{docroot};
    fail("--port must be 1-65535, not '$o{port}'")
        if $o{port} !~ /^\d+$/ || $o{port} < 1 || $o{port} > 65535;
    my $docroot = check_dir_opt( '--docroot', $o{docroot}, '' );
    # cgi-bin defaults to the docroot's sibling - the layout `lazysite
    # provision` and the shipped templates assume; a different one is fine
    # (the vhost carries explicit paths throughout).
    my $cgibin = check_dir_opt(
        '--cgibin',
        length $o{cgibin} ? $o{cgibin} : dirname($docroot) . '/cgi-bin',
        "\n(provision the site first: sudo -u SITEUSER lazysite provision ...)"
    );
    require_root('add');

    my $pattern = $o{fcgi} ? 'fcgi' : 'cgi';
    my $text    = slurp( template_dir() . "/vhost-$pattern.conf.example" );
    my %fill    = (
        '__DOMAIN__'  => $domain,
        '__DOCROOT__' => $docroot,
        '__CGIBIN__'  => $cgibin,
        '__PORT__'    => $o{port},
    );
    $text =~ s/(__[A-Z]+__)/
        exists $fill{$1} ? $fill{$1}
            : fail("template placeholder $1 is unknown to this tool - version mismatch?")
    /ge;

    my $out = vhost_path($domain);
    fail("$out already exists - use --force to overwrite it")
        if -e $out && !$o{force};
    write_conf( $out, $text );
    print "==> wrote $out (pattern: $pattern)\n\n";

    # Enablement is printed, never run: linking sites-enabled and
    # reloading nginx are host-wide actions the operator should see and
    # choose. Both patterns need fcgiwrap - it runs the CGI path
    # (/manager, /login, /dav, plugin endpoints) even when the pool
    # serves the visitor pages.
    print "This vhost runs lazysite's CGI path through fcgiwrap (once per host):\n"
        . "    apt-get install fcgiwrap\n\n"
        . "Next steps:\n"
        . "    ln -s ../sites-available/$domain.conf /etc/nginx/sites-enabled/$domain.conf\n"
        . "    nginx -t\n"
        . "    systemctl reload nginx\n"
        . "    # HTTPS: certbot --nginx -d $domain (extends the server block)\n";
    if ( $o{fcgi} ) {
        print "\nThe FastCGI pool must exist before pages render:\n"
            . "    /etc/lazysite/pools/$domain.conf (DOCROOT=, USER=, ...)\n"
            . "    systemctl enable --now lazysite\@$domain\n"
            . "    (see the lazysite-common README.Debian for the pool pattern)\n";
    }
    return 0;
}

# ---------- remove ----------

sub cmd_remove {
    Getopt::Long::GetOptions() or usage(2);
    my ($domain) = @ARGV;
    check_domain($domain);
    require_root('remove');

    my $out = vhost_path($domain);
    fail("no vhost file at $out - nothing removed") unless -f $out;
    unlink $out or fail("unlink $out: $!");
    print "==> removed $out\n"
        . "Site content was NOT touched. If the site was enabled:\n"
        . "    rm /etc/nginx/sites-enabled/$domain.conf\n"
        . "    systemctl reload nginx\n";
    return 0;
}

__END__

=head1 NAME

lazysite-nginx-vhost - render lazysite nginx server blocks into sites-available

=head1 SYNOPSIS

  lazysite-nginx-vhost add DOMAIN --docroot D [--cgibin C] [--fcgi]
                           [--port N] [--force]
  lazysite-nginx-vhost remove DOMAIN

=head1 DESCRIPTION

The nginx glue command shipped by the C<lazysite-nginx> package. It
renders one of the shipped server-block templates
(F</usr/share/lazysite-nginx/vhost-cgi.conf.example> or
F<vhost-fcgi.conf.example>) into
F</etc/nginx/sites-available/DOMAIN.conf>, substituting the domain and
the site's docroot/cgi-bin paths. It is a host integrator in the
C<lazysite-hestia-domain> mould: root-run (it writes F</etc>), but it
B<never writes into a site tree> and B<never> links sites-enabled or
reloads nginx for you - the exact commands are printed so the host-wide
actions stay visible operator choices.

nginx has no CGI engine of its own: both patterns run lazysite's CGI
endpoints through B<fcgiwrap> (Debian's socket at
F</run/fcgiwrap.socket>). The plain-CGI pattern routes every page miss
that way; the FastCGI-pool pattern - B<the recommended production shape
on nginx> - speaks native FastCGI to the persistent
C<lazysite@DOMAIN> pool socket for anonymous page traffic and carves
session-bearing requests out to the CGI auth wrapper (the pool is
anonymous by design). Provision the site first, as the site user (see
lazysite(1)); then wire the vhost; then enable it. The full multi-server
wiring reference is F<docs/reference/webserver-wiring.md> in the
lazysite source (also shipped in F</usr/share/doc/lazysite-nginx/>).

=head1 VERBS

=over 4

=item B<add> DOMAIN --docroot D [--cgibin C] [--fcgi] [--port N] [--force]

Render the server block for DOMAIN. C<--docroot> is the site's
public_html; C<--cgibin> defaults to the C<cgi-bin> sibling next to the
docroot (the layout C<lazysite provision> produces). Both must exist -
provision before wiring. C<--fcgi> selects the FastCGI-pool pattern;
the default is plain CGI via fcgiwrap. C<--port> sets the listen port
(default 80); HTTPS is left to C<certbot --nginx -d DOMAIN>. An
existing vhost file is refused unless C<--force> is given.

After writing, the fcgiwrap install line and the
sites-enabled/C<nginx -t>/reload steps are printed. With C<--fcgi>, the
pool config and C<systemctl enable --now lazysite@DOMAIN> reminder are
printed too.

=item B<remove> DOMAIN

Delete F<sites-available/DOMAIN.conf>. Site content is B<never>
deleted; the sites-enabled unlink and reload are printed, not run.

=back

=head1 ENVIRONMENT

C<LAZYSITE_NGINX_SITES_DIR> relocates the output directory (used by the
test suite; useful on non-Debian layouts). Setting it also waives the
root requirement - root is demanded only because the default target is
under F</etc>.

=head1 EXIT STATUS

0 on success; 1 on refusals and failures; 2 on usage errors.

=head1 SEE ALSO

lazysite(1), lazysite-apache-vhost(1), and
F</usr/share/doc/lazysite-nginx/README.Debian> for the per-domain
walk-through and the pattern recommendation.

=cut
