package Lazysite::Manager::Plugins;

# SM079: manager plugin, handler-config and form-target handlers. Plugins are
# probed and run via `qx($^X <plugin> --describe/--scan)`. Context ($DOCROOT,
# $action for log attribution) is set by the dispatcher.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use Cwd qw(realpath);
use Digest::SHA               qw(sha256_hex);
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common qw(write_file_checked);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action
    action_handler_list action_handler_save action_handler_delete action_form_list
    action_form_targets_read action_form_targets_save action_form_submissions
    action_form_submission_delete action_form_submission_confirm
    action_form_submissions_delete_bulk
    resolve_plugin_script
);

our $DOCROOT;
our $action = '';

# SM255 (completion): every write to lazysite.conf goes through Common's single
# writer, which locks, writes atomically and records the change. This module
# used to write the file twice by hand - once for the plugins: block (no commit)
# and once for a Site-settings save (its own commit) - which is the same
# one-file-two-mechanisms split SM255 set out to remove, in the one module the
# original change missed.
#
# Each manager module carries its own $DOCROOT and the dispatcher sets it per
# request, so the shared writer must be pointed at ours for the duration of the
# write or it looks in the wrong docroot.
sub _write_conf_content {
    my ( $content, $message ) = @_;
    no warnings 'once';
    local $Lazysite::Manager::Common::DOCROOT = $DOCROOT;
    return Lazysite::Manager::Common::write_conf_content( $content, $message );
}

# === moved from lazysite-manager-api.pl (SM079a) ===

# SM152: the plugin registry - the canonical, authoritative enumeration of the
# scripts the manager may probe/run. Keys are the stable plugin identifiers
# ("plugins/<name>.pl", plus the two core descriptor scripts); values are the
# resolved absolute paths. This is the ONLY place a plugin identity maps to a
# filesystem path, and it is built by SCANNING the known locations - never from
# request input. A request names a plugin by its registry KEY; the key is looked
# up here. This is both the security boundary (SEC-2026-07: the old resolver
# interpolated the request `script` straight into a path with only a `-f` check,
# so `plugin-action {script:"../../x.pl"}` or `{script:"content/x.md"}` executed
# an arbitrary on-disk file as Perl via qx($^X ...) - authenticated RCE) and the
# canonical source of plugin data for the manager UI.
sub plugin_registry {
    my $base = Cwd::realpath("$DOCROOT/..");
    my %reg;
    return \%reg unless defined $base;

    # Core descriptor scripts: at the install root, or under cgi-bin/ on a
    # real deployment. They publish config schemas (the site config page).
    for my $core (qw(lazysite-processor.pl lazysite-auth.pl)) {
        for my $cand ( "$base/$core", "$base/cgi-bin/$core" ) {
            if ( -f $cand && -r $cand ) { $reg{$core} = $cand; last }
        }
    }

    # Installed plugins: plugins/<name>.pl. Name restricted to a plain filename
    # (no path separators), so a symlink/entry cannot smuggle a traversal key.
    if ( opendir my $pd, "$base/plugins" ) {
        for my $f ( sort grep { /\A[A-Za-z0-9_.-]+\.pl\z/ } readdir $pd ) {
            my $p = "$base/plugins/$f";
            $reg{"plugins/$f"} = $p if -f $p && -r $p && !-l $p;
        }
        closedir $pd;
    }
    return \%reg;
}

# Resolve a request-named plugin to its absolute path via the registry ONLY.
# An exact key match returns the canonical path; anything else (a traversal
# path, an arbitrary file, an unregistered name) returns undef and the caller
# reports "unknown plugin" - it never runs.
sub resolve_plugin_script {
    my ($script) = @_;
    return unless defined $script && length $script;
    return plugin_registry()->{$script};
}

sub action_plugin_list {
    my $cache_file = "$DOCROOT/lazysite/cache/plugin-list.cache";
    if ( -f $cache_file && (time() - (stat($cache_file))[9]) < 60 ) {
        open my $fh, '<', $cache_file or return { ok=>0, error=>"cache read failed" };
        my $data = do { local $/; <$fh> }; close $fh;
        my $parsed = eval { decode_json($data) };
        return $parsed if $parsed && $parsed->{ok};
    }

    my %enabled;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    if ( open my $fh, '<:utf8', $conf_path ) {
        my $in_plugins = 0;
        while (<$fh>) {
            chomp;
            if (/^plugins\s*:\s*$/) { $in_plugins = 1; next }
            if ($in_plugins && /^\s+-\s+(.+)$/) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                $enabled{$entry} = 1;
            }
            elsif ($in_plugins && !/^\s/) { $in_plugins = 0 }
        }
        close $fh;
    }

    # D022: plugins moved to plugins/ with the lazysite- prefix
    # dropped. lazysite-processor.pl and lazysite-auth.pl stay at
    # repo root (core) but expose --describe and are plugins in
    # the manager-UI sense — the site config page at config.md
    # drives its form from the processor's descriptor rather than
    # duplicating the schema. Every shipped plugin answers
    # --describe (payment-demo included, marked demo:true).
    my @plugins;

    # SM152: the registry is the single canonical enumeration - core descriptor
    # scripts + plugins/*.pl, each mapped to its resolved absolute path. Every
    # candidate is still validated by --describe below (a non-plugin .pl is
    # dropped); a new plugins/*.pl appears automatically. This is the same map
    # resolve_plugin_script uses, so what is LISTED is exactly what can be RUN.
    my $reg = plugin_registry();

    for my $rel ( sort keys %$reg ) {
        my $full = $reg->{$rel};
        next unless -f $full && -r $full;

        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        my $json = eval { qx($^X \Q$full\E --describe 2>/dev/null) };
        alarm(0);
        next if $@ || !$json;

        my $desc = eval { decode_json($json) };
        next unless $desc && ref $desc eq 'HASH' && $desc->{id};
        # A plugin may mark itself unlisted (e.g. the payment demo helper): it
        # ships and works, but is not a user-facing toggle in the Plugin Manager.
        next if $desc->{unlisted};

        $desc->{_script}  = $rel;
        $desc->{_enabled} = $enabled{$rel} ? JSON::PP::true : JSON::PP::false;

        push @plugins, $desc;
    }

    @plugins = sort {
        ($b->{_enabled} ? 1 : 0) <=> ($a->{_enabled} ? 1 : 0)
            || ($a->{name} // '') cmp ($b->{name} // '')
    } @plugins;

    my $cache_dir = dirname($cache_file);
    make_path($cache_dir) unless -d $cache_dir;
    if ( open my $fh, '>', $cache_file ) {
        print $fh encode_json({ ok => 1, plugins => \@plugins });
        close $fh;
    }

    return { ok => 1, plugins => \@plugins };
}

sub action_plugin_enable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    # SM152: only a REGISTERED plugin can be enabled - so a stray name can never
    # be written into the conf `plugins:` list (and the on_enable hook only ever
    # runs a registry script).
    return { ok => 0, error => "Unknown plugin: $script" }
        unless plugin_registry()->{$script};
    my $r = _update_plugins_conf( $script, 'add' );
    return $r unless $r->{ok};
    my $hook = _run_plugin_hook( $script, 'on_enable' );
    $r->{hook} = $hook if $hook;
    return $r;
}

sub action_plugin_disable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    my $r = _update_plugins_conf( $script, 'remove' );
    return $r unless $r->{ok};
    my $hook = _run_plugin_hook( $script, 'on_disable' );
    $r->{hook} = $hook if $hook;
    return $r;
}

# Field feedback (2026-07-11): enabling a plugin IS enabling its feature - a
# second Enable on the config page is a trap. A plugin may declare on_enable /
# on_disable in its descriptor (each names one of its own declared actions);
# the named action runs right after the Plugin-Manager toggle and its result
# travels back as `hook` for the page's status line. Hook ids resolve against
# the descriptor's actions, so - exactly as in action_plugin_action - only
# descriptor literals ever reach the command line. A failed hook never undoes
# the toggle: the plugin's own status action is the recovery surface.
sub _run_plugin_hook {
    my ( $script, $hook_key ) = @_;
    my $full_script = resolve_plugin_script($script);
    return undef unless $full_script;
    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) };
    return undef unless $desc && ref $desc eq 'HASH';
    my $id = $desc->{$hook_key};
    return undef unless defined $id && length $id;
    my ($action) = grep { ( $_->{id} // '' ) eq $id } @{ $desc->{actions} // [] };
    return { ok => 0, error => "$hook_key names an undeclared action '$id'" }
        unless $action && ( $action->{run} // '' ) eq 'action';
    local $ENV{LAZYSITE_ACTING_USER} = $Lazysite::Manager::Common::auth_user // '';
    my $args   = join ' ', map { quotemeta } ( '--action', $id );
    my $output = qx($^X \Q$full_script\E $args --docroot \Q$DOCROOT\E);
    return eval { decode_json($output) }
        // { ok => 0, error => 'hook produced no output' };
}

sub _update_plugins_conf {
    my ($script, $op) = @_;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    open my $fh, '<:utf8', $conf_path
        or return { ok => 0, error => "Cannot read lazysite.conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;

    my @lines   = split /\n/, $conf;
    my @plugins;
    my $in_plugins = 0;
    my $found_block = 0;
    my @before;
    my @after;
    my $phase = 'before';

    for my $line (@lines) {
        if ( $line =~ /^plugins\s*:\s*$/ ) {
            $in_plugins = 1;
            $found_block = 1;
            $phase = 'plugins';
            next;
        }
        if ( $in_plugins ) {
            if ( $line =~ /^\s+-\s+(.+)$/ ) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                push @plugins, $entry;
                next;
            }
            elsif ( $line !~ /^\s/ ) {
                $in_plugins = 0;
                $phase = 'after';
            }
            else { next }
        }
        if    ( $phase eq 'before' ) { push @before, $line }
        elsif ( $phase eq 'after' )  { push @after, $line }
    }

    if ( $op eq 'add' ) {
        push @plugins, $script unless grep { $_ eq $script } @plugins;
    }
    elsif ( $op eq 'remove' ) {
        @plugins = grep { $_ ne $script } @plugins;
    }

    # Rebuild line-wise. (The old string concatenation lost the newline
    # between the last before-line and the first after-line whenever the
    # plugins block emptied - removing a site's only plugin glued two conf
    # keys into one corrupt line.)
    my @out = @before;
    if (@plugins) {
        push @out, 'plugins:', map { "  - $_" } @plugins;
    }
    push @out, @after;
    my $new_conf = join( "\n", @out );
    $new_conf =~ s/\n{3,}/\n\n/g;
    $new_conf .= "\n" unless $new_conf =~ /\n$/;

    my ( $wok, $werr ) = _write_conf_content( $new_conf,
        ( $op eq 'add' ? "enable plugin $script" : "disable plugin $script" ) );
    return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
        unless $wok;

    unlink "$DOCROOT/lazysite/cache/plugin-list.cache";

    return { ok => 1, action => $op, script => $script };
}

sub action_plugin_read {
    my ( $plugin_id, $script ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my $config_file = $desc->{config_file} // '';
    my %values;

    if ($config_file) {
        my $plugin_conf = "$DOCROOT/$config_file";
        if ( -f $plugin_conf and open my $fh, '<:utf8', $plugin_conf ) {
            while (<$fh>) {
                chomp;
                s/^\s+|\s+$//g;
                next if /^#/ || !length;
                my ( $k, $v ) = split /\s*:\s*/, $_, 2;
                $values{$k} = $v if defined $k && defined $v;
            }
            close $fh;
        }
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
        if ( -f $conf_path and open my $fh, '<:utf8', $conf_path ) {
            while (<$fh>) {
                chomp;
                s/^\s+|\s+$//g;
                next if /^#/ || !length;
                my ( $k, $v ) = split /\s*:\s*/, $_, 2;
                $values{$k} = $v if $want{$k};
            }
            close $fh;
        }
    }

    # Never return password fields
    for my $field ( @{ $desc->{config_schema} // [] } ) {
        delete $values{ $field->{key} } if ( $field->{type} // '' ) eq 'password';
    }

    return { ok => 1, values => \%values };
}

sub action_plugin_save {
    my ( $plugin_id, $script, $values ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my %allowed = map { $_->{key} => 1 } @{ $desc->{config_schema} // [] };
    my %safe;
    for my $k ( keys %$values ) {
        $safe{$k} = $values->{$k} if $allowed{$k};
    }

    my $config_file = $desc->{config_file} // '';

    # Track which keys ACTUALLY changed - the UI posts the whole form, so
    # without a diff the audit says "8 settings" for a one-field edit.
    my @changed;
    my $apply = sub {
        my ( $content_ref, $k ) = @_;
        if ( ${$content_ref} =~ /^$k\s*:[ \t]*(.*)$/m ) {
            my $old = $1;
            push @changed, $k if $old ne ( $safe{$k} // '' );
            ${$content_ref} =~ s/^$k\s*:.*$/$k: $safe{$k}/m;
        }
        else {
            push @changed, $k if length( $safe{$k} // '' );
            ${$content_ref} .= "$k: $safe{$k}\n";
        }
        return;
    };

    if ($config_file) {
        # $plugin_conf, not $conf_path: this branch writes the PLUGIN'S OWN
        # config file, while the branch below writes lazysite.conf. They had the
        # same variable name, which reads as one thing written two ways.
        my $plugin_conf = "$DOCROOT/$config_file";
        my $content     = '';
        if ( -f $plugin_conf and open my $fh, '<:utf8', $plugin_conf ) {
            $content = do { local $/; <$fh> };
            close $fh;
        }

        $apply->( \$content, $_ ) for keys %safe;

        my $dir = dirname($plugin_conf);
        make_path($dir) unless -d $dir;
        my ( $wok, $werr ) = write_file_checked( $plugin_conf, $content );
        return { ok => 0, error => "Cannot write config: $werr" }
            unless $wok;

        # A config carrying a password field must not be world-readable -
        # notify-xmpp.conf sits at the lazysite/ top level, outside the
        # mode-checked directories (2026-07-10 review, D6).
        chmod 0660, $plugin_conf
            if grep { ( $_->{type} // '' ) eq 'password' }
            @{ $desc->{config_schema} // [] };
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
        my $content   = '';
        if ( -f $conf_path and open my $fh, '<:utf8', $conf_path ) {
            $content = do { local $/; <$fh> };
            close $fh;
        }

        $apply->( \$content, $_ ) for grep { $want{$_} } keys %safe;

        # SM085: lazysite.conf is one of the two versioned config files, so a
        # Site-settings save is recorded. SM255 (completion): the writer records
        # it, rather than this branch committing its own write - that private
        # commit is exactly how the two mechanisms diverged. @changed still
        # shapes the MESSAGE, so a one-field edit does not read as "8 settings".
        my $msg = @changed
            ? 'edit lazysite/lazysite.conf (' . join( ', ', sort @changed ) . ')'
            : 'edit lazysite/lazysite.conf';
        my ( $wok, $werr ) = _write_conf_content( $content, $msg );
        return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
            unless $wok;
    }

    return { ok => 1, changed => [ sort @changed ] };
}

sub action_plugin_action {
    my ( $plugin_id, $script, $action_id, $req_params ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my ($action) = grep { $_->{id} eq $action_id } @{ $desc->{actions} // [] };
    return { ok => 0, error => 'Action not found' } unless $action;

    if ( $action->{link} ) {
        return { ok => 1, link => $action->{link} };
    }

    # SM085 (git-sync): the minimal generic extension for parameterised plugin
    # actions. An action that declares run:'action' in the descriptor is
    # invoked as `--action <id>` (the legacy default stays `--scan`), and may
    # declare `choices`; a request's params.choice is accepted ONLY when it
    # matches a declared choice id, so nothing request-controlled ever reaches
    # the command line - every argument below is a descriptor literal. The
    # acting user travels in the environment for the plugin's own attribution
    # (commits, snapshots, log lines). Action-mode stderr is NOT discarded:
    # the plugin's log_event lines belong in the server error log.
    my @argv     = ('--scan');
    my $redirect = '2>/dev/null';
    if ( ( $action->{run} // '' ) eq 'action' ) {
        @argv     = ( '--action', $action->{id} );
        $redirect = '';
        my $choice = ( ref $req_params eq 'HASH' ) ? $req_params->{choice} : undef;
        if ( defined $choice && length $choice ) {
            return { ok => 0, error => 'Unknown choice' }
                unless grep { ( $_->{id} // '' ) eq $choice }
                @{ $action->{choices} // [] };
            push @argv, '--choice', $choice;
        }
    }
    local $ENV{LAZYSITE_ACTING_USER} = $Lazysite::Manager::Common::auth_user // '';
    my $args   = join ' ', map { quotemeta } @argv;
    my $output = qx($^X \Q$full_script\E $args --docroot \Q$DOCROOT\E $redirect);
    my $result = eval { decode_json($output) }
        // { ok => 0, error => 'Action produced no output' };

    return $result;
}

sub _handlers_conf_path {
    return "$DOCROOT/lazysite/forms/handlers.conf";
}

sub _parse_handlers_conf {
    my $path = _handlers_conf_path();
    return [] unless -f $path;

    open my $fh, '<:utf8', $path or return [];
    my $text = do { local $/; <$fh> };
    close $fh;

    my @handlers;
    while ( $text =~ /^\s{2}-\s+id:\s*(\S+)(.*?)(?=^\s{2}-\s+id:|\z)/gmsx ) {
        my ( $id, $block ) = ( $1, $2 );
        my %h = ( id => $id );
        while ( $block =~ /^\s{4}(\w+)\s*:\s*(.+)$/mg ) {
            my ( $k, $v ) = ( $1, $2 );
            $v =~ s/\s+$//;
            $h{$k} = $v;
        }
        push @handlers, \%h;
    }
    return \@handlers;
}

sub _write_handlers_conf {
    my ($handlers) = @_;
    my $path = _handlers_conf_path();

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;

    my $content = "# Form dispatch handlers\n";
    $content .= "# Add handlers here and reference them from form .conf files\n\n";
    $content .= "handlers:\n";

    for my $h (@$handlers) {
        $content .= "  - id: $h->{id}\n";
        for my $k ( sort keys %$h ) {
            next if $k eq 'id';
            $content .= "    $k: $h->{$k}\n";
        }
    }

    my ( $wok ) = write_file_checked( $path, $content );
    return $wok;
}

sub action_handler_list {
    my $handlers = _parse_handlers_conf();
    return { ok => 1, handlers => $handlers };
}

# SM214: enumerate the site's forms for a token client (or the manager) that can
# read submissions but cannot list plugins/handlers (those are cookie-only). A
# "form" is a lazysite/forms/<name>.conf, excluding the special handlers.conf and
# smtp.conf. Read-only and PII-free (names + handler types + row COUNTS only, never
# submission content), so it is safe on the read_submissions gate. Answers "what
# forms exist?" and "which deliver to email vs storage, and did any come in?".
sub action_form_list {
    my $dir      = "$DOCROOT/lazysite/forms";
    my $handlers = _parse_handlers_conf();
    my %by_id    = map { $_->{id} => $_ } @$handlers;

    my @forms;
    opendir my $dh, $dir or return { ok => 1, forms => [] };
    for my $f ( sort readdir $dh ) {
        next unless $f =~ /^(.+)\.conf\z/;
        my $name = $1;
        next if $name eq 'handlers' || $name eq 'smtp';

        # handler ids this form's targets reference
        my @hids;
        if ( open my $cf, '<:utf8', "$dir/$f" ) {
            local $/;
            my $t = <$cf>;
            close $cf;
            while ( $t =~ /^\s*-\s*handler:\s*(\S+)/mg ) { push @hids, $1 }
        }
        my %seen;
        my @types = grep { !$seen{$_}++ }
            map { ( $by_id{$_} && $by_id{$_}{type} ) || 'unknown' } @hids;

        # submissions store: the file-target handler's path (default submissions/)
        # + <name>.jsonl. Count non-blank lines; never read the content.
        my $store_dir = 'lazysite/forms/submissions';
        for my $id (@hids) {
            my $h = $by_id{$id} or next;
            next unless ( $h->{type} // 'file' ) eq 'file';
            $store_dir = $h->{path} if defined $h->{path} && length $h->{path};
            last;
        }
        my $store = "$DOCROOT/$store_dir/$name.jsonl";
        my ( $has, $rows ) = ( JSON::PP::false, 0 );
        if ( -f $store && open my $sf, '<', $store ) {
            $has = JSON::PP::true;
            while ( my $l = <$sf> ) { $rows++ if $l =~ /\S/ }
            close $sf;
        }

        push @forms,
            {
            name          => $name,
            handlers      => \@hids,
            handler_types => \@types,
            has_store     => $has,
            row_count     => $rows,     # SM227: the unambiguous name
            rows          => $rows,     # SM227: deprecated alias, see below
            };
    }
    closedir $dh;

    # SM227: this listing returns COUNTS and never content, which is deliberate
    # least-privilege design. It also read as "the store is write-only" to a
    # partner, who then specified a replacement store rather than asking for the
    # grant that already reads it. Two things caused that. The `rows` key means a
    # COUNT here and an ARRAY OF ROWS in the sibling action_form_submissions - the
    # same name for two different things - so `row_count` is now the canonical
    # spelling and `rows` stays only as a deprecated alias for one release. And a
    # response that says nothing about its own scope leaves the reader to guess:
    # the note names the companion action and the capability that unlocks it, so
    # the answer travels with the payload rather than living in a tool description
    # the reader has already moved past.
    return {
        ok    => 1,
        forms => \@forms,
        note  => 'Counts only - this action never returns submission content. To '
            . 'read the rows, call read_form_submissions (MCP) or form-submissions '
            . '(control API), which need the read_submissions capability. '
            . '"row_count" is the count; the "rows" key is a deprecated alias for '
            . 'it and will be removed.',
    };
}

sub action_handler_save {
    my ($data) = @_;
    my $id = $data->{id} // '';
    $id =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid handler ID" } unless $id;

    my $handlers = _parse_handlers_conf();

    # Build handler record from input
    my %new = ( id => $id );
    for my $k (qw(type name enabled from to subject_prefix path url format
                   method sendmail_path host port tls auth username password_file)) {
        $new{$k} = $data->{$k} if defined $data->{$k} && length $data->{$k};
    }
    $new{type} //= 'file';

    # Replace existing or append
    my $found = 0;
    for my $h (@$handlers) {
        if ( $h->{id} eq $id ) {
            %$h = %new;
            $found = 1;
            last;
        }
    }
    push @$handlers, \%new unless $found;

    _write_handlers_conf($handlers)
        or return { ok => 0, error => "Cannot write handlers.conf" };

    return { ok => 1, id => $id };
}

sub action_handler_delete {
    my ($id) = @_;
    return { ok => 0, error => "No handler ID" } unless $id;

    my $handlers = _parse_handlers_conf();
    my @filtered = grep { $_->{id} ne $id } @$handlers;

    if ( scalar @filtered == scalar @$handlers ) {
        return { ok => 0, error => "Handler not found: $id" };
    }

    _write_handlers_conf(\@filtered)
        or return { ok => 0, error => "Cannot write handlers.conf" };

    return { ok => 1, deleted => $id };
}

sub action_form_targets_read {
    my ($form_name) = @_;
    $form_name //= '';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid form name" } unless $form_name;

    my $path = "$DOCROOT/lazysite/forms/$form_name.conf";
    return { ok => 1, targets => [] } unless -f $path;

    open my $fh, '<:utf8', $path or return { ok => 0, error => "Cannot read form config" };
    my $text = do { local $/; <$fh> };
    close $fh;

    my @targets;

    # SM081: parse the YAML-ish list in document order, recognising either a
    # handler reference or an inline type config at EACH entry. (Previously the
    # legacy type block was parsed only `if (!@targets)`, so a form mixing both
    # formats silently dropped its type targets on read-back.)
    for my $entry ( split /^[ \t]*-[ \t]+/m, $text ) {
        if ( $entry =~ /\Ahandler:\s*(\S+)/ ) {
            push @targets, { handler => $1 };
        }
        elsif ( $entry =~ /\Atype:\s*(\w+)/ ) {
            my %t = ( type => $1 );
            $t{url}    = $1 if $entry =~ /^\s*url:\s*(.+)$/m;
            $t{format} = $1 if $entry =~ /^\s*format:\s*(.+)$/m;
            $t{path}   = $1 if $entry =~ /^\s*path:\s*(.+)$/m;
            $t{$_} =~ s/^\s+|\s+$//g for grep { defined $t{$_} } keys %t;
            push @targets, \%t;
        }
    }

    return { ok => 1, form => $form_name, targets => \@targets };
}

sub action_form_targets_save {
    my ( $form_name, $targets ) = @_;
    $form_name //= '';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid form name" } unless $form_name;

    my $path = "$DOCROOT/lazysite/forms/$form_name.conf";
    my $dir  = dirname($path);
    make_path($dir) unless -d $dir;

    # DATA-LOSS GUARD: the manager UI ("Edit targets") only represents HANDLER
    # targets - it collapses each target to its handler id. A form may also carry
    # LEGACY INLINE targets (type/url/format/path) authored by hand or over
    # WebDAV, which the UI cannot show and would therefore erase on save. Preserve
    # any inline target already in the file, UNLESS this submission itself carries
    # inline targets (a future UI that manages them). The manager only ever
    # rewrites the handler set; inline targets survive verbatim.
    my $submission_has_inline = grep { !$_->{handler} } @$targets;
    my @preserved_inline;
    unless ($submission_has_inline) {
        my $existing = action_form_targets_read($form_name);
        @preserved_inline = grep { !$_->{handler} } @{ $existing->{targets} || [] }
            if $existing->{ok};
    }

    my $content = "targets:\n";
    for my $t ( @$targets, @preserved_inline ) {
        if ( $t->{handler} ) {
            $content .= "  - handler: $t->{handler}\n";
        }
        else {
            my $type = $t->{type} // 'file';
            $content .= "  - type: $type\n";
            for my $k (qw(url format path)) {
                $content .= "    $k: $t->{$k}\n" if defined $t->{$k} && length $t->{$k};
            }
        }
    }

    my ( $wok, $werr ) = write_file_checked( $path, $content );
    return { ok => 0, error => "Cannot write form config: $werr" }
        unless $wok;

    return { ok => 1, form => $form_name };
}

# SM182: read a form-submissions store (<dir>/<form>.jsonl, one JSON record per
# line, as written by the form-handler local-storage target) and return it as a
# STRUCTURED table - columns + rows - so the manager can render it safely.
# Submissions are user-supplied, so values are returned verbatim (stringified)
# and the CLIENT escapes every cell; nothing is interpolated here. The store is a
# reserved lazysite/ file the raw editor refuses, which is why this dedicated,
# read-only, capability-gated view exists. Rows are capped (most recent) so a
# large store never floods the browser.
# SM182/SM187: confine a submissions-file argument to a .jsonl under the docroot.
# Returns ( $abs_path, $rel, undef ) or ( undef, undef, $error ).
sub _submissions_path {
    my ($file) = @_;
    ( my $rel = $file // '' ) =~ s{^/+}{};
    return ( undef, undef, 'Invalid submissions file' )
        unless $rel =~ /\.jsonl\z/ && $rel !~ m{(?:^|/)\.\.(?:/|$)};
    my $abs  = "$DOCROOT/$rel";
    my $real = realpath( -e $abs ? $abs : dirname($abs) );
    return ( undef, undef, 'Invalid submissions file' )
        unless defined $real
        && ( $real eq $DOCROOT || index( $real, "$DOCROOT/" ) == 0 );
    return ( $abs, $rel, undef );
}

# A stable per-row id: a short hash of the raw JSONL line, so the UI can ask to
# delete a specific record without a line number that shifts as rows are removed.
sub _submission_row_id { substr( sha256_hex( $_[0] ), 0, 16 ) }

sub action_form_submissions {
    my ($file) = @_;
    my ( $abs, $rel, $err ) = _submissions_path($file);
    return { ok => 0, error => $err } if $err;
    return { ok => 1, file => $rel, columns => [], rows => [], total => 0, shown => 0 }
        unless -f $abs;

    open my $fh, '<:utf8', $abs
        or return { ok => 0, error => 'Cannot read submissions' };
    my $CAP = 500;
    my ( @rows, @raw, @cols, %seen, $total, $malformed );
    while ( my $line = <$fh> ) {
        ( my $trim = $line ) =~ s/\s+\z//;
        next unless length $trim;
        $total++;
        my $rec = eval { decode_json($trim) };
        if ( ref $rec ne 'HASH' ) { $malformed++; next }
        push @cols, $_ for grep { !$seen{$_}++ } keys %$rec;
        push @rows, $rec;
        push @raw,  $trim;
    }
    close $fh;

    if ( @rows > $CAP ) { @rows = @rows[ -$CAP .. -1 ]; @raw = @raw[ -$CAP .. -1 ] }
    # Stringify every value (a nested ref is JSON-encoded); the client escapes.
    # Each row carries a stable _id (raw-line hash) so it can be deleted.
    my @out = map {
        my ( $r, $raw ) = ( $rows[$_], $raw[$_] );
        +{  _id => _submission_row_id($raw),
            map {
                $_ => ( !defined $r->{$_} ? ''
                    : ref $r->{$_} ? encode_json( $r->{$_} )
                    : "$r->{$_}" )
            } @cols
        }
    } 0 .. $#rows;

    return {
        ok        => 1,
        file      => $rel,
        columns   => \@cols,
        rows      => \@out,
        total     => ( $total   || 0 ),
        shown     => scalar(@out),
        truncated => ( $total > $CAP ? 1 : 0 ),
        malformed => ( $malformed || 0 ),
    };
}

# SM187: delete ONE handled submission row from a store, identified by the stable
# _id (raw-line hash) that action_form_submissions returns. Rewrites the .jsonl
# without the matched line, atomically (temp + rename). manage_forms-gated +
# audited by the dispatch wrapper. Returns { ok, deleted } or { ok=>0, error }.
sub action_form_submission_delete {
    my ( $file, $id ) = @_;
    my ( $abs, $rel, $err ) = _submissions_path($file);
    return { ok => 0, error => $err } if $err;
    return { ok => 0, error => 'A row id is required' }
        unless defined $id && $id =~ /\A[0-9a-f]{16}\z/;
    return { ok => 0, error => 'No such submissions store' } unless -f $abs;

    open my $fh, '<:utf8', $abs or return { ok => 0, error => 'Cannot read submissions' };
    my ( @keep, $deleted );
    while ( my $line = <$fh> ) {
        ( my $trim = $line ) =~ s/\s+\z//;
        if ( !$deleted && length $trim && _submission_row_id($trim) eq $id ) {
            $deleted = 1;
            next;
        }
        push @keep, $line;
    }
    close $fh;
    return { ok => 0, error => 'Row not found' } unless $deleted;

    my $tmp = "$abs.tmp.$$";
    open my $out, '>:utf8', $tmp or return { ok => 0, error => 'Cannot write submissions' };
    print {$out} @keep;
    close $out;
    rename $tmp, $abs
        or do { unlink $tmp; return { ok => 0, error => 'Cannot replace submissions' } };
    return { ok => 1, file => $rel, deleted => 1 };
}

# SM216: confirm a quarantined submission as legitimate - clear its _quarantined /
# _spam_reason flags on the stored row (by stable id), so it leaves the Quarantine
# filter. The row content is untouched; a false positive is recovered in one click.
# (Deleting a genuine spam row stays action_form_submission_delete.)
sub action_form_submission_confirm {
    my ( $file, $id ) = @_;
    my ( $abs, $rel, $err ) = _submissions_path($file);
    return { ok => 0, error => $err } if $err;
    return { ok => 0, error => 'A row id is required' }
        unless defined $id && $id =~ /\A[0-9a-f]{16}\z/;
    return { ok => 0, error => 'No such submissions store' } unless -f $abs;

    open my $fh, '<:utf8', $abs or return { ok => 0, error => 'Cannot read submissions' };
    my ( @out, $confirmed );
    while ( my $line = <$fh> ) {
        ( my $trim = $line ) =~ s/\s+\z//;
        if ( !$confirmed && length $trim && _submission_row_id($trim) eq $id ) {
            my $rec = eval { decode_json($trim) };
            if ( ref $rec eq 'HASH' ) {
                delete @{$rec}{qw(_quarantined _spam_reason)};
                push @out, encode_json($rec) . "\n";
                $confirmed = 1;
                next;
            }
        }
        push @out, $line;
    }
    close $fh;
    return { ok => 0, error => 'Row not found' } unless $confirmed;

    my $tmp = "$abs.tmp.$$";
    open my $w, '>:utf8', $tmp or return { ok => 0, error => 'Cannot write submissions' };
    print {$w} @out;
    close $w;
    rename $tmp, $abs
        or do { unlink $tmp; return { ok => 0, error => 'Cannot replace submissions' } };
    return { ok => 1, file => $rel, confirmed => 1 };
}

# SM187 v2: delete several rows in ONE atomic rewrite - bulk cleanup, e.g.
# clearing a spam batch out of a store. Same path confinement + stable-id
# matching as the single delete; UI-only (destructive PII). Unknown ids are
# simply not matched; the result reports how many requested ids were removed.
sub action_form_submissions_delete_bulk {
    my ( $file, $ids ) = @_;
    my ( $abs, $rel, $err ) = _submissions_path($file);
    return { ok => 0, error => $err } if $err;
    return { ok => 0, error => 'No row ids given' }
        unless ref $ids eq 'ARRAY' && @$ids;
    my %want;
    for my $id (@$ids) {
        return { ok => 0, error => 'A row id is malformed' }
            unless defined $id && $id =~ /\A[0-9a-f]{16}\z/;
        $want{$id} = 1;
    }
    return { ok => 0, error => 'No such submissions store' } unless -f $abs;

    open my $fh, '<:utf8', $abs or return { ok => 0, error => 'Cannot read submissions' };
    my ( @keep, $deleted );
    $deleted = 0;
    while ( my $line = <$fh> ) {
        ( my $trim = $line ) =~ s/\s+\z//;
        if ( length $trim && $want{ _submission_row_id($trim) } ) { $deleted++; next; }
        push @keep, $line;
    }
    close $fh;
    return { ok => 0, error => 'No matching rows' } unless $deleted;

    my $tmp = "$abs.tmp.$$";
    open my $out, '>:utf8', $tmp or return { ok => 0, error => 'Cannot write submissions' };
    print {$out} @keep;
    close $out;
    rename $tmp, $abs
        or do { unlink $tmp; return { ok => 0, error => 'Cannot replace submissions' } };
    return { ok => 1, file => $rel, deleted => $deleted };
}

1;
