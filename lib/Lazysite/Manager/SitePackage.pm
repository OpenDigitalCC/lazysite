package Lazysite::Manager::SitePackage;

# SM158: per-domain (per-site) portable package - create/export/import/apply one
# domain's SITE (its content root + nav + bundled theme/layout + a manifest of
# the presentation keys) so an agency demo can be handed to a client's own
# instance, or a site moved between domains/instances. Deliberately EXCLUDES
# plugins, instance/site settings and auth secrets, so a package carries no
# secrets and can be self-service (unlike the whole-docroot `full` backup, which
# is system-user only). This module is the SINGLE source of the packaging logic,
# shared by the manager control-API, MCP and the `lazysite-site` CLI.
#
# Package layout (a .tar.gz alongside the ordinary backups):
#   site.json         - manifest (source host, the 7 presentation keys, nav mode)
#   content/          - the domain's content_root subtree (pages + assets)
#   nav               - the domain's nav_file OVERRIDE (only when it has one;
#                       a base-inherited nav is NOT packaged - see nav mode)
#   layout/           - the referenced layout dir, pruned to the one theme
#
# HARD SCOPE LINE: like the rest of the domains tooling, this owns only the
# lazysite side. Access control (manage_content + dav_scope) is enforced by the
# callers before they invoke package_create/package_apply.
use strict;
use warnings;
use POSIX                      qw(strftime);
use File::Path                 qw(make_path remove_tree);
use File::Copy                 qw(copy);
use File::Basename             qw(dirname basename);
use File::Find                 ();
use JSON::PP                   qw(encode_json);
use Lazysite::Util             qw(log_event);
use Lazysite::Manager::Domains ();
use Exporter 'import';
our @EXPORT_OK = qw(package_create);

our $DOCROOT   = '';
our $auth_user = '';

# The 7 presentation keys that define a site (mirrors Domains @DOMAIN_KEYS).
my @KEYS = qw(content_root site_url site_name theme layout nav_file search_default);

sub _backups_dir { return "$DOCROOT/lazysite/backups" }

# Resolve a host to its domains_list row (the primary answers to '(default)').
sub _domain_row {
    my ($host) = @_;
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my $dl = Lazysite::Manager::Domains::domains_list();
    for my $r ( @{ $dl->{domains} || [] } ) {
        return $r if lc( $r->{host} // '' ) eq lc( $host // '' );
        return $r if $r->{is_primary} && ( $host eq '(default)' || $host eq '' );
    }
    return undef;
}

# Recursive copy of regular files + dirs only (skips symlinks/specials, so a
# content tree cannot smuggle a link out). Core Perl, no external cp.
sub _copy_tree {
    my ( $src, $dst ) = @_;
    $src =~ s{/+$}{};
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p      = $File::Find::name;
                my $rel    = ( $p eq $src ) ? '' : substr( $p, length($src) + 1 );
                my $target = length $rel    ? "$dst/$rel" : $dst;
                if    ( -l $p ) { return }               # never follow/copy links
                elsif ( -d $p ) { make_path($target) }
                elsif ( -f $p ) { make_path( dirname($target) ); copy( $p, $target ) }
            },
        },
        $src
    );
    return;
}

# package_create($host, %opt) - build a portable package for one domain's site.
# Requires the domain to have its OWN content_root (a domain with none serves the
# default site - there is nothing site-specific to package). Returns
# { ok, name, size, manifest } or { ok=>0, error }.
sub package_create {
    my ( $host, %opt ) = @_;
    my $row = _domain_row($host)
        or return { ok => 0, kind => 'not-found', error => "Not a registered domain: $host" };

    my %keys  = map { $_ => ( $row->{$_} // '' ) } @KEYS;
    my $croot = $keys{content_root};
    return { ok => 0, kind => 'invalid',
        error => "$host serves the default site (no content root of its own) - nothing to package" }
        unless length $croot;

    my $content_src = "$DOCROOT/$croot";
    return { ok => 0, kind => 'not-found', error => "Content folder not found: $croot" }
        unless -d $content_src;

    my $ts       = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $safehost = $row->{is_primary} ? 'default' : ( lc($host) =~ s/[^a-z0-9.-]/_/gr );
    my $name     = "lazysite-site-$safehost-$ts.tar.gz";
    my $dir      = _backups_dir();
    make_path($dir) unless -d $dir;
    my $stage = "$dir/.stage-$safehost-$ts-$$";
    remove_tree($stage) if -e $stage;
    make_path($stage);

    my $cleanup = sub { remove_tree($stage) if -d $stage };

    # 1. content_root subtree -> content/
    _copy_tree( $content_src, "$stage/content" );

    # 2. nav: package the OVERRIDE only. A base-inherited nav (nav_file unset or
    # pointing at the infra lazysite/nav.conf) is NOT packaged - the target's
    # base nav applies; the manifest records this so apply can flag it.
    my $nav_mode = 'base-inherited';
    my $nf       = $keys{nav_file};
    if ( length $nf && $nf !~ m{^lazysite/} && $nf !~ m{(?:^|/)\.\.(?:/|$)} ) {
        my $nav_src = "$DOCROOT/$nf";
        if ( -f $nav_src ) {
            copy( $nav_src, "$stage/nav" );
            $nav_mode = 'override';
        }
    }

    # 3. layout + theme -> layout/, pruned to the referenced theme so a shared
    # layout does not drag other clients' themes along.
    my $layout = $keys{layout};
    my $theme  = $keys{theme};
    if ( length $layout && $layout =~ /^[A-Za-z0-9_-]+$/ ) {
        my $layout_src = "$DOCROOT/lazysite/layouts/$layout";
        if ( -d $layout_src ) {
            _copy_tree( $layout_src, "$stage/layout" );
            my $themes_dir = "$stage/layout/themes";
            if ( -d $themes_dir && length $theme && $theme =~ /^[A-Za-z0-9_-]+$/ ) {
                if ( opendir my $dh, $themes_dir ) {
                    for my $t ( readdir $dh ) {
                        next if $t eq '.' || $t eq '..' || $t eq $theme;
                        remove_tree("$themes_dir/$t");
                    }
                    closedir $dh;
                }
            }
        }
    }

    # 4. manifest
    my $manifest = {
        site_package => 1,
        created      => $ts,
        source_host  => ( $row->{is_primary} ? '(default)' : lc $host ),
        keys         => \%keys,
        nav          => $nav_mode,
        layout       => $layout,
        theme        => $theme,
    };
    if ( open my $mf, '>:utf8', "$stage/site.json" ) {
        print {$mf} JSON::PP->new->canonical->pretty->encode($manifest);
        close $mf;
    }
    else {
        $cleanup->();
        return { ok => 0, error => 'Could not write the package manifest' };
    }

    # 5. archive the staged tree, then drop the stage
    my $out = "$dir/$name";
    my $rc  = system( 'tar', 'czf', $out, '-C', $stage, '.' );
    $cleanup->();
    return { ok => 0, error => 'Packaging failed (tar)' } if $rc != 0 || !-f $out;

    my @st = stat $out;
    log_event( 'INFO', 'site-package-create', 'site packaged',
        host => $host, file => $name, user => $auth_user );
    return {
        ok       => 1,
        name     => $name,
        size     => ( $st[7] // 0 ),
        host     => ( $row->{is_primary} ? '(default)' : lc $host ),
        manifest => $manifest,
    };
}

1;
