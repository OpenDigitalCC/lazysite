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
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common qw(write_file_checked);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action
    action_handler_list action_handler_save action_handler_delete
    action_form_targets_read action_form_targets_save resolve_plugin_script
);

our $DOCROOT;
our $action = '';

# === moved from lazysite-manager-api.pl (SM079a) ===

sub resolve_plugin_script {
    my ($script) = @_;
    return unless $script;
    my $base = basename($script);
    # In order: installed layout (plugins/...), under docroot, core scripts
    # in cgi-bin/ (real install) by path then basename, and finally the
    # repo/dev layout where scripts sit at the tree root. The cgi-bin cases
    # are what let plugin-read/save find lazysite-processor.pl (the site
    # config descriptor) on a deployed site, not just the dev layout.
    for my $cand (
        "$DOCROOT/../$script",
        "$DOCROOT/$script",
        "$DOCROOT/../cgi-bin/$script",
        "$DOCROOT/../cgi-bin/$base",
        "$DOCROOT/../$base",
    ) {
        return $cand if -f $cand;
    }
    return;
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
    # duplicating the schema. payment-demo has no --describe
    # support so it's not listed here.
    my @CANDIDATES = (
        'lazysite-processor.pl',
        'lazysite-auth.pl',
        'plugins/form-handler.pl',
        'plugins/form-smtp.pl',
        'plugins/log.pl',
        'plugins/audit.pl',
    );

    my $base = Cwd::realpath("$DOCROOT/..");
    my @plugins;

    for my $rel ( @CANDIDATES ) {
        my $full = "$base/$rel";
        # Core scripts (processor, auth) install into cgi-bin/, not the
        # docroot parent. The repo/dev layout has them at $base; a real
        # deployment has them under $base/cgi-bin/. Fall back so the site
        # config descriptor is discovered in both.
        $full = "$base/cgi-bin/$rel"
            if !-f $full && -f "$base/cgi-bin/$rel";
        next unless -f $full && -r $full;

        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        my $json = eval { qx($^X \Q$full\E --describe 2>/dev/null) };
        alarm(0);
        next if $@ || !$json;

        my $desc = eval { decode_json($json) };
        next unless $desc && ref $desc eq 'HASH' && $desc->{id};

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
    return _update_plugins_conf($script, 'add');
}

sub action_plugin_disable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    return _update_plugins_conf($script, 'remove');
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

    my $new_conf = join("\n", @before);
    if ( @plugins ) {
        $new_conf .= "\nplugins:\n";
        $new_conf .= "  - $_\n" for @plugins;
    }
    $new_conf .= join("\n", @after) if @after;
    $new_conf =~ s/\n{3,}/\n\n/g;
    $new_conf .= "\n" unless $new_conf =~ /\n$/;

    my ( $wok, $werr ) = write_file_checked( $conf_path, $new_conf );
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
        my $conf_path = "$DOCROOT/$config_file";
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
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
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
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

    if ($config_file) {
        my $conf_path = "$DOCROOT/$config_file";
        my $content   = '';
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            $content = do { local $/; <$fh> };
            close $fh;
        }

        for my $k ( keys %safe ) {
            if ( $content =~ /^$k\s*:/m ) {
                $content =~ s/^$k\s*:.*$/$k: $safe{$k}/m;
            }
            else {
                $content .= "$k: $safe{$k}\n";
            }
        }

        my $dir = dirname($conf_path);
        make_path($dir) unless -d $dir;
        my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
        return { ok => 0, error => "Cannot write config: $werr" }
            unless $wok;
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
        my $content   = '';
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            $content = do { local $/; <$fh> };
            close $fh;
        }

        for my $k ( grep { $want{$_} } keys %safe ) {
            if ( $content =~ /^$k\s*:/m ) {
                $content =~ s/^$k\s*:.*$/$k: $safe{$k}/m;
            }
            else {
                $content .= "$k: $safe{$k}\n";
            }
        }

        my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
        return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
            unless $wok;
    }

    return { ok => 1 };
}

sub action_plugin_action {
    my ( $plugin_id, $script, $action_id ) = @_;

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

    my $output = qx($^X \Q$full_script\E --scan --docroot \Q$DOCROOT\E 2>/dev/null);
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

    my $content = "targets:\n";
    for my $t (@$targets) {
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

1;
