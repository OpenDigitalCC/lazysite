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
use File::Basename             qw(dirname);
use File::Find                 ();
use JSON::PP                   qw(decode_json);
use Lazysite::Util             qw(log_event);
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Common  qw(_write_conf_key);
use Lazysite::Manager::Themes  qw(_mirror_theme_assets);         # SM193: mirror on apply
use Lazysite::Private          ();    # SM286: what a package cannot carry
use Lazysite::Manager::Backups qw(_claim_name _apply_retention); # SM546: loaded where it is called; SM545: the O_EXCL claim
use Lazysite::Paths            ();
use Exporter 'import';
our @EXPORT_OK = qw(package_create package_apply apply_and_configure package_inspect);

our $DOCROOT = '';

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
our $auth_user = '';

# The 7 presentation keys that define a site (mirrors Domains @DOMAIN_KEYS).
# SM158 + SM185: the presentation keys that travel in a package. lang/lang_group
# (SM179) are carried so an exported/migrated site keeps its language - a package
# is a faithful copy of the source's presentation, and language is part of it.
my @KEYS = qw(content_root site_url site_name theme layout nav_file search_default
    lang lang_group);

sub _backups_dir { return _lz() . "/backups" }

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
    my @failed;    # SM559: returned, never shared - the caller labels them
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
                elsif ( -d $p ) {
                    # SM484: an unreadable DIRECTORY is where the silent omission
                    # happened - File::Find cannot descend, so no copy() ever fails
                    # and the subtree just never exists. Collected and pruned, so
                    # the package can say what it does not carry.
                    unless ( -r $p && -x $p ) {
                        push @failed, substr( $p, length($src) + 1 ) . '/';
                        $File::Find::prune = 1;
                        return;
                    }
                    make_path($target);
                }
                elsif ( -f $p ) {
                    return if $p =~ /\.html\z/ && -f ( $p =~ s/\.html\z/.md/r );
                    make_path( dirname($target) );
                    copy( $p, $target )
                        or push @failed, substr( $p, length($src) + 1 );
                }
            },
        },
        $src
    );
    return @failed;
}

sub _copy_tree {
    my ( $src, $dst ) = @_;
    $src =~ s{/+$}{};
    my @failed;    # SM559: returned, never shared - the caller labels them

    # SM268 03-F12: never descend into the destination. The staging directory
    # lives under lazysite/backups/, and a domain whose content_root resolves to
    # the docroot itself put the destination INSIDE the source - so the copy fed
    # itself, nesting content/lazysite/backups/.stage-.../content/... about fifty
    # deep until the kernel refused the path length, and died uncaught inside a
    # CGI (500, no useful message) leaving a tree ordinary cleanup will not
    # remove. Repeatable at will by a manage_domains holder.
    #
    # The reachable route is closed upstream by refusing such a content_root;
    # this is the second line, and it is the one that holds whatever a future
    # caller passes.
    ( my $dst_pfx = $dst ) =~ s{/+$}{};

    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                if ( $p eq $dst_pfx || index( $p, "$dst_pfx/" ) == 0 ) {
                    $File::Find::prune = 1;
                    return;
                }
                my $rel    = ( $p eq $src ) ? '' : substr( $p, length($src) + 1 );
                my $target = length $rel    ? "$dst/$rel" : $dst;
                if    ( -l $p ) { return }    # never follow/copy links
                elsif ( -d $p ) {
                    # SM484: an unreadable DIRECTORY is where the silent omission
                    # happened - File::Find cannot descend, so no copy() ever fails
                    # and the subtree just never exists. Collected and pruned, so
                    # the package can say what it does not carry.
                    unless ( -r $p && -x $p ) {
                        push @failed, substr( $p, length($src) + 1 ) . '/';
                        $File::Find::prune = 1;
                        return;
                    }
                    make_path($target);
                }
                elsif ( -f $p ) {
                    make_path( dirname($target) );
                    copy( $p, $target )
                        or push @failed, ( length $rel ? $rel : $p );
                }
            },
        },
        $src
    );
    return @failed;
}

# package_create($host, %opt) - build a portable package for one domain's site.
# Requires the domain to have its OWN content_root (a domain with none serves the
# default site - there is nothing site-specific to package). Returns
# { ok, name, size, manifest } or { ok=>0, error }.
sub package_create {
    my ( $host, %opt ) = @_;
    my $row = _domain_row($host)
        or return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" };

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
    my $dir      = _backups_dir();
    make_path($dir) unless -d $dir;

    # SM545: the name is CLAIMED, exactly as a manual snapshot's is (SM268
    # 03-F9). It was host + a one-second stamp written by an overwriting tar,
    # so two creates in the same second - an agent looping site_backup - were
    # two successes and one file, the first silently replaced. The claim takes
    # the -2 suffix on a collision; tar then writes through the placeholder.
    my ( $out, $name ) = _claim_name( $dir, "site-$safehost" );
    return { ok => 0, error => 'Packaging failed: could not claim a package name' }
        unless defined $name;
    ( my $stage = "$dir/.stage-$name-$$" ) =~ s/\.tar\.gz-(\d+)\z/-$1/;
    remove_tree($stage) if -e $stage;
    make_path($stage);

    my $cleanup = sub { remove_tree($stage) if -d $stage };

    # A failure after the claim must take the placeholder with it, or a create
    # that reported failure leaves an empty package in the listing.
    my $abandon = sub { $cleanup->(); unlink $out };

    # 1. content -> content/. For the primary/default site that means the docroot
    # root with the infra + other domains excluded; for a domain, its subtree.
    # SM559: the walker RETURNS what it could not read. Nothing is shared
    # between calls, so a later call can never report an earlier one's
    # failures, and the layout's failures below are the layout's.
    my @unreadable =
        $primary_base
        ? _copy_base_content("$stage/content")
        : _copy_tree( $content_src, "$stage/content" );

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
    my @unreadable_layout;
    if ( length $layout && $layout =~ /^[A-Za-z0-9_-]+$/ ) {
        my $layout_src = _lz() . "/layouts/$layout";
        if ( -d $layout_src ) {
            push @unreadable_layout,
                map { "lazysite/layouts/$layout/" . $_ }
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

    # 3b. DATA (DP-6). OPT-IN, AND THE TABLES ARE NAMED.
    #
    # Opt-in is the release manager's decision (2026-08-22): a package is a
    # portable hand-over artefact, so shipping table contents by default means
    # handing a third party whatever an operator put in a directory or a
    # contact table.
    #
    # NAMED rather than a boolean, and that came out of the build rather than
    # the decision: the data store is INSTANCE-WIDE - one
    # lazysite/db/data.sqlite for the whole install, not one per domain. So
    # "this domain's data" does not exist. A boolean would have swept every
    # table on the instance, including another domain's, into the one artefact
    # that travels between organisations - which is the risk the opt-in was
    # chosen to avoid, arriving from a direction the decision did not consider.
    #
    # Each table is exported as typed JSON rather than as the SQLite file:
    # it restores into a FRESH database on any engine, it can be read before
    # being handed over, and a decimal keeps its trailing zeros because the
    # serialiser writes it as a string (D8).
    my @data_carried;
    my @data_failed;
    my @wanted = grep { defined && length } @{ $opt{data_tables} || [] };
    if (@wanted) {
        require Lazysite::Data::Tables;
        require Lazysite::Data::Export;
        make_path("$stage/data");
        for my $t (@wanted) {
            my $d = Lazysite::Data::Tables::load_table( $DOCROOT, $t );
            unless ( $d->{ok} ) {
                push @data_failed, { table => $t, error => $d->{error} };
                next;
            }
            my $r = Lazysite::Data::Tables::export_all_rows( $DOCROOT, $t );
            unless ( $r->{ok} ) {
                push @data_failed, { table => $t, error => $r->{error} };
                next;
            }
            my $export = Lazysite::Data::Export::export_table( $d, $r->{rows} );
            my $path   = "$stage/data/$t.json";
            if ( open my $jf, '>:utf8', $path ) {
                my $ok = print {$jf} Lazysite::Data::Export::to_json($export);
                $ok = 0 unless close $jf;
                if ($ok) {
                    push @data_carried,
                        { table => $t, rows => scalar @{ $r->{rows} } };
                }
                else {
                    unlink $path;
                    push @data_failed,
                        { table => $t, error => 'could not write the export' };
                }
            }
            else {
                push @data_failed, { table => $t, error => "could not open $path" };
            }
        }
        # A NAMED TABLE THAT DID NOT MAKE IT FAILS THE PACKAGE. An operator who
        # asked for three tables and silently got two would hand over a package
        # they believe is complete.
        if (@data_failed) {
            $abandon->();
            return { ok => 0, kind => 'data',
                error => 'could not export: '
                    . join( ', ',
                    map { "$_->{table} ($_->{error})" } @data_failed ) };
        }
    }

    # WHAT WAS LEFT BEHIND IS REPORTED, exactly as SM286 reports gated content.
    # The reasoning is the same and it is the important half: the omission is
    # correct and completely silent, so the receiving operator would have no
    # way to learn that this instance has tables at all. A count, never the
    # rows.
    # `my ... if ...` is undefined behaviour in Perl - the variable is declared
    # once and keeps its value across calls - so the require and the listing are
    # unconditional and plain.
    require Lazysite::Data::Tables;
    require Lazysite::Data::Export;    # BP-4: the manifest uses its serialiser too
    my %carried      = map { $_->{table} => 1 } @data_carried;
    my @declared     = @{ Lazysite::Data::Tables::list_tables($DOCROOT) || [] };
    my $data_omitted = scalar grep { !$carried{$_} } @declared;

    # 4. manifest
    #
    # SM286: a package NEVER carries gated content, and says how much it left.
    #
    # Two independent reasons, either of which is sufficient. First, the ACL rules
    # live under lazysite/ and are deliberately not packaged - so gated content
    # extracted at the far end would arrive with no rules governing it, i.e.
    # published, on a site whose operator never chose to publish it. Second, a
    # package is the artefact that TRAVELS between organisations; someone else's
    # members-only content is not a thing to put on a courier by default.
    #
    # The store is a sibling of the docroot, so the copy above already misses it
    # without trying. That is exactly the danger: the omission is correct and
    # completely silent. Count it and report it - in the result to the operator
    # building the package, and in the manifest so the receiving operator learns
    # it from the package itself rather than from a gap they may not notice.
    # SM484: what the copy could not read reaches both the manifest (a
    # COUNT, never paths - it travels) and the returned result (site-relative
    # paths, for the operator building the package). SM559: the layout's
    # failures are reported as the layout's, under their own tree.
    my $private_omitted =
        Lazysite::Private::count_private( $DOCROOT, $primary_base ? '' : $croot );

    my $manifest = {
        site_package => 1,
        created      => $ts,
        source_host  => ( $row->{is_primary} ? '(default)' : lc $host ),
        keys         => \%keys,
        nav          => $nav_mode,
        layout       => $layout,
        theme        => $theme,

        # A count, never the paths. A filename is content: "members/2026-payroll"
        # discloses the thing the gate exists to protect, and this manifest
        # travels further than the content ever would.
        private_omitted           => $private_omitted,
        unreadable_omitted        => scalar(@unreadable),
        layout_unreadable_omitted => scalar(@unreadable_layout),

        # DP-6. `data_omitted` is the number of DECLARED tables this package
        # does not carry - the same shape as private_omitted, and there for the
        # same reason: a receiving operator learns from the package itself that
        # data exists, rather than from a gap they may never notice.
        data         => \@data_carried,
        data_omitted => $data_omitted,
    };
    if ( open my $mf, '>:utf8', "$stage/site.json" ) {
        print {$mf} Lazysite::Data::Export::to_json($manifest);
        close $mf;
    }
    else {
        $abandon->();
        return { ok => 0, error => 'Could not write the package manifest' };
    }

    # 5. archive the staged tree, then drop the stage
    my $rc = system( 'tar', 'czf', $out, '-C', $stage, '.' );
    $cleanup->();
    unless ( $rc == 0 && -f $out ) {
        unlink $out;
        return { ok => 0, error => 'Packaging failed (tar)' };
    }

    # SM183: a site package is the artefact that TRAVELS - between organisations,
    # by whatever channel is to hand - and applying it overwrites a site. Write
    # the digest beside it so the receiving operator can verify it arrived
    # intact, with sha256sum -c and no lazysite tooling at all.
    my $sha = Lazysite::Manager::Backups::write_sha256($out);

    # SM547: bounded like every other artefact kind (SM268 03-F11). This was
    # the one kind nothing ever bounded, and the one an agent produces most -
    # every site_backup call is a package. Per HOST, on the helper's own
    # doctrine that kinds are not interchangeable: on a shared instance,
    # packaging one domain must never expire another domain's packages.
    {
        local $Lazysite::Manager::Backups::DOCROOT      = $DOCROOT;
        local $Lazysite::Manager::Backups::LAZYSITE_DIR = _lz();
        _apply_retention("site-$safehost");
    }

    my @st = stat $out;
    log_event( 'INFO', 'site-package-create', 'site packaged',
        host                    => $host, file => $name, user => $auth_user,
        private_omitted         => $private_omitted,
        unreadable_count        => scalar(@unreadable),
        layout_unreadable_count => scalar(@unreadable_layout) );
    return {
        ok       => 1,
        name     => $name,
        sha256   => $sha,
        size     => ( $st[7] // 0 ),
        host     => ( $row->{is_primary} ? '(default)' : lc $host ),
        manifest => $manifest,

        # SM286: surfaced at the top level, not only inside the manifest, because
        # the operator reads the result and a UI shows what it is handed. A
        # package that quietly contains less of the site than its builder assumes
        # is discovered by the person applying it, in front of their client.
        private_omitted => $private_omitted,
        ( @unreadable        ? ( unreadable        => \@unreadable )        : () ),
        ( @unreadable_layout ? ( unreadable_layout => \@unreadable_layout ) : () ),
        ( $private_omitted
            ? ( notice => "$private_omitted protected "
                    . ( $private_omitted == 1 ? 'file is' : 'files are' )
                    . ' not in this package. Protected content stays on this site:'
                    . ' the rules that govern it are not packaged, so it would'
                    . ' arrive unprotected. Move it across separately if the'
                    . ' destination is meant to have it.' )
            : ()
        ),
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
# SM266: with a $target content root, inspect also answers what an apply would
# DO to that target - how many files it would add versus overwrite, and whether
# the bundled theme and layout are already installed. The Backups page showed a
# manifest and then a confirm button, which is the difference between "I have
# read the manifest" and "I know what this will change". Read-only: it extracts
# to the same scratch dir inspect already uses and never touches the target.
sub package_inspect {
    my ( $pkg, $target ) = @_;
    return { ok => 0, error => 'Package not found' } unless defined $pkg && -f $pkg;

    my $stage = _lz() . "/backups/.inspect-$$-" . strftime( '%H%M%S', gmtime );
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
    my $has_nav    = -f "$stage/nav"    ? 1 : 0;
    my $has_layout = -d "$stage/layout" ? 1 : 0;

    # SM266: the dry run. Counted against the target as it stands now.
    my $compare;
    if ( defined $target && length $target && -d "$stage/content" ) {
        my ( $add, $over ) = ( 0, 0 );
        ( my $root = $target ) =~ s{^/+|/+$}{}g;
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    return unless -f $File::Find::name;
                    my $rel = substr( $File::Find::name, length("$stage/content/") );
                    -e "$DOCROOT/$root/$rel" ? $over++ : $add++;
                },
            },
            "$stage/content"
        );
        my $theme  = $manifest->{theme};
        my $layout = $manifest->{layout};
        $compare = {
            added       => $add,
            overwritten => $over,
            # "already present" means the apply leaves it alone; "missing" means
            # the apply installs it. Both are fine - the point is that the
            # operator knows which before agreeing, not after.
            layout_present => ( defined $layout && length $layout
                    && -d _lz() . "/layouts/$layout" ) ? 1 : 0,
            theme_present => ( defined $theme && length $theme && defined $layout
                    && length $layout
                    && -d _lz() . "/layouts/$layout/themes/$theme" ) ? 1 : 0,
        };
    }
    remove_tree($stage) if -d $stage;

    # SM286: tell the RECEIVING operator that the source site held protected
    # content this package does not contain. They are the one about to apply it
    # and conclude they have the whole site; the number comes from the source's
    # own manifest, so they learn it from the package rather than from a gap.
    #
    # Absent on a package built before this, which is honestly different from
    # zero: `undef` means "this package cannot say", not "there was none".
    my $omitted = $manifest->{private_omitted};

    return { ok => 1, manifest => $manifest, content_files => $files,
        has_nav => $has_nav, has_layout => $has_layout,
        ( defined $omitted ? ( private_omitted => $omitted ) : () ),
        ( $omitted
            ? ( notice => "The source site had $omitted protected "
                    . ( $omitted == 1 ? 'file' : 'files' )
                    . ' that a package cannot carry, so this content is not here.' )
            : ()
        ),
        ( $compare ? ( compare => $compare ) : () ) };
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

    # SM268 03-F10: verify the digest BEFORE overwriting a site.
    #
    # The sidecar existed and nothing ever checked it: it was written, listed,
    # and read as assurance by an operator who had no way to know it was only
    # "a digest was recorded at some point". Apply is where that assurance is
    # actually spent - it overwrites a live site - so it is where the check has
    # to happen.
    #
    # A MISMATCH refuses: the artefact says it is not the one whose digest was
    # recorded, and the recorded digest is the only claim about it we have. An
    # ABSENT sidecar does not refuse - packages built before this existed have
    # none, and turning them into un-appliable files would break restore for
    # exactly the operators most likely to need it. The response says which it
    # was, so a caller can tell "verified" from "unverified".
    my $verified = Lazysite::Manager::Backups::verify_sha256($pkg);
    if ( $verified eq 'mismatch' ) {
        return { ok => 0, kind => 'integrity',
            error => 'This package does not match the digest recorded beside it '
                . '(' . ( $pkg =~ s{.*/}{}r ) . '.sha256). It has been altered or '
                . 'truncated since it was created - applying it would overwrite '
                . 'the site with content nobody vouched for. Fetch it again from '
                . 'its source, or delete the sidecar if you know the change was '
                . 'yours.' };
    }

    my $stage = _lz() . "/backups/.apply-$$-" . strftime( '%H%M%S', gmtime );
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
    # SM559: what the copies could not write, labelled by tree, is reported
    # in the result and logged - never left for a later call to find.
    my @copy_failed;
    push @copy_failed, map { 'content/' . $_ } _copy_tree( "$stage/content", $target )
        if -d "$stage/content";

    # 1b. DATA (DP-6). Restore only what the package actually carries, and
    # NEVER overwrite a table that already has rows.
    #
    # A package apply is how a site arrives on a new instance, and it is also
    # how somebody re-applies one onto an instance already in use. The second
    # case is the dangerous one: restoring over a populated table would replace
    # a live product list with a snapshot from whenever the package was built,
    # and the operator would have asked for a site, not for that.
    #
    # So an occupied table is REFUSED and reported. Migrating first is
    # deliberate too - the descriptor travels with the export, and rows cannot
    # go into a table that does not exist yet.
    my @data_restored;
    my @data_skipped;
    if ( -d "$stage/data" ) {
        require Lazysite::Data::Tables;
        require Lazysite::Data::Export;
        require JSON::PP;
        for my $jf ( sort glob "$stage/data/*.json" ) {
            my ($table) = $jf =~ m{/([a-z][a-z0-9_]*)\.json\z};
            unless ( defined $table ) {
                push @data_skipped,
                    { table => ( $jf =~ s{.*/}{}r ), why => 'not a table name' };
                next;
            }
            my $raw = do {
                if ( open my $fh, '<:utf8', $jf ) { local $/; <$fh> }
                else                              { undef }
            };
            my $export = defined $raw ? eval { JSON::PP->new->decode($raw) } : undef;
            unless ( ref $export eq 'HASH' ) {
                push @data_skipped, { table => $table, why => 'unreadable export' };
                next;
            }

            my $d = Lazysite::Data::Tables::load_table( $DOCROOT, $table );
            unless ( $d->{ok} ) {
                push @data_skipped,
                    { table => $table,
                    why => 'no descriptor on this instance - save it first' };
                next;
            }

            my $existing = Lazysite::Data::Tables::read_rows( $DOCROOT, $table, as => 'operator',
                limit => 1 );
            if ( $existing->{ok} && @{ $existing->{rows} || [] } ) {
                push @data_skipped,
                    { table => $table, why => 'the table already holds rows' };
                next;
            }

            my $sch = Lazysite::Data::Tables::apply_schema( $DOCROOT, $table );
            unless ( $sch->{ok} ) {
                push @data_skipped, { table => $table, why => $sch->{error} };
                next;
            }

            # THE SAME import the export was written for, so a restore cannot
            # put anything into the store that a write could not - and a
            # package whose shape no longer matches this instance's descriptor
            # is refused rather than coerced.
            my $imp = Lazysite::Data::Export::import_table( $d, $export );
            unless ( $imp->{ok} ) {
                push @data_skipped, { table => $table, why => $imp->{error} };
                next;
            }
            my $n = 0;
            for my $row ( @{ $imp->{rows} } ) {
                my $r = Lazysite::Data::Tables::insert_row( $DOCROOT, $table, $row );
                unless ( $r->{ok} ) {
                    push @data_skipped,
                        { table => $table, why => "row $n: $r->{error}" };
                    last;
                }
                $n++;
            }
            push @data_restored, { table => $table, rows => $n } if $n;
        }
    }

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
        my $ldst = _lz() . "/layouts/$layout";
        if ( !-d $ldst ) {
            push @copy_failed, map { 'layout/' . $_ } _copy_tree( "$stage/layout", $ldst );
            $layout_installed = $layout;
        }
        elsif ( length $theme
            && $theme =~ /^[A-Za-z0-9_-]+$/
            && !-d "$ldst/themes/$theme"
            && -d "$stage/layout/themes/$theme" )
        {
            # Layout present but missing this theme - add just the theme.
            push @copy_failed, map { "layout/themes/$theme/" . $_ }
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
        && -d _lz() . "/layouts/$layout/themes/$theme" )
    {
        local $Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
        local $Lazysite::Manager::Themes::LAZYSITE_DIR = _lz();
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
    log_event( 'WARN', 'site-package-apply', 'some files could not be written',
        content_root => $croot, user => $auth_user, count => scalar @copy_failed )
        if @copy_failed;

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
        # SM268 03-F10: 'verified' or 'absent' - a mismatch never reaches here.
        # The caller can then tell an integrity-checked apply from one where
        # nobody had made a claim to check against.
        integrity => $verified,
        ( @copy_failed ? ( copy_failed => \@copy_failed ) : () ),

        # DP-6. Both lists, always - `data_skipped` is the useful half, and a
        # caller that shows only what was restored would report a partial data
        # restore as a complete one.
        data_restored => \@data_restored,
        data_skipped  => \@data_skipped,
    };
}

# apply_and_configure($pkg, %opt) - package_apply PLUS write the target domain's
# presentation keys from the applied manifest, so a caller (CLI/MCP) gets the
# full "apply a site onto a domain" operation in one call. The manager-api does
# this inline (it also does the scope check + safety snapshot); this is the
# shared version for callers that manage those concerns themselves.
#   %opt: host (target configured domain; '' or '(default)' = primary/base),
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
        return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" }
            unless $row;
        $croot = $row->{content_root} // '';
        return { ok => 0, kind => 'invalid',
            error => "$host has no content folder of its own; pass --content-root" }
            unless length $croot;
    }

    # SM183: the safety snapshot happens HERE, so every surface gets it.
    #
    # It used to be taken only by the control-API's inline apply, which meant an
    # apply through MCP or the CLI overwrote a site with no rollback point - and
    # site_apply's own tool description said so, which made a documented gap
    # rather than a hidden one but did not make it safe. "The artefact is the
    # interface, not the tool" is SM183's whole claim, and a destructive
    # operation that is reversible on one surface and not another contradicts it.
    #
    # snapshot => 0 is for a caller that has ALREADY taken one (the control-API
    # takes it before its scope checks); it is not an opt-out for convenience.
    # Failure to snapshot REFUSES the apply rather than proceeding without one:
    # this overwrites content, and the only thing worse than not being able to
    # roll back is believing you can.
    my $safety_name = '';
    if ( !exists $opt{snapshot} || $opt{snapshot} ) {
        local $Lazysite::Manager::Backups::DOCROOT      = $DOCROOT;
        local $Lazysite::Manager::Backups::LAZYSITE_DIR = _lz();
        # SM412: SCOPE THE SNAPSHOT TO THE BLAST RADIUS. This used to snapshot
        # the whole docroot whatever the target, which on a multi-domain
        # instance meant reading the PRIMARY domain's tree to protect an apply
        # into sites/<target> - refused with permission denied for an account
        # that could never read (and never needed) that tree. package_apply
        # writes only under $croot, so $croot is what the snapshot carries.
        # An empty $croot (the primary/base site) keeps the full content
        # snapshot, which for that target IS the blast radius.
        my $safety = Lazysite::Manager::Backups::action_backup_create(
            'prerestore', ( length $croot ? ( root => $croot ) : () ) );

        # SM378: CARRY THE CAUSE. This discarded $safety->{error} and returned a
        # bare 'safety snapshot failed', which turns a diagnosable fault into a
        # wall - measured in the field, where site_apply refused while
        # site_backup on the same host succeeded in both directions minutes
        # later and nothing in the refusal could tell the two apart.
        unless ( $safety->{ok} ) {
            my $why = $safety->{reason} || $safety->{error} || 'no reason given';
            return { ok => 0, kind => 'snapshot-failed',
                error => "Refusing to apply: safety snapshot failed - $why",
                ( $safety->{detail} ? ( detail => $safety->{detail} ) : () ) };
        }
        $safety_name = $safety->{name} // '';
    }

    my $ap = package_apply( $pkg, content_root => $croot, clean => $opt{clean} );
    unless ( $ap->{ok} ) {
        # Name the snapshot on the failure path too - an apply that failed
        # part-way is exactly when the caller needs to know what to restore.
        $ap->{safety} = $safety_name if length $safety_name;
        return $ap;
    }

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
    # SM266: the operator may KEEP named presentation keys - take the package's
    # content while leaving the target's own theme, layout or nav alone. SM193
    # made the identity keys opt-in because stamping them was dangerous; the
    # rest were still applied wholesale, and an operator who wanted the content
    # but not the look had no way to say so. Named keys are dropped from the
    # write set, so the target's existing value simply stays.
    if ( ref $opt{keep_presentation} eq 'ARRAY' ) {
        delete @{$keys}{ @{ $opt{keep_presentation} } };
        $ap->{kept_presentation} = [ sort @{ $opt{keep_presentation} } ];
    }
    # SM255: applying a package sets several presentation keys, each of which is
    # its own conf write. Batched so the history records ONE act - "apply site
    # package" - rather than half a dozen consecutive edits that read as separate
    # operator decisions. The batch commits at the end; it cannot skip.
    Lazysite::Manager::Common::conf_batch(
        'apply site package to ' . ( length $host ? $host : 'the default site' ),
        sub {
            for my $k ( sort keys %$keys ) {
                my $v = $keys->{$k};
                next unless defined $v && length $v;
                if ( length $host ) {
                    Lazysite::Manager::Domains::domain_set( $host, $k, $v );
                }
                else { _write_conf_key( $k, $v ) }
            }
            return;
        } );
    $ap->{applied_to}    = length $host         ? $host : '(default)';
    $ap->{identity_kept} = $opt{adopt_identity} ? 0     : 1;
    # The rollback point, named in the RESULT rather than only in a log line, so
    # the caller can tell the operator what to restore without going looking.
    $ap->{safety} = $safety_name if length $safety_name;
    return $ap;
}

1;
