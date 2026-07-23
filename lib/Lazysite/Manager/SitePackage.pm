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
use Cwd                        qw(realpath);
use File::Path                 qw(make_path remove_tree);
use File::Copy                 qw(copy);
use File::Basename             qw(dirname basename);
use File::Find                 ();
use JSON::PP                   qw(encode_json decode_json);
use Lazysite::Util             qw(log_event);
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Common  qw(_write_conf_key);
use Lazysite::Manager::Themes  qw(_mirror_theme_assets);      # SM193: mirror on apply
use Exporter 'import';
our @EXPORT_OK = qw(package_create package_apply apply_and_configure package_inspect);

our $DOCROOT   = '';
our $auth_user = '';

# The 7 presentation keys that define a site (mirrors Domains @DOMAIN_KEYS).
# SM158 + SM185: the presentation keys that travel in a package. lang/lang_group
# (SM179) are carried so an exported/migrated site keeps its language - a package
# is a faithful copy of the source's presentation, and language is part of it.
my @KEYS = qw(content_root site_url site_name theme layout nav_file search_default
    lang lang_group);

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
# SM185: copy the DEFAULT site's content (the docroot root) into $dst, excluding
# lazysite/ (infra + secrets), every registered ADDITIONAL domain's content root
# (those belong to other sites), and the generated .html render caches that sit
# beside a .md source. Used only for the primary/default-site package.
sub _copy_base_content {
    my ($dst) = @_;
    my %skip = ( lazysite => 1 );
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my $dl = Lazysite::Manager::Domains::domains_list();
    for my $r ( @{ $dl->{domains} || [] } ) {
        next if $r->{is_primary};
        ( my $cr = $r->{content_root} // '' ) =~ s{^/+|/+$}{}g;
        $skip{$cr} = 1 if length $cr;
    }
    my $src = $DOCROOT;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p   = $File::Find::name;
                my $rel = ( $p eq $src ) ? '' : substr( $p, length($src) + 1 );
                if ( length $rel ) {
                    for my $ex ( keys %skip ) {
                        next unless $rel eq $ex || index( $rel, "$ex/" ) == 0;
                        $File::Find::prune = 1 if -d $p;
                        return;
                    }
                }
                my $target = length $rel ? "$dst/$rel" : $dst;
                if    ( -l $p ) { return }
                elsif ( -d $p ) { make_path($target) }
                elsif ( -f $p ) {
                    return if $p =~ /\.html\z/ && -f ( $p =~ s/\.html\z/.md/r );
                    make_path( dirname($target) );
                    copy( $p, $target );
                }
            },
        },
        $src
    );
    return;
}

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

    # SM185: the DEFAULT/primary site served at the docroot ROOT (no content_root
    # of its own) is still packageable - its content is the docroot minus
    # lazysite/ (infra + secrets) and minus every OTHER domain's content root. An
    # ADDITIONAL domain with no content root just mirrors the default, so there is
    # nothing site-specific to package.
    my $primary_base = ( !length $croot && $row->{is_primary} ) ? 1 : 0;
    return { ok => 0, kind => 'invalid',
        error => "$host serves the default site (no content root of its own) - nothing to package" }
        unless length $croot || $primary_base;

    my $content_src = $primary_base ? $DOCROOT : "$DOCROOT/$croot";
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

    # 1. content -> content/. For the primary/default site that means the docroot
    # root with the infra + other domains excluded; for a domain, its subtree.
    if ($primary_base) { _copy_base_content("$stage/content") }
    else               { _copy_tree( $content_src, "$stage/content" ) }

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

# --- public: apply a package to a target content root ----------------------

# Safely extract a site package to a staging dir and return its path + manifest,
# or ( undef, $err ). Uses the SEC-2026-07 M-TAR flags (no setuid/owner from the
# archive) AND extracts to an ISOLATED staging dir - never straight onto the
# docroot - so a hostile `../` member cannot escape; the caller copies only the
# vetted subtrees across. Rejects a member whose resolved path leaves the stage.
sub _extract_package {
    my ( $pkg, $stage ) = @_;
    make_path($stage);
    my $rc = system( 'tar', 'xzf', $pkg, '-C', $stage,
        '--no-same-owner', '--no-same-permissions' );
    return ( undef, 'Could not read the package (bad archive)' ) if $rc != 0;

    # Belt-and-braces: no extracted path may resolve outside the stage, and no
    # symlinks are honoured (a package is data, not links).
    my $real_stage = realpath($stage) // $stage;
    my $escaped    = 0;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                if ( -l $p ) { unlink $p; return }    # drop any symlink outright
                my $rp = realpath($p) // return;
                $escaped = 1
                    unless $rp eq $real_stage || index( $rp, "$real_stage/" ) == 0;
            },
        },
        $stage
    );
    return ( undef, 'Package contains an unsafe path' ) if $escaped;

    my $mf = "$stage/site.json";
    return ( undef, 'Not a lazysite site package (no manifest)' ) unless -f $mf;
    my $manifest = eval {
        open my $fh, '<:utf8', $mf or die;
        local $/;
        decode_json(<$fh>);
    };
    return ( undef, 'Package manifest is unreadable' )
        unless ref $manifest eq 'HASH' && $manifest->{site_package};
    return ( $manifest, undef );
}

# package_inspect($pkg_path) - read a site package's manifest WITHOUT applying it
# (SM183). Reuses the M-TAR-safe extractor into a THROWAWAY staging dir, reads the
# manifest, counts the content files, then drops the stage. Read-only: nothing on
# the live docroot changes. The CALLER enforces access (manage_domains + scope).
# Returns { ok, manifest, content_files, has_nav, has_layout } or { ok=>0, error }.
sub package_inspect {
    my ($pkg) = @_;
    return { ok => 0, error => 'Package not found' } unless defined $pkg && -f $pkg;

    my $stage = "$DOCROOT/lazysite/backups/.inspect-$$-" . strftime( '%H%M%S', gmtime );
    remove_tree($stage) if -e $stage;
    my ( $manifest, $err ) = _extract_package( $pkg, $stage );
    unless ($manifest) {
        remove_tree($stage) if -d $stage;
        return { ok => 0, error => $err };
    }

    my $files = 0;
    if ( -d "$stage/content" ) {
        File::Find::find(
            { no_chdir => 1, wanted => sub { $files++ if -f $File::Find::name } },
            "$stage/content" );
    }
    my $has_nav    = -f "$stage/nav" ? 1 : 0;
    my $has_layout = -d "$stage/layout" ? 1 : 0;
    remove_tree($stage) if -d $stage;

    return { ok => 1, manifest => $manifest, content_files => $files,
        has_nav => $has_nav, has_layout => $has_layout };
}

# package_apply($pkg_path, %opt) - apply an (already-safe-located) site package
# to a TARGET content root on this instance. The CALLER is responsible for access
# control (manage_content + scope) and for taking a safety snapshot first; this
# does the extraction, the confined content copy, the theme/layout install, and
# the nav placement, then RETURNS the manifest keys so the caller writes the
# per-domain presentation config (content_root/site_url/... via domain_set or a
# base config write - a policy decision that lives with the caller).
#
# %opt:
#   content_root  (required) - docroot-relative dir to receive the content
#   clean         (bool) - remove existing files under content_root first
sub package_apply {
    my ( $pkg, %opt ) = @_;
    return { ok => 0, error => 'Package not found' } unless defined $pkg && -f $pkg;

    my $croot = $opt{content_root} // '';
    $croot =~ s{^/+|/+$}{}g;
    return { ok => 0, kind => 'invalid', error => 'A target content_root is required' }
        unless length $croot;
    return { ok => 0, kind => 'invalid', error => 'Invalid target content_root' }
        if $croot =~ m{(?:^|/)\.\.(?:/|$)} || $croot =~ m{^lazysite(?:/|$)};

    my $stage = "$DOCROOT/lazysite/backups/.apply-$$-" . strftime( '%H%M%S', gmtime );
    remove_tree($stage) if -e $stage;
    my ( $manifest, $err ) = _extract_package( $pkg, $stage );
    unless ($manifest) {
        remove_tree($stage) if -d $stage;
        return { ok => 0, kind => 'invalid', error => $err };
    }
    my $cleanup = sub { remove_tree($stage) if -d $stage };

    # 1. content -> target content_root (confined). Optionally clear first.
    my $target = "$DOCROOT/$croot";
    if ( $opt{clean} && -d $target ) {
        my $rt = realpath($target)  // '';
        my $rd = realpath($DOCROOT) // '';
        if ( length $rt
            && length $rd
            && $rt ne $rd
            && index( $rt, "$rd/" ) == 0
            && $rt !~ m{/lazysite(?:/|$)} )
        {
            remove_tree($target);
        }
    }
    make_path($target) unless -d $target;
    _copy_tree( "$stage/content", $target ) if -d "$stage/content";

    # 2. theme + layout: install the bundled layout/<...>/themes/<theme> if the
    # target does not already have that layout. Never overwrite an existing
    # layout (another site may share it) - only fill a gap.
    my $layout = $manifest->{layout} // '';
    my $theme  = $manifest->{theme}  // '';
    my $layout_installed;
    if ( length $layout
        && $layout =~ /^[A-Za-z0-9_-]+$/
        && -d "$stage/layout" )
    {
        my $ldst = "$DOCROOT/lazysite/layouts/$layout";
        if ( !-d $ldst ) {
            _copy_tree( "$stage/layout", $ldst );
            $layout_installed = $layout;
        }
        elsif ( length $theme
            && $theme =~ /^[A-Za-z0-9_-]+$/
            && !-d "$ldst/themes/$theme"
            && -d "$stage/layout/themes/$theme" )
        {
            # Layout present but missing this theme - add just the theme.
            _copy_tree( "$stage/layout/themes/$theme", "$ldst/themes/$theme" );
            $layout_installed = "$layout/$theme";
        }
    }

    # SM193: mirror the installed layout's theme assets to /lazysite-assets/ so the
    # applied site renders STYLED immediately - the same mirror step layout
    # activation performs. Previously an applied site was unstyled until a later
    # activation hand-built the mirror (mirror-at-activation gotcha). Best-effort:
    # a mirror failure must not fail the apply.
    if ( length $layout
        && length $theme
        && $layout =~ /^[A-Za-z0-9_-]+$/
        && $theme  =~ /^[A-Za-z0-9_-]+$/
        && -d "$DOCROOT/lazysite/layouts/$layout/themes/$theme" )
    {
        local $Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
        local $Lazysite::Manager::Themes::LAZYSITE_DIR = "$DOCROOT/lazysite";
        eval { _mirror_theme_assets( $layout, $theme ); 1 }
            or log_event( 'WARN', 'site-package-apply',
            'asset mirror failed after apply', layout => $layout, theme => $theme );
    }

    # 3. nav override -> a nav file inside the target content root (only when the
    # package carried an override). The caller points the domain's nav_file at it.
    my $nav_rel;
    if ( $manifest->{nav} && $manifest->{nav} eq 'override' && -f "$stage/nav" ) {
        copy( "$stage/nav", "$target/nav.conf" );
        $nav_rel = "$croot/nav.conf";
    }

    $cleanup->();
    log_event( 'INFO', 'site-package-apply', 'site package applied',
        content_root => $croot, user => $auth_user );

    # Presentation keys the caller should write for the target domain - taken
    # from the manifest but with content_root/nav_file rewritten to the TARGET's
    # actual locations (the source paths do not apply on this instance).
    my %keys = %{ $manifest->{keys} || {} };
    $keys{content_root} = $croot;
    if ( defined $nav_rel ) { $keys{nav_file} = $nav_rel }
    else                    { delete $keys{nav_file} }    # inherit base nav

    return {
        ok               => 1,
        content_root     => $croot,
        keys             => \%keys,
        nav              => ( $nav_rel ? 'override' : 'base-inherited' ),
        layout_installed => $layout_installed,
        source_host      => ( $manifest->{source_host} // '' ),
    };
}

# apply_and_configure($pkg, %opt) - package_apply PLUS write the target domain's
# presentation keys from the applied manifest, so a caller (CLI/MCP) gets the
# full "apply a site onto a domain" operation in one call. The manager-api does
# this inline (it also does the scope check + safety snapshot); this is the
# shared version for callers that manage those concerns themselves.
#   %opt: host (target registered domain; '' or '(default)' = primary/base),
#         content_root (target dir; for a host it defaults to that domain's
#         content_root), clean.
sub apply_and_configure {
    my ( $pkg, %opt ) = @_;
    my $host = lc( $opt{host} // '' );
    $host = '' if $host eq '(default)';

    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my $croot = $opt{content_root} // '';
    if ( length $host && !length $croot ) {
        my ($row) = grep { lc( $_->{host} // '' ) eq $host }
            @{ Lazysite::Manager::Domains::domains_list()->{domains} || [] };
        return { ok => 0, kind => 'not-found', error => "Not a registered domain: $host" }
            unless $row;
        $croot = $row->{content_root} // '';
        return { ok => 0, kind => 'invalid',
            error => "$host has no content folder of its own; pass --content-root" }
            unless length $croot;
    }

    my $ap = package_apply( $pkg, content_root => $croot, clean => $opt{clean} );
    return $ap unless $ap->{ok};

    my $keys = $ap->{keys} || {};
    # SM193: by DEFAULT keep the target domain's own identity - do not stamp the
    # source package's site_url / site_name onto it. That is right for cloning a
    # site as-is (a handoff) but wrong for migrating a package onto a NEW domain
    # (it would set the target's URL/name to the source's). Pass
    # adopt_identity => 1 (--adopt-source-identity) to take the package's instead.
    # The portable presentation keys (theme/layout/nav/content_root) are unaffected.
    unless ( $opt{adopt_identity} ) {
        delete @{$keys}{qw(site_url site_name)};
    }
    for my $k ( sort keys %$keys ) {
        my $v = $keys->{$k};
        next unless defined $v && length $v;
        if ( length $host ) { Lazysite::Manager::Domains::domain_set( $host, $k, $v ) }
        else                { _write_conf_key( $k, $v ) }
    }
    $ap->{applied_to}    = length $host         ? $host : '(default)';
    $ap->{identity_kept} = $opt{adopt_identity} ? 0     : 1;
    return $ap;
}

1;
