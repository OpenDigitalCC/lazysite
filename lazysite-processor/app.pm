package main;

# lazysite-processor/app.pm - a site, or a section of one, installs as an app.
#
# SM1155 (L1, 2026-10-17: the owner is rebuilding a pocket portal, today a Vue
# PWA, as lazysite pages). Two engine-generated documents and one script:
#
#   <scope>manifest.webmanifest   the web app manifest, from the app_* settings
#   <scope>lazysite-sw.js         the service worker, from the same settings
#   /assets/lazysite-app.js       registers the worker (a shipped engine asset)
#
# HOLDS   _app_settings (the settings, validated, or undef when the app is off),
#         _app_manifest, _app_worker, _app_shell, _app_never, _app_offline_pages
#         and _app_page_fault (which pages may be kept for offline, SM1197),
#         _serve_app (the two
#         generated URLs) and _inject_app (the manifest link and the
#         registration script, into a page inside the scope).
# OWNS    which paths the app worker never handles (one table, for the worker and
#         the shell list); what the manifest says; when the worker's text changes.
# CALLS   resolve_site_vars, confine_content_root, _content_abs,
#         _security_headers, _lazysite_version (the script and its parts);
#         encode_json, sha256_hex (imported by the script's `use`, before its
#         parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, %ACCESS_REC (the script's, `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and loads nothing: ADR
# 0001 keeps the render path free of the Lazysite:: tree.
#
# THE MANIFEST AND THE WORKER ARE GENERATED, NEVER AUTHORED. A site that wrote a
# worker by hand under /lazysite-assets/ would own its caching rules, and the
# rules are the whole of the safety here: the Odoo extension (SM747, SM857)
# promises that an answer meant for one viewer is stored nowhere but in that
# viewer's page. The worker is built from one table in this file and tested
# against the paths it must refuse (t/unit/processor/134).
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, %ACCESS_REC );

# The settings, or undef when the app is off or declared wrongly. Off is the
# default and has no switch: a site that sets app_name is an app.
#
# A wrong value turns the app OFF rather than being quietly repaired. A scope
# of `portal` (no slashes) repaired to `/portal/` would be a guess about which
# section the operator meant, and an app installed over the wrong section is
# worse than none. `lazysite check` names the value (tools/lazysite-check.pl).
sub _app_settings {
    my %sv   = resolve_site_vars();
    my $name = $sv{app_name} // '';
    $name =~ s/\A\s+|\s+\z//g;
    return undef unless length $name;

    my $scope = length( $sv{app_scope} // '' ) ? $sv{app_scope} : '/';
    $scope =~ s/\A\s+|\s+\z//g;
    return undef
        unless $scope =~ m{\A/(?:[A-Za-z0-9._~-]+/)*\z} && $scope !~ m{(?:\A|/)\.\.?/};

    my $start = length( $sv{app_start_url} // '' ) ? $sv{app_start_url} : $scope;
    $start =~ s/\A\s+|\s+\z//g;
    return undef
        unless $start =~ m{\A/[A-Za-z0-9._~/%-]*(?:\?[A-Za-z0-9._~%&=/-]*)?\z}
        && $start !~ m{(?:\A|/)\.\.(?:/|\z)};
    ( my $start_path = $start ) =~ s/\?.*\z//;
    # A start page the scope does not cover is refused by the browser at install.
    return undef unless index( $start_path, $scope ) == 0 || "$start_path/" eq $scope;

    my $short = length( $sv{app_short_name} // '' ) ? $sv{app_short_name} : $name;
    my %colour;
    for my $k (qw(theme background)) {
        my $v = $sv{"app_${k}_colour"} // '';
        $v =~ s/\A\s+|\s+\z//g;
        $colour{$k} = $v if $v =~ /\A#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})\z/;
    }

    # The icons the settings name, and which of them are there. A name that is
    # not a file the site serves is left out of the manifest: an icon that 404s
    # makes the browser drop the install prompt, silently.
    my $root = $DOCROOT;
    if ( defined $sv{content_root} && length $sv{content_root} ) {
        my $c = confine_content_root( $DOCROOT, $sv{content_root} );
        $root = $c if defined $c;
    }
    my @icons;
    my @icon_problems;
    for my $spec ( [ 64, '64x64', 'any' ], [ 192, '192x192', 'any' ], [ 512, '512x512', 'any' ],
        [ 'maskable', '512x512', 'maskable' ] )
    {
        my ( $key, $sizes, $purpose ) = @{$spec};
        my $path = $sv{"app_icon_$key"} // '';
        $path =~ s/\A\s+|\s+\z//g;
        next unless length $path;
        unless ( $path =~ m{\A/[A-Za-z0-9._~/-]+\.(png|webp|svg|jpe?g)\z}i && $path !~ m{\.\.} ) {
            push @icon_problems, "app_icon_$key ($path) is not a site path to an image";
            next;
        }
        my $ext = lc $1;
        my $abs = _content_abs("$root$path");
        unless ( -f $abs || -f "$DOCROOT$path" ) {
            push @icon_problems, "app_icon_$key ($path) is not a file this site serves";
            next;
        }
        my %type = ( png => 'image/png', webp => 'image/webp', svg => 'image/svg+xml', jpg => 'image/jpeg', jpeg => 'image/jpeg' );
        push @icons, { src => $path, sizes => $sizes, type => $type{$ext}, purpose => $purpose };
    }

    # SM1197: how a new worker takes over. `now` (the default) is what SM1155
    # shipped: skipWaiting and claim at once. `wait` holds it until the page posts
    # skip-waiting, so a half-filled form is not swapped under its user. A value
    # that is neither turns the app OFF, as every wrong declaration here does.
    my $update = length( $sv{app_update} // '' ) ? lc $sv{app_update} : 'now';
    $update =~ s/\A\s+|\s+\z//g;
    return undef unless $update eq 'now' || $update eq 'wait';

    return {
        name          => $name,
        short_name    => $short,
        scope         => $scope,
        start_url     => $start,
        colour        => \%colour,
        icons         => \@icons,
        icon_problems => \@icon_problems,
        update        => $update,
        offline_asked => [ grep { length } map { s/\A\s+|\s+\z//gr } split /,/, ( $sv{app_offline_pages} // '' ) ],
        auth_default => ( $sv{auth_default} // '' ),
        shell_extra => [ grep { length } map { s/\A\s+|\s+\z//gr } split /,/, ( $sv{app_shell} // '' ) ],
        root          => $root,
        alias_host    => $sv{alias_host} // '',
        manager_path  => ( $sv{manager_path}  || '/manager' ),
        auth_redirect => ( $sv{auth_redirect} || '/login' ),
    };
}

# The paths the worker NEVER handles, as prefixes, from the settings. Both the
# worker (which refuses them at fetch time) and the shell list (which never
# names them) use this one table, so they cannot disagree.
#
#   /cgi-bin/ and /lazysite-*.pl   every endpoint, the Odoo endpoint and the
#                                  auth endpoints among them (SM747, SM857)
#   /lazysite/                     the engine tree
#   the manager, the sign-in path and its sign-out path
sub _app_never {
    my ($app) = @_;
    my $login = $app->{auth_redirect};
    ( my $logout = $login ) =~ s{/login\b}{/logout};
    my %seen;
    return grep { !$seen{$_}++ } ( '/cgi-bin/', '/lazysite/', $app->{manager_path}, $login, $logout );
}

sub _app_is_never {
    my ( $path, @never ) = @_;
    return 1 if $path =~ m{/lazysite-[a-z0-9-]+\.pl(?:/|\z)};
    for my $p (@never) {
        return 1 if $path eq $p || index( $path, $p =~ m{/\z} ? $p : "$p/" ) == 0;
    }
    return 0;
}

# The app shell: the files the worker fetches at install. The engine's own
# chrome and registration script, the icons, whatever app_shell names, and the
# stylesheets and scripts the start page's cached render links - the theme's.
# Read from the PUBLIC cached render only: a start page that is per-viewer
# leaves no public render, and then the shell is the first three sources, which
# is the safe direction (a smaller shell, never another viewer's markup).
sub _app_shell {
    my ($app) = @_;
    my @never = _app_never($app);
    my @shell = ( '/assets/lazysite-chrome.css', '/assets/lazysite-chrome.js', '/assets/lazysite-app.js' );
    push @shell, map { $_->{src} } @{ $app->{icons} };
    push @shell, @{ $app->{shell_extra} };

    ( my $path = $app->{start_url} ) =~ s/\?.*\z//;
    ( my $base = $path )             =~ s{\A/}{};
    $base = 'index' if $base eq '';
    $base =~ s{/\z}{/index};
    $base =~ s/\.html?\z//;
    my $cache = ( $ENV{LAZYSITE_CACHE_DIR} || "$LAZYSITE_DIR/cache" ) . '/hosts';
    my $file = length $app->{alias_host} ? "$cache/$app->{alias_host}/$base.html" : "$app->{root}/$base.html";
    if ( $base !~ m{\.\.} && open my $fh, '<:raw', $file ) {
        my $html = do { local $/; <$fh> };
        close $fh;
        while ( $html =~ m{<link\b[^>]*\brel=["']stylesheet["'][^>]*\bhref=["'](/[^"'>\s]+)["']}gix ) { push @shell, $1 }
        while ( $html =~ m{<link\b[^>]*\bhref=["'](/[^"'>\s]+)["'][^>]*\brel=["']stylesheet["']}gix ) { push @shell, $1 }
        while ( $html =~ m{<script\b[^>]*\bsrc=["'](/[^"'>\s]+)["']}gix ) { push @shell, $1 }
    }

    my %seen;
    my @out;
    for my $u (@shell) {
        next if $u =~ m{\A//} || $u =~ m{[\s"'<>\\]} || $u =~ m{\.\.};
        ( my $p = $u ) =~ s/\?.*\z//;
        next if _app_is_never( $p, @never );
        next if $seen{$u}++;
        push @out, $u;
        last if @out >= 60;
    }
    return @out;
}

# What changes when the cached shell changes: each shell file's size and time,
# so a deploy that alters the theme's stylesheet alters the worker's bytes, and
# the browser installs the new worker, which opens a new cache and drops the old.
sub _app_fingerprint {
    my ( $app, @shell ) = @_;
    # SM1197: and the list of pages kept for offline, so a page taken off the list
    # opens a new cache and the old copy of it is deleted at activation, not left
    # on the device unreachable.
    my @parts = ( 'pages', _app_offline_pages($app) );
    for my $u (@shell) {
        ( my $p = $u ) =~ s/\?.*\z//;
        my @st = stat("$app->{root}$p");
        @st = stat("$DOCROOT$p") unless @st;
        push @parts, join "\0", $u, ( @st ? ( $st[7], $st[9] ) : ( '-', '-' ) );
    }
    return substr( sha256_hex( join "\n", @parts ), 0, 12 );
}

# SM1197 (inbox 2026-10-19, "An installed app cannot open without a connection"):
# WHY THIS PAGE MAY NOT BE KEPT ON A DEVICE, or undef when it may. The worker
# keeps a listed page for offline use, so the list must hold only pages that are
# the same for every visitor. The engine already knows which are not, and this
# asks it, by the same readers the gate and the renderer use:
#
#   auth other than none (or auth_default), auth_groups, payment, addresses -
#       the page is gated (_peek_md reads them with the gate's own reader); an
#       access key the gate cannot read refuses the page to everyone
#   an ACL read rule, a draft section, an address rule from the store - _acl_governed
#   odoo-identity: and db:...(mine) - the page renders per viewer (main marks them
#       `_protected`, no-store); nocache: true - rendered fresh, api:/raw: - data
#   an `odoo:` binding is NOT in this list, on purpose: resolve_odoo runs only a
#       binding that permits public and works on no visitor key and no Odoo
#       session, so what it puts in the page is the same for every visitor. What is
#       personal comes from the Odoo endpoint at run time, which the worker never
#       touches.
#
# The manager (lib/Lazysite/Manager/Config.pm, _app_offline_page_fault) restates the
# rules, because it loads nothing from this file, and t/unit/manager/368 runs the
# same pages through both so they cannot disagree. A bad entry here is DROPPED, not
# repaired and not fatal: a hand-edited conf must not take the whole app down, and
# the page not kept is the safe direction. The manager refuses it at save, naming it.
sub _app_page_fault {
    my ( $app, $p ) = @_;
    return 'is not a plain site path'
        unless $p =~ m{\A/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*\z} && $p !~ m{(?:\A|/)\.\.?(?:/|\z)};
    my $scope = $app->{scope};
    return "is outside the app scope ($scope)" unless index( $p, $scope ) == 0 || "$p/" eq $scope;
    return 'is an endpoint, the manager, a sign-in path or the engine tree, which the worker never handles'
        if _app_is_never( $p, _app_never($app) );

    ( my $base = $p ) =~ s{\A/}{};
    $base .= 'index' if $base eq '' || $base =~ m{/\z};
    my $file = "$app->{root}/$base.md";
    return 'is not a page this site has' unless -f $file;

    my $m = _peek_md($file);
    return 'is a page the engine cannot read the access rules of' if $m->{access_unreadable};
    my $auth = $m->{auth} || $app->{auth_default} || 'none';
    return "needs sign-in (auth: $auth)" if $auth ne 'none';
    return 'is limited to groups'        if $m->{groups};
    return 'is a paid page'              if ( $m->{payment} // 'none' ) ne 'none';
    return 'is limited by address'       if $m->{addresses} || $m->{addresses_deny};
    return 'shows who the viewer is in Odoo (odoo-identity:)'   if $m->{odoo_me};
    return 'binds the viewer\'s own rows (db:...(mine))'        if $m->{db_mine};
    return 'is rendered fresh for each request (nocache: true)' if $m->{nocache};
    return 'is a data page (api: or raw: true), not a page'     if $m->{api} || $m->{raw};
    return 'is under an access rule (a read list, a draft section or an address list)' if _acl_governed($file);
    return undef;
}

# The pages the worker keeps: what app_offline_pages asks for, less what
# _app_page_fault refuses, in the order given, without repeats.
sub _app_offline_pages {
    my ($app) = @_;
    my %seen;
    return grep { !$seen{$_}++ && !defined _app_page_fault( $app, $_ ) } @{ $app->{offline_asked} };
}

sub _app_manifest {
    my ($app) = @_;
    my %m = (
        id         => $app->{scope},
        name       => $app->{name},
        short_name => $app->{short_name},
        start_url  => $app->{start_url},
        scope      => $app->{scope},
        display    => 'standalone',
    );
    $m{theme_color}      = $app->{colour}{theme}      if defined $app->{colour}{theme};
    $m{background_color} = $app->{colour}{background} if defined $app->{colour}{background};
    $m{icons} = [ map { +{ %{$_} } } @{ $app->{icons} } ] if @{ $app->{icons} };
    return JSON::PP->new->canonical->utf8->pretty->encode( \%m );
}

# The worker. ONE table decides what it touches; the rest is mechanism.
#
#   not GET, not this origin, a Range request, or a path in `never`   the
#       worker does not answer: the browser fetches it as it would without a
#       worker. Nothing is read, kept or replayed.
#   a stylesheet or script             stale-while-revalidate
#   an image                           cache-first
#   a page named in `pages`            network first, the last good copy kept for
#       offline (SM1197, app_offline_pages). The engine lists only pages that are
#       the same for every visitor (_app_page_fault), and the worker adds its own
#       three guards, because the list is configuration and the response is fact:
#         - the COPY IS FETCHED BY THE WORKER, without credentials, never taken
#           from what the person's own navigation received. A signed-in request
#           therefore cannot put anything personal in the kept copy: it is the
#           page as an anonymous visitor gets it. (A browser hides Set-Cookie
#           from a script, so the cookie the page sets is not something a worker
#           can read; not sending one is what makes it moot.)
#         - a redirect (a gated page sends an anonymous visitor to sign-in), a
#           Set-Cookie where one is visible, no-store or private, a status other
#           than 200 - not kept, and a copy kept earlier is deleted.
#         - the never table below is checked FIRST, so a page list that named the
#           endpoint or the manager would still not be answered.
#   everything else - EVERY OTHER PAGE not answered: the browser fetches it as it
#       would without a worker.
#   a response with Cache-Control no-store or private, a status other than
#       200, an opaque response, or Vary: *   never stored, and a copy of the
#       same URL stored earlier is deleted: a file that became protected stops
#       being served from the device at the next fetch.
#
# No cookie, token or answer is read or written: the worker neither sets nor
# forwards a header, and keeps only whole responses under the rules above.
# No offline queue, background sync or push.
sub _app_worker {
    my ($app) = @_;
    my @shell = _app_shell($app);
    my %cfg   = (
        cache => 'lazysite-app-' . ( _lazysite_version() || 'dev' ) . '-' . _app_fingerprint( $app, @shell ),
        shell => \@shell,
        never => [ _app_never($app) ],
        pages  => [ _app_offline_pages($app) ],
        update => $app->{update},
    );
    my $json = JSON::PP->new->canonical->ascii->encode( \%cfg );
    my $js   = _app_worker_template();
    $js =~ s/__CONFIG__/$json/;
    return $js;
}

# A sub for the reason _registry_ct is one: this file's main body runs near the
# top of the request, and a file-scoped `my` down here would still be empty.
sub _app_worker_template {
    return <<'JS';
/* lazysite app worker (SM1155). Generated by the engine from the app_* settings;
   do not edit. A deploy that changes the shell changes this file, and a changed
   worker is the browser's cue to install it. */
'use strict';
var CFG = __CONFIG__;
var PREFIX = 'lazysite-app-';
var STYLE_SCRIPT = /\.(?:css|js|mjs)$/i;
var IMAGE = /\.(?:png|jpe?g|gif|webp|avif|svg|ico)$/i;

/* 'network' means this worker does not answer: the browser fetches as usual. */
function route(url, request) {
  if (request.method !== 'GET') return 'network';
  if (url.origin !== self.location.origin) return 'network';
  if (request.headers && request.headers.get && request.headers.get('range')) return 'network';
  var p = url.pathname;
  if (/\/lazysite-[a-z0-9-]+\.pl(?:\/|$)/.test(p)) return 'network';
  for (var i = 0; i < CFG.never.length; i++) {
    var n = CFG.never[i];
    if (p === n || p.indexOf(n.charAt(n.length - 1) === '/' ? n : n + '/') === 0) return 'network';
  }
  if (CFG.pages.indexOf(p) >= 0) return 'page';
  if (STYLE_SCRIPT.test(p)) return 'swr';
  if (IMAGE.test(p)) return 'cache-first';
  return 'network';
}

/* Whether a response may be kept. Honours the server: no-store and private are
   never kept, and neither is anything that is not a whole, plain 200. */
function storable(response) {
  if (!response || response.status !== 200) return false;
  if (response.type === 'opaque' || response.type === 'opaqueredirect') return false;
  var h = response.headers;
  var cc = (h && h.get && h.get('cache-control')) || '';
  if (/(?:^|[\s,])(?:no-store|private)(?:[\s,=]|$)/i.test(cc)) return false;
  var vary = (h && h.get && h.get('vary')) || '';
  if (/(?:^|,)\s*\*\s*(?:,|$)/.test(vary)) return false;
  return true;
}

/* A page is stricter than a file: it must be a plain answer for THIS address,
   with no redirect (a gated page sends a visitor to sign-in, and the sign-in
   form is not the page), no cookie where a script can see one. */
function storablePage(response) {
  if (!storable(response)) return false;
  if (response.redirected) return false;
  var h = response.headers;
  if (h && h.get && h.get('set-cookie')) return false;
  return true;
}

/* Fetch the page for keeping: by the worker, without credentials, so the copy is
   the page as an anonymous visitor gets it whoever is signed in. A failed fetch
   (no network) leaves a good copy alone. */
function refreshPage(key) {
  return caches.open(CFG.cache).then(function (cache) {
    return fetch(key, { credentials: 'omit', cache: 'no-cache' }).then(function (response) {
      return storablePage(response) ? cache.put(key, response.clone()) : cache.delete(key);
    }, function () {});
  }).catch(function () {});
}

/* Network first. The person is shown what the network sent; the kept copy is
   refreshed behind it, and used only when the network is not there. */
function networkFirstPage(event, url) {
  var key = url.origin + url.pathname;
  return fetch(event.request).then(function (response) {
    event.waitUntil(refreshPage(key));
    return response;
  }, function (err) {
    return caches.open(CFG.cache).then(function (cache) { return cache.match(key); }).then(function (hit) {
      if (hit) return hit;
      throw err;
    });
  });
}

function keep(cache, request, response) {
  if (storable(response)) return cache.put(request, response.clone());
  return cache.delete(request);
}

function staleWhileRevalidate(event) {
  var request = event.request;
  return caches.open(CFG.cache).then(function (cache) {
    return cache.match(request).then(function (hit) {
      var fresh = fetch(request).then(function (response) {
        return Promise.resolve(keep(cache, request, response)).then(function () { return response; });
      });
      if (hit) { event.waitUntil(fresh.catch(function () {})); return hit; }
      return fresh;
    });
  });
}

function cacheFirst(event) {
  var request = event.request;
  return caches.open(CFG.cache).then(function (cache) {
    return cache.match(request).then(function (hit) {
      if (hit) return hit;
      return fetch(request).then(function (response) {
        return Promise.resolve(keep(cache, request, response)).then(function () { return response; });
      });
    });
  });
}

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CFG.cache).then(function (cache) {
      return Promise.all(CFG.shell.map(function (u) {
        return fetch(u, { cache: 'reload' }).then(function (response) {
          return keep(cache, u, response);
        }).catch(function () {});
      }).concat(CFG.pages.map(function (p) { return refreshPage(self.location.origin + p); })));
    }).then(function () { return CFG.update === 'wait' ? undefined : self.skipWaiting(); })
  );
});

/* The page asks for the new worker when it is ready to be swapped (SM1197,
   app_update: wait); lazysite-app.js posts this from its apply(). */
self.addEventListener('message', function (event) {
  var d = event.data;
  if (event.source && event.source.type && event.source.type !== 'window') return;
  if (d === 'skip-waiting' || (d && d.type === 'skip-waiting')) self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (names) {
      return Promise.all(names.filter(function (n) {
        return n.indexOf(PREFIX) === 0 && n !== CFG.cache;
      }).map(function (n) { return caches.delete(n); }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (event) {
  var r = route(new URL(event.request.url), event.request);
  if (r === 'network') return;
  var url = new URL(event.request.url);
  event.respondWith(r === 'page' ? networkFirstPage(event, url) : r === 'swr' ? staleWhileRevalidate(event) : cacheFirst(event));
});
JS
}

# Whether this URI is the manifest or the worker, and the answer. Returns 1 when
# it served one. Before the registries and after the static serve, so a file the
# site really has at that path wins, as a hand-written sitemap.xml does.
sub _serve_app {
    my ($uri) = @_;
    return 0 unless defined $uri;
    $uri =~ s/\?.*\z//;
    return 0 unless $uri =~ m{/(?:manifest\.webmanifest|lazysite-sw\.js)\z};
    my $app = _app_settings() or return 0;
    my ( $ct, $body );
    if ( $uri eq "$app->{scope}manifest.webmanifest" ) {
        ( $ct, $body ) = ( 'application/manifest+json; charset=utf-8', _app_manifest($app) );
    }
    elsif ( $uri eq "$app->{scope}lazysite-sw.js" ) {
        ( $ct, $body ) = ( 'text/javascript; charset=utf-8', _app_worker($app) );
    }
    else {
        return 0;
    }
    $ACCESS_REC{s}  = 200;
    $ACCESS_REC{ch} = 'registry';    # a fetch of the manifest is not a page view
        # The worker lives INSIDE its scope, which is why no Service-Worker-Allowed
        # header is needed: a worker may control the directory it is served from.
        # no-cache so a deploy reaches an installed device on its next check.
    print "Status: 200 OK\r\n";
    print "Content-Type: $ct\r\n";
    print "$_\r\n" for _security_headers();
    print "Cache-Control: no-cache\r\n\r\n";
    print $body;
    return 1;
}

# The manifest link and the registration script, into a page inside the scope.
# Before </head> and the LAST </body>, for the reason _inject_auth_sync gives.
sub _inject_app {
    my ( $html, $vars ) = @_;
    my $app = _app_settings() or return $html;
    my $uri = $vars->{request_uri} // '';
    $uri =~ s/[?#].*\z//;
    return $html unless index( $uri, $app->{scope} ) == 0 || "$uri/" eq $app->{scope};
    return $html if _app_is_never( $uri, $app->{manager_path} );
    return $html if $html =~ m{/assets/lazysite-app\.js};

    my $link = qq{<link rel="manifest" href="$app->{scope}manifest.webmanifest">};
    $link .= qq{<meta name="theme-color" content="$app->{colour}{theme}">}
        if defined $app->{colour}{theme} && $html !~ /<meta\s+name=["']theme-color["']/i;
    $html =~ s{</head>}{$link</head>}i unless $html =~ /<link\b[^>]*\brel=["']manifest["']/i;

    my $script = '<script src="/assets/lazysite-app.js?v=' . _lazysite_version()
        . qq{" data-ls-app-sw="$app->{scope}lazysite-sw.js" data-ls-app-scope="$app->{scope}"}
        . ( $app->{update} eq 'wait' ? ' data-ls-app-update="wait"' : '' ) . q{ defer></script>};
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

1;
