package Lazysite::Manager::SiteBackup;

# Site backup and export: the control API's face over Manager::SitePackage and
# Manager::Backups - building a domain's or the primary site's package, reading,
# deleting, streaming, uploading and applying one. Moved unchanged out of
# lazysite-manager-api.pl by SM944 S28.
#
# Index
#   _root_outside_grant          may the caller NOT reach content at a root (SM578/SM976)
#   _package_scope_refusal       the refusal for a package outside the caller's reach
#   _package_grant_refusal       ...whose words name the rule (SM782)
#   action_site_backup_create    site-backup-create: package one domain
#   action_site_export_primary   site-export-primary: package the primary site
#   _site_package_path           a package name to its path in backups/
#   _package_name_refusal        ...or why the name is not one
#   action_site_backup_inspect   site-backup-inspect: a manifest, and a dry run
#   action_site_backup_delete    site-backup-delete
#   action_site_backup_download  site-backup-download: stream a package
#   action_site_backup_upload    site-backup-upload: store a package, for an account
#   action_site_backup_apply     site-backup-apply: apply a package to a domain
#
# The request context ($auth_user, @REQUEST_SCOPES) and the domain and
# no-scope rules are read from Lazysite::Manager::Common, which
# lazysite-manager-api.pl sets and nothing here assigns (t/lint/217); every verb
# addressed by a host, a root or a package asks the domain rule (t/lint/218).
# Loaded where no request set the context, each verb refuses and writes nothing
# (t/unit/manager/205). $DOCROOT and $LAZYSITE_DIR are set by the dispatcher, as
# for every manager module.

use strict;
use warnings;
use Exporter 'import';
use File::Path                     qw(make_path);
use POSIX                          qw(strftime);
use Lazysite::Util                 qw(log_event);
use Lazysite::Manager::Common      qw($auth_user @REQUEST_SCOPES _no_scope_refusal);
use Lazysite::Manager::Upload      qw(check_upload_rate parse_multipart_body);
use Lazysite::Manager::Backups     qw(action_backup_create);
use Lazysite::Manager::Domains     qw(domains_list);
use Lazysite::Manager::SitePackage qw(package_create package_inspect);

our @EXPORT_OK = qw(action_site_backup_create action_site_backup_upload action_site_backup_apply
    action_site_export_primary action_site_backup_inspect action_site_backup_delete
    action_site_backup_download _package_scope_refusal);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

# SM183: a scope-confined caller may only reach a package whose source content
# root lies within their dav_scope union, so one client's manager cannot read
# another's package metadata on a shared instance. Returns the refusal, or
# undef when the caller may proceed. Unconfined operators always may.
# SM578 (completed after the field pass): ONE rule, applied to a content root.
#
# The first cut of this confined site-backup-download and site-backup-delete,
# because both route through _package_scope_refusal below - and left
# site-backup-create and site-backup-inspect untouched, because each carried
# its own inline copy of the old test. The result contradicted its own filing:
# a scopeless token grant could not download a package but could BUILD one for
# any host on the instance and read any manifest in full. The four verbs now
# ask one function, so they cannot disagree again - which is the actual defect,
# not the two missing checks.
#
# Returns true when the caller may NOT reach content rooted at $croot.
#
# SM976: the reach is caller_may_reach_domain's. This exempted every cookie
# session, so a manager confined to one domain built, downloaded and deleted
# another domain's package; the operator and an unbound cookie manager are still
# unconfined there, and a scoped one is held to its scope. A package of the
# primary (no content root) is reached by no token: a token naming no scope is
# refused here first, and a scoped one does not reach the primary.
sub _root_outside_grant {
    my ($croot) = @_;
    return 1 if _no_scope_refusal();    # a token naming no scope reaches nothing
    return Lazysite::Manager::Common::caller_may_reach_domain( root => $croot ) ? 0 : 1;
}

sub _package_scope_refusal {
    my ($pkg) = @_;

    # SM578: THE EXEMPTION IS THE CHANNEL, NOT THE ABSENCE OF A SCOPE.
    #
    # This used to return early whenever the caller had no dav_scopes, on the
    # reading that no scope means unconfined. That is true of a COOKIE session -
    # the operator, at their own manager - and false of a token or MCP grant,
    # where it simply means nobody set one. A partner holding manage_domains and
    # no dav_scope therefore reached every domain's package on the instance, and
    # a package is a whole site: pages, assets, theme, layout, configuration.
    #
    # So the confinement is a property of THIS ACTION now. A cookie session is
    # exempt because it is the sysop; every token grant must name a scope the
    # package's content root falls inside, and one that names none reaches no
    # package at all rather than all of them. The operator ACCEPTED that
    # behaviour change knowing existing partners must be re-scoped.
    # SM976: and a cookie manager confined to a domain is held too.
    return undef unless Lazysite::Manager::Common::request_domain_confined();
    my $info  = package_inspect($pkg);
    my $croot = $info->{ok} ? ( $info->{manifest}{keys}{content_root} // '' ) : '';
    return _package_grant_refusal($croot) if _root_outside_grant($croot);
    return undef;
}

# SM782: THE REFUSAL NAMES THE RULE. "You do not have access to this
# package" left a holder of manage_domains with nowhere to go - a different
# capability, a different channel, or someone else? The rule (SM578) is a
# scope: a token grant reaches a package only through a WebDAV scope that
# contains the package's content root; a cookie session is the sysop and is
# exempt. Say so, with what this grant names and what the package has.
sub _package_grant_refusal {
    my ($croot) = @_;
    # SM783: name the FIELD. "this grant names no scope" sent a reader to
    # `whoami`, which prints a `scope` block (the content allow/deny) and is
    # not this - so the message read as wrong about them. dav_scope is what
    # this rule consults.
    my $scopes = @REQUEST_SCOPES      ? join( ', ', @REQUEST_SCOPES ) : 'no dav_scope';
    my $root = length( $croot // '' ) ? "'$croot'" : 'no content root (the primary domain)';
    return { ok => 0, kind => 'forbidden',
        error => 'A token grant reaches a site package only through a WebDAV scope '
            . "that contains the package's content root; this package has $root and "
            . "this grant's dav_scope names $scopes. The sysop's own session is exempt; a token needs a "
            . 'dav_scope covering the package, or the sysop removes it.' };
}

# SM158: package one domain's SITE (content root + nav + bundled theme/layout +
# manifest) into a portable .tar.gz alongside the backups, downloadable via
# backup-download. manage_content-gated (above); additionally the caller must
# have ACCESS to that domain's content root - a scope-confined editor can only
# package a domain within their dav_scope union (sysops are unconfined).
sub action_site_backup_create {
    my ( $host, $data_tables ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'A domain host is required' }
        unless length $host;

    # Resolve the domain's own content root, and confine to the caller's scope.
    my ($row) = grep { lc( $_->{host} // '' ) eq $host } @{ domains_list()->{domains} || [] };
    return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" }
        unless $row;
    my $croot = $row->{content_root} // '';
    # SM578: was `if (@REQUEST_SCOPES && ...)`, so a token grant naming no scope
    # built a package for ANY host on the instance - measured in the field
    # against an unrelated domain.
    if ( _root_outside_grant($croot) ) {
        return { ok => 0, kind => 'forbidden',
            error => "You do not have access to the content of $host." };
    }

    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    return package_create( $host, data_tables => $data_tables );
}

# SM185: package the DEFAULT/primary site as a self-contained site package,
# independent of the domains feature (manage_content-gated, so a site owner who
# does not use additional domains can still export/hand off their site). A
# scope-confined editor (bound to a sub-area) may NOT export the whole default
# site. The package excludes lazysite/ and every other domain's content.
sub action_site_export_primary {
    my ($data_tables) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Exporting the default site needs full content access (you are confined to an area).' }
        unless Lazysite::Manager::Common::caller_may_reach_domain( host => '' );   # SM976
    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    return package_create( '(default)', data_tables => $data_tables );
}

# SM183: resolve a site-package name to its path under lazysite/backups/, confined
# to the lazysite-site- namespace - a full/content backup or any other file (or a
# traversal) is unreachable. Returns the abs path, or undef for an invalid name.
# SM783: A NAME THAT WAS SENT IS NOT A NAME THAT IS MISSING. Every caller
# answered "A site package name is required" whether the name was absent or
# simply not a package name, so a caller who HAD sent one went looking for
# the parameter rather than at its shape - the same family as the three
# refusals 0.13.8 fixed. Returns ( $path, undef ) or ( undef, $refusal ).
sub _site_package_path {
    my ($name) = @_;
    $name //= '';
    return "$LAZYSITE_DIR/backups/$name"
        if $name =~ /\Alazysite-site-[A-Za-z0-9._-]+\.tar\.gz\z/ && $name !~ /\.\./;
    return undef;
}

sub _package_name_refusal {
    my ($name) = @_;
    return { ok => 0, kind => 'invalid',
        error => 'A site package name is required (in the JSON body or the query as `name`)' }
        unless defined $name && length $name;
    return { ok => 0, kind => 'invalid',
        error => "'$name' is not a site package name - expected "
            . 'lazysite-site-<host>-<stamp>.tar.gz' };
}

# SM183: read a package's manifest WITHOUT applying it. manage_domains-gated
# (above) + read-only. A scope-confined caller may only inspect a package whose
# (source) content root lies within their dav_scope union - so one client's
# manager cannot read another client's package metadata (or the primary site's)
# on a shared instance. Operators (no scope) are unconfined.
sub action_site_backup_inspect {
    my ( $name, $host ) = @_;
    my $pkg = _site_package_path($name) or return _package_name_refusal($name);
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg; # not a store: a backup archive

    # SM578: inspect had no scope test at all, so the manifest of a package the
    # caller may not download read back in full - source host, content root,
    # file counts. The manifest IS the disclosure.
    my $refusal = _package_scope_refusal($pkg);
    return $refusal if $refusal;

    # SM266: with a target host, the caller wants the DRY RUN as well - what an
    # apply would add versus overwrite there. The target's content root is
    # resolved here (not passed in), so a caller cannot aim the comparison at an
    # arbitrary directory and use the counts to probe the filesystem.
    my $target = '';
    if ( defined $host && length $host ) {
        my ($d) = grep { ( $_->{host} // '' ) eq $host }
            @{ Lazysite::Manager::Domains::domains_list()->{domains} || [] };
        $target = ( ref $d eq 'HASH' ? $d->{content_root} : '' ) // '';
        return { ok => 0, kind => 'invalid',
            error => "No configured domain '$host' with its own content root." }
            unless length $target;
        return { ok => 0, kind => 'forbidden',
            error => 'You do not have access to that target.' }
            unless Lazysite::Manager::Common::caller_may_reach_domain( host => $host ); # SM976
    }

    # SM976: the package's own content root was asked a second time here, of
    # @REQUEST_SCOPES directly; _package_scope_refusal above asks it of every
    # domain-confined caller now, so the copy is gone.
    return package_inspect( $pkg, $target );
}

# SM183: remove a site package from the backups area. manage_domains-gated;
# name-confined to the lazysite-site- namespace; scope-confined to the package's
# content root like inspect. Audited via the generic dispatch wrapper.
sub action_site_backup_delete {
    my ($name) = @_;
    my $pkg = _site_package_path($name) or return _package_name_refusal($name);
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg; # not a store: a backup archive

    my $refusal = _package_scope_refusal($pkg);
    return $refusal if $refusal;

    unlink $pkg or return { ok => 0, error => "Could not delete the package: $!" };
    # SM183: and its integrity sidecar, or the next listing shows a digest for a
    # package that no longer exists - and a later package reusing the name would
    # inherit a digest that never described it.
    unlink "$pkg.sha256" if -f "$pkg.sha256";
    return { ok => 1, name => $name };
}

# SM193 gap 1: stream a SITE PACKAGE for download. manage_domains-gated and so
# TOKEN-accessible (unlike the manage_config full-system backup-download),
# name-confined to the lazysite-site- namespace and scope-confined to the
# package's content root - so a token client (an agent) can DOWNLOAD a package it
# created, completing the create -> download -> upload -> apply cross-instance
# migration loop, without reaching the full-system backups. Streams like
# action_backup_download; returns {streamed=>1} after the body, or a hash error
# before any output.
sub action_site_backup_download {
    my ($name) = @_;
    my $pkg = _site_package_path($name) or return _package_name_refusal($name);
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg; # not a store: a backup archive

    my $refusal = _package_scope_refusal($pkg);
    return $refusal if $refusal;

    my $size = ( stat $pkg )[7] // 0;
    ( my $safe = $name ) =~ s/[\r\n"\\]//g;
    log_event( 'INFO', 'site-backup-download', 'site package downloaded',
        file => $name, user => $auth_user );

    # Q16b: the one streamed path (Manager::Upload), which opens the package
    # before any header goes out.
    require Lazysite::Manager::Upload;
    return { ok => 0, error => 'Cannot read the package' }
        unless Lazysite::Manager::Upload::stream_attachment( $pkg, 'application/gzip', $safe, $size );
    return { ok => 1, streamed => 1 };
}

# SM158: upload a site package (a multipart file) into lazysite/backups/, so it
# can then be applied. This is the "import" step - the one thing the old backup
# tooling could not do (backups were server-only). The stored name is forced to
# the lazysite-site- namespace and .tar.gz; content is written raw (a package is
# a gzip blob, never executed). manage_content-gated (above) + upload rate limit.
sub action_site_backup_upload {
    my ($raw) = @_;
    # SM944 S28, the established fail-closed pattern (ruled 2026-10-09/10): A
    # PACKAGE IS STORED FOR AN ACCOUNT. Inside a request the dispatcher has
    # refused an empty $auth_user (and required `manage_domains`) before this
    # runs, so it is never empty here; reached outside one (the request
    # context's reset leaves nobody) it wrote a package into backups/ with
    # nobody asking (tmp/sm944-s27-s28-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'A site package is uploaded by a signed-in account, and no account is asking.' }
        unless length $auth_user;
    my $ct = $ENV{CONTENT_TYPE} // '';
    return { ok => 0, error => 'Expected a multipart file upload' }
        unless $ct =~ m{multipart/form-data}i;

    # SM548: ($username, $content_length), as the file upload passes them.
    # This passed the docroot where the user belongs, so every user of the
    # instance shared one package-upload budget and the byte limit compared
    # against nothing.
    my $rate = check_upload_rate( $auth_user, length( $raw // '' ) );
    return { ok => 0, kind => 'rate', error => $rate->{error} }
        if ref $rate eq 'HASH' && !$rate->{ok};

    my ($file) = grep { defined $_->{filename} && length $_->{filename} }
        parse_multipart_body( $raw, $ct );
    return { ok => 0, error => 'No file in the upload' } unless $file;
    return { ok => 0, error => 'A site package is a .tar.gz file' }
        unless $file->{filename} =~ /\.tar\.gz\z/;
    return { ok => 0, error => 'Empty upload' } unless length( $file->{data} // '' );

    # A stored package always carries the namespace prefix + a UTC stamp; the
    # uploaded filename is never trusted for the on-disk name.
    my $stamp = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $name  = "lazysite-site-uploaded-$stamp.tar.gz";
    my $dir   = "$LAZYSITE_DIR/backups";
    make_path($dir) unless -d $dir;
    my $out = "$dir/$name";
    open my $fh, '>:raw', $out or return { ok => 0, error => "Cannot store the upload: $!" };
    print {$fh} $file->{data};
    close $fh;

    # Audited by the generic dispatch wrapper (site-backup-upload is not in
    # %skip), like every other write action.
    my @st = stat $out;
    return { ok => 1, name => $name, size => ( $st[7] // 0 ) };
}

# SM158: apply a site package (already in lazysite/backups/) to a TARGET domain
# on this instance. Safety-snapshots the whole docroot first, extracts + copies
# the vetted content into the target content root, installs the bundled
# theme/layout if missing, places the nav override, then writes the target
# domain's presentation keys. Requires manage_domains + access (scope) to the
# target content root. $req: { name, host, clean }.
#   host present + registered => apply into that domain (its content_root);
#   host omitted / '(default)' => apply to the PRIMARY/base site.
sub action_site_backup_apply {
    my ($req) = @_;
    $req ||= {};
    my $name = $req->{name} // '';
    my $host = lc( $req->{host} // '' );
    $host = '' if $host eq '(default)';

    my $pkg = _site_package_path($name) or return _package_name_refusal($name);
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg; # not a store: a backup archive

    # SM975: the scope test below skips an empty scope, which is right for the
    # cookie session and wrong for a token: an unscoped token applied a package
    # over any domain's content and presentation. It reaches no target now.
    if ( my $r = _no_scope_refusal() ) { return $r }

    # Resolve the TARGET content root.
    my $croot;
    if ( length $host ) {
        my ($row) = grep { lc( $_->{host} // '' ) eq $host }
            @{ domains_list()->{domains} || [] };
        return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" }
            unless $row;
        $croot = $row->{content_root} // '';
        return { ok => 0, kind => 'invalid',
            error => "$host has no content folder of its own - set one on the Domains "
                . 'page (or apply to the default site) first.' }
            unless length $croot;
    }
    else {
        # Primary/base: use the base content_root, else adopt the package's.
        my ($base) = grep { $_->{is_primary} } @{ domains_list()->{domains} || [] };
        $croot = $base->{content_root} // '';
        $croot = ( $req->{content_root} // '' ) unless length $croot;
    }
    $croot =~ s{^/+|/+$}{}g;

    # Scope: the caller must reach the target DOMAIN, and its content root.
    # SM976: an apply with no host is an apply to the primary - its presentation
    # is set from the package - so a caller confined to a domain is refused it
    # even where the content root it named lies inside its scope.
    unless ( Lazysite::Manager::Common::caller_may_reach_domain( host => $host )
        && Lazysite::Manager::Common::caller_may_reach_domain( root => $croot ) )
    {
        return { ok => 0, kind => 'forbidden',
            error => 'You do not have access to the target content root.' };
    }

    # Safety snapshot BEFORE any write, so an apply is always reversible.
    # Taken here rather than in apply_and_configure because it must precede the
    # scope checks above on this surface; snapshot => 0 below stops the shared
    # layer taking a second one. SM183 moved the snapshot INTO the shared layer
    # so MCP and the CLI get it too - this surface always had it.
    #
    # SM874: SCOPED TO THE TARGET, which is the whole point of SM412 and which
    # this surface never did. SM412 gave action_backup_create a `root` because
    # "the safety snapshot before a site-package apply used to tar the whole
    # docroot whatever the target" - then fixed it inside apply_and_configure.
    # This surface passes `snapshot => 0` to opt OUT of that shared path and
    # took its own, unscoped: so the one surface a person clicks kept the exact
    # defect SM412 had just removed, for four releases.
    #
    # It survived because t/unit/manager/61 drives the LIBRARY, and
    # t/unit/manager/59 asserted this call by SOURCE REGEX as evidence the
    # surface "takes a snapshot" - proving it existed, never what it covered.
    # An empty $croot means the primary, where unscoped IS the blast radius.
    my $safety = action_backup_create( 'prerestore',
        ( length $croot ? ( root => $croot ) : () ) );

    # SM378: the third copy of the same discard. A refusal that will not say
    # why is its own defect, and this is the surface a remote caller meets.
    unless ( $safety->{ok} ) {
        my $why = $safety->{reason} || $safety->{error} || 'no reason given';
        return { ok => 0, kind => 'snapshot-failed',
            error => "Refusing to apply: safety snapshot failed - $why",
            ( $safety->{detail} ? ( detail => $safety->{detail} ) : () ) };
    }

    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    my $ap = Lazysite::Manager::SitePackage::apply_and_configure(
        $pkg,
        host         => $host,
        content_root => ( length $croot ? $croot : ( $req->{content_root} // '' ) ),
        clean        => ( $req->{clean} ? 1      : 0 ),
        snapshot     => 0,
        # SM193: keep the TARGET domain's site_url/site_name by default; opt into
        # taking the package's identity with adopt_identity (a migration vs handoff).
        adopt_identity => ( $req->{adopt_identity} ? 1 : 0 ),
        # SM266: presentation keys the sysop chose to KEEP on the target -
        # take the package's content without taking its look. Filtered against
        # the portable set so a caller cannot use this to skip a key the apply
        # depends on (content_root above all, which is what makes the write land
        # in the right place).
        keep_presentation => [
            grep { /\A(?:theme|layout|nav)\z/ }
                @{ ref $req->{keep_presentation} eq 'ARRAY' ? $req->{keep_presentation} : [] }
        ],
    );
    unless ( $ap->{ok} ) {
        $ap->{safety} = $safety->{name};
        return $ap;
    }

    # SM158: applying a site is a bulk content change - like a restore, commit it
    # so it is visible in content history and recoverable (instant no-op when the
    # Content history plugin is off). Parity with backup-restore.
    require Lazysite::Git;
    Lazysite::Git::commit_all( $DOCROOT, $auth_user,
        "apply site package $name" . ( length $host ? " to $host" : '' ) );

    # Drop caches so the applied site renders fresh.
    Lazysite::Util::clear_host_cache($DOCROOT);

    # Audited by the generic dispatch wrapper (target = the host, via
    # _audit_implicit_target's site-backup- branch).
    return {
        ok               => 1,
        applied_to       => ( length $host ? $host : '(default)' ),
        content_root     => $ap->{content_root},
        nav              => $ap->{nav},
        layout_installed => $ap->{layout_installed},
        safety           => $safety->{name},
        source_host      => $ap->{source_host},
    };
}

1;
