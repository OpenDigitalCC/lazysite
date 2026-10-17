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
#         _app_manifest, _app_worker, _app_shell, _app_never, _serve_app (the two
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

    return {
        name          => $name,
        short_name    => $short,
        scope         => $scope,
        start_url     => $start,
        colour        => \%colour,
        icons         => \@icons,
        icon_problems => \@icon_problems,
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
    my @parts;
    for my $u (@shell) {
        ( my $p = $u ) =~ s/\?.*\z//;
        my @st = stat("$app->{root}$p");
        @st = stat("$DOCROOT$p") unless @st;
        push @parts, join "\0", $u, ( @st ? ( $st[7], $st[9] ) : ( '-', '-' ) );
    }
    return substr( sha256_hex( join "\n", @parts ), 0, 12 );
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
#   everything else - EVERY PAGE       not answered. A page is never stored by
#       the worker, so a page with an odoo: binding, a per-viewer page and a
#       protected page cannot be, whatever headers they carry. This is stricter
#       than L1 asked and it is the reason the rest can be simple.
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
      }));
    }).then(function () { return self.skipWaiting(); })
  );
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
  event.respondWith(r === 'swr' ? staleWhileRevalidate(event) : cacheFirst(event));
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
        . qq{" data-ls-app-sw="$app->{scope}lazysite-sw.js" data-ls-app-scope="$app->{scope}" defer></script>};
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

1;
