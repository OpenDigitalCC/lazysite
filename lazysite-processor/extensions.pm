package main;

# lazysite-processor/extensions.pm - what an enabled extension's declaration
# gives a page: its assets, its components and its template variables.
#
# SM1369 X5, the asset part of H-10 (ruling 55, tmp/proposal-extension-hooks.md).
# Core names no extension (t/lint/321): what the Odoo helper, its sign-in
# component and its "Signed in as" banner needed from the processor is now read
# from the hook index the manager writes (lazysite/extensions.index.json, X1)
# from the descriptors of the ENABLED extensions, and any extension can declare
# the same three things:
#
#   assets        [ { file, inject_when, alias, attrs } ]: a file in the payload's
#                 assets/, served at /assets/<id>-<file> (and at its alias) on
#                 every domain, and added to a page whose rendered markup carries
#                 the attribute inject_when names - once, before the last </body>,
#                 with the data attributes the attrs function answers;
#   components    [ { file } ]: a ::: <name> component in the payload's
#                 templates/components/, found after the layout's and the
#                 engine's own;
#   template_vars [ { name, render } ]: a layout variable, rendered by the
#                 extension's function when - and only when - a template asks.
#
# HOLDS   _extension_index (the index, memoised on the file's identity),
#         _extension_entries (its entries, of the extensions on now),
#         _extension_asset (an asset by request path), _serve_extension_asset,
#         _inject_extension_assets, _extension_template_vars,
#         _extension_component_dirs, _extension_component_dir, _warm_endpoint
#         (SM1369 X5, H-5: a declared warm endpoint, for the front door),
#         _call_extension_hook (the one door to an extension's own code), and
#         the identity providers' (X4): _identity_providers, _provider_on,
#         _provider_signin_page, _provider_signin_paths, _identity_template_vars.
# OWNS    which extension files the processor serves, injects, includes or
#         renders: only what the index names, only while the extension and
#         everything it requires is on, only from the payload the index names.
# CALLS   _enabled_extensions, _lazysite_version, _esc_html, _security_headers,
#         _timing_header, _static_cache_control, _lazy_lib, log_event (the
#         script and its parts); decode_json (imported by the script's `use`,
#         before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, %ACCESS_REC, %STATIC_CT (the script's, `our`
#         there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944). It is package main, required by
# absolute path from lazysite-processor.pl's BEGIN and loads nothing: ADR 0001
# keeps the render path free of the Lazysite:: tree. The index is read here as
# JSON, module-free (R-4 of the proposal); an extension's FUNCTION is reached
# through Lazysite::Extensions::Hooks::call_hook, loaded on first use by
# _lazy_lib as the identity reader is, and only for a page that asks for a
# variable or carries a region the attrs function serves. call_hook is what
# checks, at the call, that the extension is on and that the module is the
# extension's own (G-1); a hook that fails answers nothing (G-9).
#
# THE ENABLED LIST IS READ AGAIN HERE (_enabled_extensions): the index holds
# only enabled extensions when it is written, and a disable rebuilds it, but an
# index a failed write left behind must not serve a disabled extension's file.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, %ACCESS_REC, %STATIC_CT );

# The index, memoised per process on the file's identity (device, inode, size,
# mtime): the manager renames a new file into place, so a rebuild is a new
# inode. Absent is a site with no hooks and nothing to serve. One that cannot
# be read or decoded serves nothing either, after a WARN: an index nobody can
# read runs nothing, which is the closed side (Lazysite::Extensions::Hooks reads
# it the same way for a hook call; t/unit/extensions/76 holds the two readers
# to one answer).
my %INDEX_MEMO;
my $INDEX_FILE = 'extensions.index.json';    # as Lazysite::Extensions::Hooks names it

sub _extension_index {
    my $path = "$LAZYSITE_DIR/$INDEX_FILE";
    my @st   = stat $path;
    unless (@st) {
        %INDEX_MEMO = ();
        return {};
    }
    my $sig = join ':', @st[ 0, 1, 7, 9 ];
    return $INDEX_MEMO{index} if %INDEX_MEMO && $INDEX_MEMO{sig} eq $sig;
    my %ext;
    if ( open my $fh, '<:raw', $path ) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $got = eval { decode_json($raw) };
        if ( ref $got eq 'HASH' && ( $got->{format} // 0 ) == 1 && ref $got->{extensions} eq 'HASH' ) {
            %ext = %{ $got->{extensions} };
        }
        else {
            log_event( 'WARN', 'extension-hook',
                'the hook index is not one this engine reads - nothing it names is served until it is rebuilt',
                file => $path );
        }
    }
    else {
        log_event( 'WARN', 'extension-hook', 'the hook index cannot be read', file => $path, error => "$!" );
    }
    %INDEX_MEMO = ( sig => $sig, index => \%ext );
    return \%ext;
}

# The index's entries of the extensions that are ON NOW, with everything they
# require on too: ( [ id, entry ], ... ) in id order. Memoised with the index
# on the conf's identity as well, so a request asks each file once.
my %ENTRIES_MEMO;

sub _extension_entries {
    my $idx = _extension_index();
    return [] unless %$idx;
    my @cs  = stat "$LAZYSITE_DIR/lazysite.conf";
    my $sig = join ':', ( $INDEX_MEMO{sig} // '' ), @cs ? @cs[ 0, 1, 7, 9 ] : ('none');
    return $ENTRIES_MEMO{entries} if %ENTRIES_MEMO && $ENTRIES_MEMO{sig} eq $sig;
    my $on = _enabled_extensions();
    my @e;
    for my $id ( sort keys %$idx ) {
        my $e = $idx->{$id};
        next unless ref $e eq 'HASH' && ref $e->{hooks} eq 'HASH' && $on->{ $e->{key} // '' };
        next if grep { !$on->{$_} } @{ ref $e->{requires_keys} eq 'ARRAY' ? $e->{requires_keys} : [] };
        push @e, [ $id, $e ];
    }
    %ENTRIES_MEMO = ( sig => $sig, entries => \@e );
    return \@e;
}

sub _entry_list {
    my ( $e, $kind ) = @_;
    my $v = $e->{hooks}{$kind};
    return grep { ref $_ eq 'HASH' } @{ ref $v eq 'ARRAY' ? $v : [] };
}

# A file name as the validator accepted it: one name, an extension, no path.
sub _extension_file_ok {
    my ($f) = @_;
    return defined $f && !ref $f && $f =~ /\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9]+\z/ ? 1 : 0;
}

# The declared asset a request path names - /assets/<id>-<file>, or an alias -
# as { id, asset, path }, or undef. The path is inside the payload the index
# names, by construction: the id is the index's key, the file a plain name.
sub _extension_asset {
    my ($uri) = @_;
    return undef unless defined $uri;
    $uri =~ s/\?.*\z//;
    return undef unless $uri =~ m{\A/assets/[^/]+\z};
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        next unless defined $e->{payload} && !ref $e->{payload} && $e->{payload} =~ m{\A/};
        for my $a ( _entry_list( $e, 'assets' ) ) {
            next unless _extension_file_ok( $a->{file} );
            next
                unless $uri eq "/assets/$id-$a->{file}"
                || ( defined $a->{alias} && !ref $a->{alias} && $uri eq $a->{alias} );
            return { id => $id, asset => $a, path => "$e->{payload}/assets/$a->{file}" };
        }
    }
    return undef;
}

# Serve a declared asset from the extension's payload. Returns 1 when it
# answered. A type the engine does not serve as a static, a file that is gone
# or is a link, or one that cannot be read, is not found - as the index build
# would have refused it - and the reason is logged.
sub _serve_extension_asset {
    my ($uri) = @_;
    my $hit   = _extension_asset($uri) or return 0;
    my $real  = $hit->{path};
    my ($ext) = $real =~ /\.([A-Za-z0-9]+)\z/;
    my $ct    = $STATIC_CT{ lc( $ext // '' ) };
    unless ($ct) {
        log_event( 'WARN', $uri, 'a declared asset is of a type the engine does not serve',
            extension => $hit->{id}, file => $hit->{asset}{file} );
        return 0;
    }
    if ( -l $real || !-f $real ) {
        log_event( 'WARN', $uri, 'a declared asset is not a file in the extension\'s payload',
            extension => $hit->{id}, path => $real );
        return 0;
    }
    open my $fh, '<:raw', $real or do {
        log_event( 'WARN', $uri, 'a declared asset cannot be read', extension => $hit->{id}, path => $real,
            error => "$!" );
        return 0;
    };
    my @st   = stat $fh;
    my $body = do { local $/; <$fh> };
    close $fh;

    $ACCESS_REC{s}  = 200;
    $ACCESS_REC{ch} = 'registry';    # an engine file, not a page view
    my $etag = @st ? sprintf( 'W/"%x-%x"', $st[9], $st[7] ) : undef;
    my $inm  = $ENV{HTTP_IF_NONE_MATCH};
    if ( defined $etag && defined $inm && grep { $_ eq $etag || $_ eq '*' } map { s/^\s+|\s+$//gr } split /,/, $inm ) {
        $ACCESS_REC{s} = 304;
        $ACCESS_REC{b} = 0;
        print "Status: 304 Not Modified\n";
        print "$_\n" for _security_headers();
        print "$_\n" for _timing_header();
        print "ETag: $etag\n";
        print _static_cache_control($real) . "\n";
        print "\n";
        return 1;
    }
    binmode(STDOUT);
    print "Status: 200 OK\n";
    print "Content-Type: $ct\n";
    print "$_\n" for _security_headers();
    print "$_\n" for _timing_header();
    print "ETag: $etag\n" if defined $etag;
    print _static_cache_control($real) . "\n";
    print 'Content-Length: ' . length($body) . "\n";
    print "\n";
    print $body unless ( $ENV{REQUEST_METHOD} // 'GET' ) eq 'HEAD';
    $ACCESS_REC{b} = length $body;
    return 1;
}

# SM1369 X5, H-5 (n782): IS A cgi-bin SCRIPT A WARM ENDPOINT? One an extension
# that is on now declares (hooks.endpoints, warm: 1): the front door then hands
# the request to its warm-fork parent, a service the same extension declares,
# and runs the CGI as before when none is listening. Read from the index, so
# core knows no endpoint by name.
sub _warm_endpoint {
    my ($script) = @_;
    return 0 unless defined $script && $script =~ /\Alazysite-[a-z][a-z0-9-]*\.pl\z/;
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        return 1 if grep { ( $_->{script} // '' ) eq $script && $_->{warm} } _entry_list( $e, 'endpoints' );
    }
    return 0;
}

# THE ONE DOOR TO AN EXTENSION'S OWN CODE from the processor: the loader checks
# that the extension and what it requires are on, that the function is one its
# indexed declaration names, and that the module is the extension's own, and a
# function that dies answers ( 0, why ). Returns what call_hook returns.
sub _call_extension_hook {
    my ( $id, $function, @args ) = @_;
    _lazy_lib('Lazysite::Extensions::Hooks');
    my ( $ok, @out ) = Lazysite::Extensions::Hooks::call_hook( $DOCROOT, $id, $function, @args );
    log_event( 'DEBUG', 'extension-hook', 'a hook answered nothing', extension => $id, function => $function,
        why => $out[0] // '' )
        unless $ok;
    return ( $ok, @out );
}

sub _hook_context {
    return { docroot => $DOCROOT, lazysite_dir => $LAZYSITE_DIR, version => _lazysite_version() };
}

# A declared script, into a page whose rendered markup carries the attribute
# its inject_when names: once, before the LAST </body>, versioned, with the
# data attributes the extension's attrs function answers (escaped here; a name
# that is not a data attribute is dropped). The alias is what the tag names when
# there is one, so a page that loads the script itself by that path, as the
# docs show, is not given it twice. The terms are the data and account helpers'
# (_inject_data_helper): the markup is the trigger, not a setting.
sub _inject_extension_assets {
    my ($html) = @_;
    return $html unless $html =~ m{</body>}i;
    my $entries = _extension_entries();
    return $html unless @$entries;
    my $v = _lazysite_version();
    for my $pair (@$entries) {
        my ( $id, $e ) = @$pair;
        for my $a ( _entry_list( $e, 'assets' ) ) {
            next unless _extension_file_ok( $a->{file} ) && $a->{file} =~ /\.js\z/;
            my $when = $a->{inject_when};
            next unless defined $when && !ref $when && $when =~ /\Adata-[a-z0-9-]+\z/;
            next if $html !~ m{\b\Q$when\E\b};
            my $alias = defined $a->{alias} && !ref $a->{alias} && $a->{alias} =~ m{\A/assets/[^/]+\z} ? $a->{alias} : undef;
            my $src = $alias // "/assets/$id-$a->{file}";
            next if $html =~ m{\Q$src\E} || $html =~ m{/assets/\Q$id-$a->{file}\E};
            my $attrs = '';
            if ( defined $a->{attrs} && !ref $a->{attrs} ) {
                my ( $ok, $got ) = _call_extension_hook( $id, $a->{attrs}, _hook_context() );
                if ( $ok && ref $got eq 'HASH' ) {
                    for my $k ( sort keys %$got ) {
                        next unless $k =~ /\Adata-[a-z0-9-]+\z/ && defined $got->{$k} && !ref $got->{$k};
                        $attrs .= ' ' . $k . '="' . _esc_html( $got->{$k} ) . '"';
                    }
                }
            }
            my $script = '<script src="' . $src . '?v=' . $v . '"'
                . $attrs . ' defer></script>';
            $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
        }
    }
    return $html;
}

# The template variables the enabled extensions declare: name => a code ref the
# template engine calls when a template names the variable, and never
# otherwise, so a page whose layout says nothing of an extension loads nothing
# of it. The function answers safe markup (or a value the template escapes, as
# the layout contract for it says); anything but a plain value is ''. The first
# extension to declare a name keeps it.
sub _extension_template_vars {
    my %vars;
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        for my $t ( _entry_list( $e, 'template_vars' ) ) {
            my ( $name, $fn ) = ( $t->{name}, $t->{render} );
            next unless defined $name && !ref $name && $name =~ /\A[a-z][a-z0-9_]*\z/;
            next unless defined $fn && !ref $fn;
            $vars{$name} //= sub {
                my ( $ok, $out ) = _call_extension_hook( $id, $fn, _hook_context() );
                return $ok && defined $out && !ref $out ? $out : '';
            };
        }
    }
    return { %vars, _identity_template_vars() };
}

# ---- SM1369 X4 (H-1): what an identity provider gives a page ----
#
# The providers the enabled extensions declare (owns.hooks.identity_provider):
# each may name a sign-in page, served as a system page while the provider says
# its sign-in is on, and exempt from maintenance; offer a /login option; and give
# the `signin_banner` layout variable. Core's own variables, so no extension can
# take their names (Hooks' %CORE_VARS), and each is a code ref the template
# engine calls only when a template names it.

sub _identity_providers {
    my @p;
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        my $ip = $e->{hooks}{identity_provider};
        push @p, [ $id, $ip ] if ref $ip eq 'HASH';
    }
    return @p;
}

# Is this provider's sign-in on now? Its own `on`, through the one door; a
# provider that does not answer is off (G-9).
sub _provider_on {
    my ( $id, $ip ) = @_;
    return 0 unless defined $ip->{on} && !ref $ip->{on};
    my ( $ok, $on ) = _call_extension_hook( $id, $ip->{on}, _hook_context() );
    return $ok && $on ? 1 : 0;
}

# The provider whose sign-in page this is, as ( id, declaration ), or ().
sub _provider_signin_page {
    my ($base) = @_;
    return () unless defined $base && $base =~ /\A[a-z][a-z0-9-]{0,63}\z/;
    for my $p ( _identity_providers() ) {
        my $page = $p->[1]{signin_page};
        return @$p if defined $page && !ref $page && $page eq $base;
    }
    return ();
}

# The sign-in pages the enabled providers declare, as paths (/name).
sub _provider_signin_paths {
    my @paths;
    for my $p ( _identity_providers() ) {
        my $page = $p->[1]{signin_page};
        push @paths, "/$page" if defined $page && !ref $page && $page =~ /\A[a-z][a-z0-9-]{0,63}\z/;
    }
    return \@paths;
}

sub _identity_template_vars {
    my @providers = _identity_providers();
    return () unless @providers;
    return (
        # Each provider that is on: its banner, the markup it answers.
        signin_banner => sub {
            my $out = '';
            for my $p (@providers) {
                my ( $id, $ip ) = @$p;
                next unless defined $ip->{banner} && !ref $ip->{banner} && _provider_on( $id, $ip );
                my ( $ok, $b ) = _call_extension_hook( $id, $ip->{banner}, _hook_context() );
                $out .= $b if $ok && defined $b && !ref $b;
            }
            return $out;
        },
        # Each provider that is on: { id, label, path } for /login, the path a
        # same-site one and the label plain text the template escapes.
        login_options => sub {
            my @o;
            for my $p (@providers) {
                my ( $id, $ip ) = @$p;
                next unless defined $ip->{login_option} && !ref $ip->{login_option} && _provider_on( $id, $ip );
                my ( $ok, $o ) = _call_extension_hook( $id, $ip->{login_option}, _hook_context() );
                next unless $ok && ref $o eq 'HASH';
                my ( $label, $path ) = @$o{qw(label path)};
                next unless defined $label && !ref $label && length $label && $label !~ /[\x00-\x1f\x7f]/;
                next unless defined $path && !ref $path && $path =~ m{\A/[\w/.-]*\z} && $path !~ m{//};
                push @o, { id => $id, label => $label, path => $path };
            }
            return \@o;
        },
    );
}

# The templates/ directory of each enabled extension that declares a component,
# for the component renderer's search path - after the layout's own components
# and the engine's built-in ones, which win.
sub _extension_component_dirs {
    my @dirs;
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        next unless defined $e->{payload} && !ref $e->{payload} && $e->{payload} =~ m{\A/};
        push @dirs, "$e->{payload}/templates" if _entry_list( $e, 'components' );
    }
    return @dirs;
}

# The templates/ directory that holds a declared component by name, or undef.
sub _extension_component_dir {
    my ($name) = @_;
    return undef unless defined $name && $name =~ /\A[\w-]+\z/;
    for my $pair ( @{ _extension_entries() } ) {
        my ( $id, $e ) = @$pair;
        next unless defined $e->{payload} && !ref $e->{payload} && $e->{payload} =~ m{\A/};
        for my $c ( _entry_list( $e, 'components' ) ) {
            next unless defined $c->{file} && !ref $c->{file} && $c->{file} eq "$name.tt";
            my $f = "$e->{payload}/templates/components/$name.tt";
            return "$e->{payload}/templates" if -f $f && !-l $f;
        }
    }
    return undef;
}

1;
