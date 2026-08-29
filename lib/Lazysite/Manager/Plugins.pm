package Lazysite::Manager::Plugins;

# SM079: manager plugin, handler-config and form-target handlers. Plugins are
# probed and run via `qx($^X <plugin> --describe/--scan)`. Context ($DOCROOT,
# $action for log attribution) is set by the dispatcher.

use strict;
use warnings;
use JSON::PP                  qw(encode_json decode_json);
use File::Basename            qw(dirname);
use File::Path                qw(make_path);
use Cwd                       qw(realpath);
use Digest::SHA               qw(sha256_hex);
use Lazysite::Util            qw(log_event);
use Lazysite::Manager::Common qw(write_file_checked);
use Exporter 'import';
use Lazysite::Paths ();

our @EXPORT_OK = qw(
    action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action
    action_handler_list action_handler_save action_handler_delete action_form_list
    action_form_delete
    action_form_targets_read action_form_targets_save action_form_submissions
    action_form_submission_delete action_form_submission_confirm
    action_form_submissions_delete_bulk
    resolve_plugin_script plugin_enabled
);

our $DOCROOT;

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
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

# SM409: the plugins: list in lazysite.conf, as a map. This parse used to
# live inline in action_plugin_list, where its only consumer was the LISTING -
# which is precisely how "disabled" came to mean a display state rather than a
# fact: nothing on any execution path ever read it.
sub _enabled_map {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my %enabled;
    my $conf_path = _lz() . "/lazysite.conf";
    if ( open my $fh, '<:utf8', $conf_path ) {
        my $in_plugins = 0;
        while (<$fh>) {
            chomp;
            if (/^plugins\s*:\s*$/) { $in_plugins = 1; next }
            if ( $in_plugins && /^\s+-\s+(.+)$/ ) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                $enabled{$entry} = 1;
            }
            elsif ( $in_plugins && !/^\s/ ) { $in_plugins = 0 }
        }
        close $fh;
    }
    return \%enabled;
}

sub plugin_enabled { return _enabled_map()->{ $_[0] } ? 1 : 0 }

# SM409 / ADR 0009: DISABLED MEANS OFF - for plugins that opt into the
# contract. A descriptor that declares `contract` is gated: it EXECUTES only
# when its script appears in the plugins: list, and it defaults to disabled,
# because a contract plugin is born with the off switch (the data plugin is
# the first). A legacy descriptor (no `contract` key) is untouched: existing
# plugins keep running exactly as they always have, until each one's
# migration SM enables it explicitly to replicate its current effective
# state - the release manager's ruling, so that nothing in the field changes
# behaviour on upgrade.
#
# The gate refuses EXECUTION (actions, hooks). Config read/save stay open on
# a disabled plugin, deliberately: an operator must be able to configure a
# plugin before enabling it, and the enable flow itself is a config surface.
#
# Returns undef when the plugin may run, or the refusal hash when it may not.
sub _gate_execution {
    my ( $script, $desc ) = @_;
    return undef unless ref $desc eq 'HASH' && $desc->{contract};
    return undef if plugin_enabled($script);
    log_event( 'WARN', 'plugin-gate', 'disabled plugin refused execution',
        plugin => $script );
    return { ok => 0,
        error => 'This plugin is disabled. A sysop can enable it on the '
            . 'Plugin Manager page.' };
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
    my $cache_file = _lz() . "/cache/plugin-list.cache";
    if ( -f $cache_file && ( time() - ( stat($cache_file) )[9] ) < 60 ) {
        open my $fh, '<', $cache_file or return { ok => 0, error => "cache read failed" };
        my $data   = do { local $/; <$fh> }; close $fh;
        my $parsed = eval { decode_json($data) };
        return $parsed if $parsed && $parsed->{ok};
    }

    my %enabled = %{ _enabled_map() };

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

        # A PLUGIN THAT OVERRUNS IS DROPPED, AND IT USED TO BE DROPPED IN
        # SILENCE. `next if $@` removed it from the Plugin Manager with nothing
        # written anywhere - so on a loaded host a sysop watches a plugin
        # disappear from the list and has no way at all to find out why. Two
        # seconds is a generous budget for a --describe and a mean one for a
        # host under load.
        #
        # THE BUDGET SCALES UNDER MEASUREMENT. Devel::Cover makes every
        # subprocess start far slower than two seconds, so an instrumented run
        # dropped lazysite-processor.pl from its own plugin list - the
        # instrument changing the thing it measures, exactly as the tempdir
        # instrumentation did. It is the same principle: measurement must not
        # alter behaviour.
        my $budget
            = ( $INC{'Devel/Cover.pm'}
                || ( $ENV{PERL5OPT} // '' ) =~ /Devel::Cover/ ) ? 30 : 2;

        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($budget);
        my $json = eval { _describe_json($full) };
        alarm(0);
        if ( $@ || !$json ) {
            log_event( 'WARN', 'plugin-list',
                'a plugin did not describe itself in time and is not listed',
                plugin => $rel,
                why    => ( $@ ? "no answer within ${budget}s" : 'empty answer' ) );
            next;
        }

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
        ( $b->{_enabled} ? 1 : 0 ) <=> ( $a->{_enabled} ? 1 : 0 )
            || ( $a->{name} // '' ) cmp( $b->{name} // '' )
    } @plugins;

    my $cache_dir = dirname($cache_file);
    make_path($cache_dir) unless -d $cache_dir;
    if ( open my $fh, '>', $cache_file ) {
        print $fh encode_json( { ok => 1, plugins => \@plugins } );
        close $fh;
    }

    return { ok => 1, plugins => \@plugins };
}

# SM152/ADR 0009: the ONE way this module asks a plugin to describe itself.
# The path is always a registry value (resolve_plugin_script or the registry
# scan), never request text. Deliberately UNGATED - a descriptor is metadata,
# and _run_plugin_hook reads it on the disable path - and deliberately carrying
# no timeout of its own: action_plugin_list is the caller that budgets the
# probe, and it wraps this call in its own alarm so an overrun still dies there.
sub _describe_json {
    my ($full) = @_;
    my $out = qx($^X \Q$full\E --describe 2>/dev/null);
    return $out;
}

# The decoded descriptor, or undef when the script said nothing or said
# something that is not JSON. Returns exactly what decode_json returned, so a
# caller may test it as it always has.
sub _describe {
    my ($full) = @_;
    return eval { decode_json( _describe_json($full) ) };
}

# SM472: the declared modules this plugin cannot run without, that are absent.
#
# Reads the plugin's OWN declaration (ADR 0009 `owns.deps`) rather than a list
# kept here - a list here would be a second opinion about the same fact, and
# would go stale the first time a plugin gained a dependency.
#
# Returns a message naming what is missing, or undef.
# Is a command available and executable?
#
# PATH is read from the environment the CGI actually runs under, with a
# conservative fallback: a plugin check must not conclude "installed" because a
# login shell would have found it while the web server would not.
#
# No shell is involved. The caller checks the name against a strict pattern and
# this joins it to a directory, so nothing here reaches a command line.
sub _bin_on_path {
    my ($bin) = @_;
    return 0 unless defined $bin && length $bin;
    my $path = $ENV{PATH} // '/usr/local/bin:/usr/bin:/bin';
    for my $dir ( split /:/, $path ) {
        next unless length $dir;
        return 1 if -x "$dir/$bin" && !-d _;
    }
    return 0;
}

sub _missing_deps {
    my ( $script, $full, $desc ) = @_;
    # TLO-1: the caller may already hold the resolved path and the descriptor.
    # Counted, not tested for truth, so an undef descriptor passed in is not
    # quietly fetched again.
    $full = resolve_plugin_script($script) if @_ < 2;
    return undef unless $full;
    $desc = _describe($full) if @_ < 3;
    return undef unless ref $desc eq 'HASH' && ref $desc->{owns} eq 'HASH';

    my @deps = @{ $desc->{owns}{deps} || [] };

    # SM694: A PLUGIN MAY DEPEND ON A PROGRAM, NOT ONLY A MODULE.
    #
    # `deps` is checked by `require`, which answers for Perl modules and
    # nothing else. A plugin wrapping an external tool - pandoc, and whatever
    # follows it - had no way to declare what it needs, so SM472's rule ("a
    # plugin that cannot run is not enabled") could not protect it: the
    # operator would get a plugin that enables and then fails at first use,
    # which is the exact state SM472 exists to prevent.
    #
    # `bins` is that declaration for an executable. Same refusal, same shape of
    # message, same Debian hint - an operator should not have to learn a second
    # idiom because the missing thing happens to be a binary.
    my @bins = @{ $desc->{owns}{bins} || [] };
    return undef unless @deps || @bins;

    my @absent;
    for my $m (@deps) {
        next unless $m =~ /\A[A-Za-z][\w:]*\z/;            # never interpolate a name
        ( my $file = "$m.pm" ) =~ s{::}{/}g;
        next if eval { require $file; 1 };
        ( my $pkg = lc $m ) =~ s{::}{-}g;
        push @absent, "$m (Debian: lib$pkg-perl)";
    }

    for my $b (@bins) {
        # A bare command name only - never a path, never a shell metacharacter.
        # This value comes from a plugin descriptor, and a lookup that
        # interpolated it would let a descriptor decide what gets executed.
        # The module branch guards its names for the same reason.
        next unless $b =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
        next if _bin_on_path($b);
        push @absent, "$b (a program, not a Perl module - Debian: $b)";
    }

    return undef unless @absent;

    return
        'This plugin needs '
        . join( ', ', @absent )
        . ' and they are not installed. It would enable and then fail on every '
        . 'request that used them, so it has been left off - install them and '
        . 'enable it again.';
}

sub action_plugin_enable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    # SM152: only a REGISTERED plugin can be enabled - so a stray name can never
    # be written into the conf `plugins:` list (and the on_enable hook only ever
    # runs a registry script).
    #
    # TLO-1: the registry is still SCANNED on this call - what it yields is
    # carried down to _missing_deps and _run_plugin_hook instead of being
    # looked up twice more. It is NOT cached across calls, which is the
    # property t/unit/manager/27 pins.
    my $full = plugin_registry()->{$script};
    return { ok => 0, error => "Unknown plugin: $script" } unless $full;

    # SM472: A PLUGIN THAT CANNOT RUN IS NOT ENABLED.
    #
    # ADR 0009 has a plugin DECLARE the modules it needs, and the SBOM gate
    # reads that list so nothing ships undeclared. Nothing was reading it at
    # the one moment it answers a question an operator has: can this work here?
    #
    # It was found the expensive way. The data plugin enabled cleanly on a host
    # without YAML::PP, listed its (empty) set of tables happily, and then
    # answered HTTP 500 to every attempt to declare one - because the parser is
    # only reached once there is something to parse. The field bisected five
    # variations of the request before concluding the write path was broken.
    # Every signal was honest and none of them said the word "YAML::PP".
    #
    # REFUSED RATHER THAN WARNED, because the alternative is a plugin that is
    # on and does not work - which is the state that produced those 500s. The
    # message names the module AND a package that provides it, so the refusal
    # is a next step rather than a dead end; install, then enable, which is the
    # right order anyway.
    #
    # ONE --describe for the whole action. The descriptor is read before the
    # conf gains the entry, and the hook below reads the same one: --describe
    # is run with no --docroot (see _describe_json), so a descriptor cannot
    # depend on this site's lazysite.conf and the write between them is
    # invisible to it.
    my $desc = _describe($full);
    if ( my $missing = _missing_deps( $script, $full, $desc ) ) {
        return { ok => 0, kind => 'missing_deps', error => $missing };
    }

    my $r = _update_plugins_conf( $script, 'add' );
    return $r unless $r->{ok};
    my $hook = _run_plugin_hook( $script, 'on_enable', $full, $desc );
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
    my ( $script, $hook_key, $full_script, $desc ) = @_;
    # TLO-1: as _missing_deps - the enable path resolves and describes once and
    # hands both down; disable calls with two arguments and does its own.
    $full_script = resolve_plugin_script($script) if @_ < 3;
    return undef unless $full_script;
    $desc = _describe($full_script) if @_ < 4;
    return undef unless $desc && ref $desc eq 'HASH';

    # SM409: hooks are deliberately NOT gated. They run only from the toggle
    # actions themselves - on_enable right after the conf gains the entry (so
    # the plugin is enabled by then), and on_disable right after the conf
    # loses it, which is the plugin's SANCTIONED last run: its one chance to
    # stop what it started. Gating here would refuse exactly that cleanup.
    # Arbitrary execution goes through action_plugin_action, which is gated.
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
    my ( $script, $op ) = @_;

    my $conf_path = _lz() . "/lazysite.conf";
    open my $fh, '<:utf8', $conf_path
        or return { ok => 0, error => "Cannot read lazysite.conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;

    my @lines = split /\n/, $conf;
    my @plugins;
    my $in_plugins  = 0;
    my $found_block = 0;
    my @before;
    my @after;
    my $phase = 'before';

    for my $line (@lines) {
        if ( $line =~ /^plugins\s*:\s*$/ ) {
            $in_plugins  = 1;
            $found_block = 1;
            $phase       = 'plugins';
            next;
        }
        if ($in_plugins) {
            if ( $line =~ /^\s+-\s+(.+)$/ ) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                push @plugins, $entry;
                next;
            }
            elsif ( $line !~ /^\s/ ) {
                $in_plugins = 0;
                $phase      = 'after';
            }
            else { next }
        }
        if    ( $phase eq 'before' ) { push @before, $line }
        elsif ( $phase eq 'after' )  { push @after,  $line }
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

    unlink _lz() . "/cache/plugin-list.cache";

    return { ok => 1, action => $op, script => $script };
}

# The one `key: value` reader this module uses. Comments and blank lines are
# dropped; every remaining line is split on its first colon. Returns EVERY pair
# the file carries - which keys are wanted, and whether a key with no value
# counts, is the caller's question and the two callers answer it differently.
sub _read_kv_lines {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ($path) = @_;
    my %kv;
    if ( -f $path and open my $fh, '<:utf8', $path ) {
        while (<$fh>) {
            chomp;
            s/^\s+|\s+$//g;
            next if /^#/ || !length;
            my ( $k, $v ) = split /\s*:\s*/, $_, 2;
            $kv{$k} = $v if defined $k;
        }
        close $fh;
    }
    return \%kv;
}

# The whole file, or '' when there is no file to read. A file that exists and is
# empty reads as undef, exactly as the hand-written slurps it replaces did.
sub _slurp_or_empty {
    my ($path) = @_;
    my $content = '';
    if ( -f $path and open my $fh, '<:utf8', $path ) {
        $content = do { local $/; <$fh> };
        close $fh;
    }
    return $content;
}

sub action_plugin_read {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ( $plugin_id, $script ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $desc = _describe($full_script)
        or return { ok => 0, error => 'Cannot describe plugin' };

    my $config_file = $desc->{config_file} // '';
    my %values;

    if ($config_file) {
        my $kv = _read_kv_lines("$DOCROOT/$config_file");
        for my $k ( keys %$kv ) {
            $values{$k} = $kv->{$k} if defined $kv->{$k};
        }
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $kv   = _read_kv_lines( _lz() . "/lazysite.conf" );
        for my $k ( keys %$kv ) {
            $values{$k} = $kv->{$k} if $want{$k};
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

    my $desc = _describe($full_script)
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
        my $content     = _slurp_or_empty($plugin_conf);

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
        my %want      = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = _lz() . "/lazysite.conf";
        my $content   = _slurp_or_empty($conf_path);

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

    my $desc = _describe($full_script)
        or return { ok => 0, error => 'Cannot describe plugin' };

    # SM409: a contract plugin that is not enabled executes nothing.
    if ( my $refused = _gate_execution( $script, $desc ) ) { return $refused }

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

# SM598: undef is an ANSWER here, and the callers must hear it.
#
# _lz is Lazysite::Paths::lazysite_dir($DOCROOT), which returns undef for an
# undefined or empty docroot - a deliberate guard. This concatenated it anyway,
# so the result was "/forms/handlers.conf": an absolute path at the FILESYSTEM
# ROOT rather than anywhere inside a site. It surfaced as a Perl warning in the
# 0.10.33 release run ("uninitialized value in concatenation"), and the tests
# passed either way because nothing exists at that path, so the read found
# nothing and the code around it treated that as "no handlers" - the wrong
# answer, arriving indistinguishably from the right one.
#
# The WRITER is the sharper half: it does make_path(dirname($path)), which with
# no docroot is an attempt to create /forms at the root of the filesystem. It
# fails for want of permission on any sane host, which is luck rather than
# design.
sub _handlers_conf_path {
    my $lz = _lz();
    return undef unless defined $lz && length $lz;
    return "$lz/forms/handlers.conf";
}

sub _parse_handlers_conf {
    my $path = _handlers_conf_path();

    # SM598: no docroot is not "no handlers". Both return an empty list, and one
    # of them is a fault - so the fault says so once, in the log, rather than
    # being read as an ordinary empty site.
    unless ( defined $path ) {
        log_event( 'WARN', 'handlers', 'no docroot: cannot locate handlers.conf' );
        return [];
    }
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

    # SM598: refuse rather than write. Without a docroot this used to
    # make_path("/forms") and then write handlers.conf at the filesystem root -
    # a config file, outside every site, in a place nothing would ever read it
    # back from.
    unless ( defined $path ) {
        log_event( 'ERROR', 'handlers', 'no docroot: refusing to write handlers.conf' );
        return 0;
    }

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

    my ($wok) = write_file_checked( $path, $content );
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
    my $dir      = _lz() . "/forms";
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
    for my $k ( qw(type name enabled from to subject_prefix path url format
        method sendmail_path host port tls auth username password_file) ) {
        $new{$k} = $data->{$k} if defined $data->{$k} && length $data->{$k};
    }
    $new{type} //= 'file';

    # Replace existing or append
    my $found = 0;
    for my $h (@$handlers) {
        if ( $h->{id} eq $id ) {
            %$h    = %new;
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

    _write_handlers_conf( \@filtered )
        or return { ok => 0, error => "Cannot write handlers.conf" };

    return { ok => 1, deleted => $id };
}

sub action_form_targets_read {
    my ($form_name) = @_;
    $form_name //= '';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid form name" } unless $form_name;

    my $path = _lz() . "/forms/$form_name.conf";
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

    my $path = _lz() . "/forms/$form_name.conf";
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
# SM268 H1: the directories that legitimately hold submission stores - the
# default, plus the `path` of every configured file-target handler. Normalised
# and reserved-area-checked, so an operator cannot point a handler at
# lazysite/auth and turn this back into an arbitrary reader.
# SM422: PUBLIC, because it is now a shared definition rather than this
# module's private business. Common::carveout_refusal consults it so the read
# gate and the control API's form-submissions route agree about what a
# submission store IS - and a cross-package reach into a private sub is
# exactly what "use published APIs" exists to stop.
sub submission_store_dirs {
    my %dirs = ( 'lazysite/forms/submissions' => 1 );
    my $list = eval { _parse_handlers_conf() } || [];
    for my $h (@$list) {
        next unless ref $h eq 'HASH';
        next unless ( $h->{type} // 'file' ) eq 'file';
        my $p = $h->{path};
        next unless defined $p && length $p;
        $p =~ s{^/+|/+$}{}g;
        next unless length $p;
        next if $p =~ m{(?:^|/)\.\.(?:/|$)};
        # A handler pointed at an engine-owned area is a misconfiguration, and
        # honouring it here would reintroduce the very read this fix closes.
        next if Lazysite::Manager::Common::path_is_reserved($p)
            && $p !~ m{\Alazysite/forms(?:/|\z)};
        $dirs{$p} = 1;
    }
    return keys %dirs;
}

sub _submissions_path {
    my ($file) = @_;
    ( my $rel = $file // '' ) =~ s{^/+}{};
    return ( undef, undef, 'Invalid submissions file' )
        unless $rel =~ /\.jsonl\z/ && $rel !~ m{(?:^|/)\.\.(?:/|$)};

    # SM268 H1: confine to the submission stores. This checked only "ends in
    # .jsonl, no .., inside the docroot" - so a token holding the LEAST
    # PRIVILEGE read capability (read_submissions, documented as "a read that
    # does not allow editing forms or handlers") could read ANY .jsonl under the
    # docroot. Reproduced: lazysite/auth/sessions.jsonl, which is the session
    # registry - operator usernames, their source IPs, User-Agents and session
    # ids - and another domain's leads file. The blocklist was never consulted
    # and the action is absent from %SCOPED_ACTION, so neither the reserved-area
    # guard nor dav_scope applied.
    #
    # The store directory is sysop-configurable (the file handler's `path`,
    # default lazysite/forms/submissions), so this admits the configured
    # directories rather than one hard-coded string - anything else would break
    # a site that moved its store. A file OUTSIDE every configured store is
    # refused whatever its extension.
    my %allowed = map { $_ => 1 } submission_store_dirs();
    my $dir     = $rel;
    $dir =~ s{/[^/]+\z}{};
    return ( undef, undef, 'Invalid submissions file' )
        unless length $dir && $allowed{$dir};

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
        +{ _id => _submission_row_id($raw),
            map {
                $_ => ( !defined $r->{$_} ? ''
                    : ref $r->{$_} ? encode_json( $r->{$_} )
                    :                "$r->{$_}" )
            } @cols
        }
    } 0 .. $#rows;

    return {
        ok        => 1,
        file      => $rel,
        columns   => \@cols,
        rows      => \@out,
        total     => ( $total || 0 ),
        shown     => scalar(@out),
        truncated => ( $total > $CAP ? 1 : 0 ),
        malformed => ( $malformed || 0 ),
    };
}

# SM187: delete ONE handled submission row from a store, identified by the stable
# _id (raw-line hash) that action_form_submissions returns. Rewrites the .jsonl
# without the matched line, atomically (temp + rename). manage_forms-gated +
# audited by the dispatch wrapper. Returns { ok, deleted } or { ok=>0, error }.
# TL-20: the one atomic replacement the three submission editors share. Write
# the surviving lines to a sibling temp file and rename it over the store, so a
# concurrent reader sees the whole old file or the whole new one and never a
# half-written store. On a failure the temp file is removed, leaving the store
# as it was. Returns undef on success, or the caller's own error hash.
sub _rewrite_store {
    my ( $abs, $keep ) = @_;
    my $tmp = "$abs.tmp.$$";
    open my $out, '>:utf8', $tmp
        or return { ok => 0, error => 'Cannot write submissions' };
    print {$out} @$keep;
    close $out;
    rename $tmp, $abs
        or do { unlink $tmp; return { ok => 0, error => 'Cannot replace submissions' } };
    return undef;
}

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

    if ( my $e = _rewrite_store( $abs, \@keep ) ) { return $e }
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

    if ( my $e = _rewrite_store( $abs, \@out ) ) { return $e }
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

    if ( my $e = _rewrite_store( $abs, \@keep ) ) { return $e }
    return { ok => 1, file => $rel, deleted => $deleted };
}

# SM632: the inverse of bind_form.
#
# `bind_form` writes lazysite/forms/<name>.conf and there was NO inverse on any
# token surface: not in the action registry, and delete_file refuses the path
# because lazysite/ is internal (correctly). So a capability a token may hold
# created an object no capability a token may hold could destroy, and
# registrations accumulated with nothing able to prune them - form-list counts a
# bound form with no store as a real form. That is the same create-without-delete
# asymmetry SM578 closed for site packages, on a different object.
#
# WHAT IT DELETES AND WHAT IT WILL NOT. The registration only. A form with
# STORED SUBMISSIONS is refused, because those are personal data and deleting
# their registration would orphan them - present on disk, absent from every
# listing, which is worse than leaving the form. Removing submissions is
# form-submission-delete, kept interactive on purpose (SM214: a human confirms a
# destructive operation on personal data, often on the only copy). An empty
# store is not a reason to refuse: there is nothing to orphan.
#
# Confirmation names the form, like data-table-drop. A destructive verb that
# takes only an id is one an agent fires by having the wrong id.
sub action_form_delete {
    my ( $name, $confirm ) = @_;

    return { ok => 0, error => 'form name required', kind => 'invalid' }
        unless defined $name && length $name;
    return { ok => 0, error => "invalid name '$name'", kind => 'invalid-path' }
        unless $name =~ /\A[A-Za-z0-9_-]+\z/;
    return { ok => 0, error => 'refusing to delete a reserved config',
        kind => 'invalid' }
        if $name eq 'handlers' || $name eq 'smtp';

    my $conf = _lz() . "/forms/$name.conf";
    return { ok => 0, kind => 'no_such_form',
        error => "no form '$name' is registered" }
        unless -f $conf;

    # The row count comes from the SAME reader the listing uses, so a form that
    # looks empty in form-list cannot be refused here, or look full there and be
    # deleted here. Two counters for one question is how the halves disagree.
    my $listing = action_form_list();
    my ($rec)   = grep { $_->{name} eq $name } @{ $listing->{forms} || [] };
    my $rows    = $rec ? ( $rec->{row_count} // 0 ) : 0;
    if ( $rows > 0 ) {
        return { ok => 0, kind => 'has_submissions', rows => $rows,
            error => "'$name' has $rows stored submission"
                . ( $rows == 1 ? '' : 's' )
                . '. Deleting the registration would leave them on disk and out '
                . 'of every listing. Remove them in the manager first '
                . '(submission deletion is interactive by design), then delete '
                . 'the form.' };
    }

    unless ( defined $confirm && $confirm eq $name ) {
        return { ok => 0, kind => 'confirm', field => 'confirm',
            error => "Confirm by naming it exactly: {\"form\":\"$name\","
                . "\"confirm\":\"$name\"}" };
    }

    unlink $conf
        or return { ok => 0, error => "cannot remove the form config: $!" };
    log_event( 'INFO', $name, 'form registration deleted' );
    return { ok => 1, form => $name, removed => "lazysite/forms/$name.conf" };
}

1;
