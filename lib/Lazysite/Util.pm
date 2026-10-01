package Lazysite::Util;

# Shared helpers for the modular lazysite scripts (auth, dav, manager-api, the
# users tool). The processor stays self-contained and does NOT use this module -
# see docs/feature-requests/archive/SM079-modular-refactor.md.
#
# Each script sets $Lazysite::Util::COMPONENT after `use`, so log lines are
# attributed to the right component.

use strict;
use warnings;
use Lazysite::Paths ();
use POSIX           ();
use Socket          qw(inet_pton inet_ntop AF_INET AF_INET6);
use Exporter 'import';

our @EXPORT_OK = qw(log_event const_eq unlink_host_copies unlink_host_page clear_host_cache forward_line service_enabled secure_write_perms drop_to_tree_owner target_identity cannot_read backup_retention interpolate_env env_allowlist request_host request_address trusted_proxy_spec parse_trusted_proxies);

our $COMPONENT = 'lazysite';

# SM215: make a just-written file owner/group/mode-safe so a helper run under sudo
# (as root) never leaves a file the web-server (www-data) CGI cannot access. The
# parent directory is provisioned <site-user>:<web-group> (and is setgid), so we
# INHERIT owner+group from it rather than hard-code www-data: as root, chown both
# (only root can); unprivileged, set the group only (best-effort - a non-root CLI
# is normally already the file's owner, and chown-to-another-user would just fail).
# Call on the temp file BEFORE rename (same directory), or on the final path. Mode
# is applied explicitly. Best-effort throughout: never dies on a chown/chmod fail.
# SM766 (SM760's lesson, made a rule): A STORE READER NEVER TURNS AN
# UNOPENABLE FILE INTO AN EMPTY ANSWER IN SILENCE. `open ... or return {}`
# on a file that EXISTS turned a permissions fault into "this account holds
# nothing" for the runtime and a dead process for Status; both were read as
# facts about the site. Every read-open in the auth and daemon stores now
# goes through this on failure: it WARNs with the file, the error and the
# unix user - unless the file simply is not there (ENOENT), which is the
# ordinary empty case and not a fault - and returns undef so the caller's
# `// <empty>` keeps its shape. t/lint/121 holds that no read-open in those
# modules returns in silence.
# SM753: THE ONE READER of `backup_retention`. Three parsers read this key
# with two defaults - the manager kept 10, the installer and the theme store
# kept 3, the docs said 3 - so a sysop who never set it kept ten manual
# backups, read that they kept three, and the theme store kept three. The
# release manager's ruling (2026-09-07): 3, one reader, settable on the Site
# config page. `0` means unlimited; anything that is not a whole number
# reads as the default and is said in the log, not died on.
our $BACKUP_RETENTION_DEFAULT = 3;
sub backup_retention {
    my ($lazysite_dir) = @_;
    my $conf = "$lazysite_dir/lazysite.conf";
    return $BACKUP_RETENTION_DEFAULT unless defined $lazysite_dir && -f $conf;
    open my $fh, '<:utf8', $conf or return $BACKUP_RETENTION_DEFAULT;
    my $val = $BACKUP_RETENTION_DEFAULT;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^backup_retention\s*:\s*(.*?)\s*$/;
        my $v = $1;
        # SM782: an EMPTY value is the default, silently - it is how the
        # field ships and what clearing it through the API writes.
        if    ( !length $v )      { $val = $BACKUP_RETENTION_DEFAULT }
        elsif ( $v =~ /\A\d+\z/ ) { $val = $v + 0 }
        else { log_event( 'WARN', 'config', 'backup_retention is not a whole number; using the default', value => $v, default => $BACKUP_RETENTION_DEFAULT ) }
        last;
    }
    close $fh;
    return $val;
}

sub cannot_read {
    my ( $what, $path ) = @_;
    return undef if $!{ENOENT};
    # SM768: read $! BEFORE getpwuid, which is free to reset it - the first
    # version logged `error=` blank, which is the one field the rule exists
    # to carry.
    my $err = "$!";
    my ($who) = getpwuid($>);
    log_event( 'WARN', 'store', "cannot read $what - it exists and this process cannot open it",
        file => $path, error => $err, unix_user => ( $who // $> ) );
    return undef;
}

sub secure_write_perms {
    my ( $path, $mode ) = @_;
    return unless defined $path && length $path;
    chmod $mode, $path if defined $mode;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    my @ds = stat $dir or return;
    my ( $duid, $dgid ) = @ds[ 4, 5 ];
    if ( $> == 0 ) { chown $duid, $dgid, $path }    # root: match the provisioned dir
    else           { chown -1, $dgid, $path }       # non-root: group only, best-effort
    return;
}

# SM619: BECOME the owner of the site tree before writing into it.
#
# The rule this enforces is not new - lazysite-check.pl states it as SM139:
# "lazysite never writes into a site tree as root, because root-owned files
# there are exactly what stops the manager working afterwards". It was enforced
# in exactly one probe. A fleet sweep after the 0.11.0 upgrade found 31 sites
# with 16 identical failures each, every one traceable to a tree owned root:root
# - and one root-run command explains a whole tree, because lazysite/auth is
# setgid (02770): once ITS group is root, everything created beneath it
# afterwards inherits group root, including writes by callers that are
# themselves careful.
#
# secure_write_perms (SM215) is the per-FILE remedy and cannot reach this case:
# it inherits owner and group from the parent directory, so when the parent is
# the thing make_path() just created as root, it faithfully inherits root.
#
# WHOSE identity: the docroot's, read per call. One host serves many sites owned
# by different users, so this is never a constant - it is whatever owns the tree
# being written to, resolved fresh each time.
#
# Returns a hashref: { dropped => 0|1, user, group, why }. NEVER dies - the
# caller decides whether a refusal to drop is fatal, because that answer differs
# between a tool that writes (fatal) and one that only reads (harmless).
# The DECISION half, split out so it can be tested without being root: given a
# tree and an optional --as-user, who should this process become? Returns
# ( uid, gid ) or ( undef, why ). A test can point it at any real directory,
# including a genuinely root-owned one like '/', which is how the refusal path
# gets exercised at all - the alternative was a fake-root environment variable
# inside a privilege-dropping function, which is a worse thing to own.
sub target_identity {
    my ( $docroot, %opt ) = @_;
    my ( $uid, $gid );
    if ( defined $opt{as_user} && length $opt{as_user} ) {
        my @pw = getpwnam $opt{as_user}
            or return ( undef, "no such user '$opt{as_user}'" );
        ( $uid, $gid ) = @pw[ 2, 3 ];
        # An explicit --as-user names the OWNER; the tree still decides the
        # group, so a file lands in the web group the site is provisioned with
        # rather than the user's private group.
        my @ds = stat $docroot;
        $gid = $ds[5] if @ds && $ds[5] != 0;
    }
    else {
        my @ds = stat $docroot
            or return ( undef, "cannot stat '$docroot'" );
        ( $uid, $gid ) = @ds[ 4, 5 ];
        # A root-owned tree cannot say who it belongs to. Guessing here is how
        # the damage spread in the first place, so say so and let the caller
        # refuse - the repair (lazysite-check --fix, as root) is a different
        # tool with a different job.
        return ( undef,
            "the tree at '$docroot' is owned by root, so it cannot say "
                . 'which user to become - repair ownership first '
                . '(lazysite-check.pl --docroot ... --fix, as root), '
                . 'or name the owner with --as-user' )
            if $uid == 0;
    }

    return ( $uid, $gid );
}

sub drop_to_tree_owner {
    my ( $docroot, %opt ) = @_;
    return { dropped => 0, why => 'not running as root' } if $> != 0;

    my ( $uid, $gid ) = target_identity( $docroot, %opt );
    return { dropped => 0, why => $gid } unless defined $uid;

    # ORDER MATTERS AND IS NOT RECOVERABLE. The group must be set while still
    # root: once the UID is dropped the process can no longer change its GID, so
    # a UID-first version would strand the process in root's group with no way
    # back and no error to say so.
    $) = "$gid $gid";    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $( = $gid;           ## no critic (Variables::RequireLocalizedPunctuationVars)
    $> = $uid;           ## no critic (Variables::RequireLocalizedPunctuationVars)
    $< = $uid;           ## no critic (Variables::RequireLocalizedPunctuationVars)

    # Perl does not die when one of those assignments fails, so VERIFY rather
    # than assume. Both real and effective are checked: dropping only the
    # effective ids would leave the privilege reachable again through $> = 0.
    if ( $> != $uid || $< != $uid || $) + 0 != $gid || $( + 0 != $gid ) {
        return {
            dropped => 0,
            why     => "could not drop to uid $uid gid $gid "
                . "(now euid=$>, uid=$<, egid=" . ( $) + 0 ) . ", gid=" . ( $( + 0 ) . ')'
        };
    }

    # 0002, so a new file is group-writable and a new directory group-writable
    # and traversable - what the CGI needs, and what the deploy sets by hand.
    umask 0002;

    return {
        dropped => 1,
        user    => scalar( ( getpwuid $uid )[0] ) // $uid,
        group   => scalar( ( getgrgid $gid )[0] ) // $gid,
    };
}

# Constant-time string compare for timing-safe credential/token checks.
sub const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord( substr( $a, $_, 1 ) ) ^ ord( substr( $b, $_, 1 ) )
        for 0 .. length($a) - 1;
    return $r == 0;
}

# --- ${CGI_VAR} interpolation in a lazysite.conf value (SM926) ----------------
#
# `site_url` routinely holds `${REQUEST_SCHEME}://${SERVER_NAME}` - it is what
# install.pl and TestHelper write, so that one config works on any domain - and
# that value MEANS NOTHING until somebody expands it.
#
# THREE PIECES OF THE ENGINE READ THAT KEY AND ONLY TWO EXPANDED IT. The processor
# has an allowlist; tools/lazysite-users.pl hand-rolls two of the same variables
# with a comment explaining why it must; Lazysite::Notify had a seven-line reader
# that returned the raw line - so the first XMPP notification to arrive on a live
# site carried the URL `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins`. The
# third hand-rolled copy is how that happened, and a fourth would be the same
# mistake with a different symptom, so this is the one home for it.
#
# THE PROCESSOR KEEPS ITS OWN COPY, deliberately: the render path is module-free
# (ADR 0001) and cannot require this. t/lint/202 pins the two allowlists
# identical, which is the same arrangement lint 198 makes for `_cannot_read`.
#
# HTTP_HOST IS EXCLUDED, and the reason it is excluded deserves reading before
# anyone relies on it - see the note in t/lint/202. It is request-supplied; so,
# on a default Apache (`UseCanonicalName Off`, which none of the shipped vhost
# examples override), is SERVER_NAME. Excluding one and permitting the other is
# not the guarantee the processor's comment believes it is. Recorded in SM926
# rather than changed here, because the fix is a vhost or a policy decision.
my %ENV_ALLOWLIST = map { $_ => 1 } qw(
    SERVER_NAME SERVER_PORT REQUEST_SCHEME HTTPS
    REQUEST_URI REDIRECT_URL
    DOCUMENT_ROOT SERVER_ADMIN
);

# Named, not returned straight from sort: `return sort ...` is undefined in scalar
# context, and a caller asking "how many variables may be interpolated?" is a
# reasonable thing to write. Same reasoning as _registration_groups in
# tools/lazysite-users.pl, and perlcritic refuses it at severity 5.
sub env_allowlist {
    my @names = sort keys %ENV_ALLOWLIST;
    return @names;
}

# SM926, RULED 2026-10-01: THE PRESENTED HOST IS THE HOST.
#
# One definition of "the host this request is for", shared by everything that
# needs one. There were two: lazysite-processor.pl's `_request_host` read
# HTTP_HOST to choose an alias host's config, and interpolation read whatever
# $ENV{SERVER_NAME} happened to hold - which under Apache's `UseCanonicalName`
# default of Off is the Host header, and under On is the configured ServerName.
# So a page and a notification could disagree about what host the site is on,
# conditional on a vhost setting none of the four shipped examples sets.
#
# The ruling settles it as a division of responsibility rather than a trust level:
# the engine uses the hostname it was given, and restricting what may be presented
# is the front end's job. A site that wants it fixed pins it - a literal
# `site_url` has no ${...} to expand and is left alone.
#
# VALIDATION IS NOT TRUST, it is hygiene: the host reaches filenames (the per-host
# page cache) and URLs, so only a DNS-shaped name of sane length is accepted and
# anything else reads as absent. That is the same validation the processor's copy
# has always done, and t/lint/203 pins the two identical.
sub request_host {
    my $host = lc( $ENV{HTTP_HOST} // q{} );
    $host =~ s/:\d+\z//;    # strip port
    $host =~ s/\.\z//;      # trailing dot (FQDN form)
    return q{} if length $host > 253;
    return q{}
        unless $host =~ /\A [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )?
                         (?: \. [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )? )* \z/x;
    return $host;
}

# SM929, RULED 2026-10-01: ONE DEFINITION OF THE REQUEST ADDRESS, AND ITS TRUST
# BASIS IS A NAMED LIST THAT DEFAULTS TO THE PRIVATE RANGES.
#
# Everything that asks "who is this request from" asked it differently. Forty-four
# reads across nine files: ten drove a DECISION (the login and form rate limits,
# the bad-URL auto-blocker, the DAV rate gate) and thirty-three went on the RECORD
# (`_ip` on a submission, the audit trail's actor column, the notification email,
# the daily visitor hash). Behind a front proxy every one of them saw the PROXY -
# one constant for every visitor a site will ever have, which is how SM929 was
# found: nine stored enquiries from six unrelated campaigns, all recording
# 10.2.30.177. A rate limit keyed on a constant is one bucket for the world, and
# the auto-blocker, whose threshold is ten bad URLs in an hour, blocks that
# constant - which is every visitor to the site.
#
# AND THE ONE READER THAT DID CONSULT THE FORWARDED HEADER TRUSTED IT BLINDLY.
# `client_ip` in the render path took the FIRST hop whenever the header was
# present. MEASURED ON A LIVE SITE 2026-10-01: an ordinary request rendered this
# caller's real public address, and the same request with
# `X-Forwarded-For: 203.0.113.7` rendered 203.0.113.7. A visitor chose what the
# engine believed, so unifying REMOVES an untrusted read as well as adding a
# trusted one.
#
# WHY THE RIGHTMOST HOP AND NOT THE FIRST. The filing asked for the first address,
# which is right for a proxy that REPLACES the header and wrong for one that
# APPENDS: a caller-supplied value then arrives AHEAD of the true one, which is
# exactly what that measurement shows. Walking from the right, every hop a trusted
# peer contributed is itself trusted, so the first address that is NOT trusted is
# the furthest one attributable to a peer we trust. A hop we cannot parse ENDS the
# walk rather than being skipped: skipping it would step further left, into the
# part of the chain the caller controls.
#
# THE TRUST BASIS IS THE PEER, WHICH NO CLIENT CAN SET. That is what makes this
# different in kind from the SM794 header-trust shape: REMOTE_ADDR comes from the
# server's own accept(), so there is no sentinel to forge and nothing for the trust
# source to clear. `auth_proxy_trusted` was considered and is NOT reused - it is a
# boolean about X-Remote-* AUTH headers with no hop check at all (SM794), so making
# it mean "and also believe this address" would overload one switch with two
# unrelated trust decisions.
sub _trusted_proxy_default {
    # A SUB, NOT A PACKAGE ARRAY: in the processor a file-scoped `our` below the
    # main body is EMPTY when a request is served (t/lint/39 names exactly this),
    # which would have left the render path trusting nothing and silently reading
    # the peer. A sub is initialised at call time and cannot be too early.
    return ( '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' );
}

# The raw `trusted_proxies` line, or undef when the key is absent - which is NOT
# the same as empty. Four states, and they differ:
#   absent        -> undef -> the RFC1918 default above
#   empty         -> ''    -> trust nothing (clearing the field is a decision)
#   `none`        -> ''    -> trust nothing, said out loud
#   a list        -> that list, and only that
sub trusted_proxy_spec {
    my ($lazysite_dir) = @_;
    # Defined FIRST: form-handler.pl's $LAZYSITE_DIR is undef when the handler
    # library is missing, and interpolating it to build the path would warn.
    return undef unless defined $lazysite_dir && length $lazysite_dir;
    my $conf = "$lazysite_dir/lazysite.conf";
    return undef unless -f $conf;
    open my $fh, '<:utf8', $conf or return undef;
    my $spec;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^trusted_proxies\s*:\s*(.*?)\s*$/;
        $spec = $1;
        last;
    }
    close $fh;
    return $spec;
}

# ($set, $rejected) - the parsed trust set, and every word that is not an address
# or range. PURE, and silent by design: the processor carries a pinned copy of this
# (ADR 0001) and a copy that logged would drift from one that could not. The
# REPORTING lives where an operator looks - tools/lazysite-check.pl names a rejected
# entry, because a trust list with a typo in it is a declaration the code ignores.
sub parse_trusted_proxies {
    my ($spec) = @_;
    $spec = '' unless defined $spec;
    $spec =~ s/\A\s+//;
    $spec =~ s/\s+\z//;
    my @words;
    # ABSENT AND EMPTY ARE THE SAME ANSWER, deliberately, and `none` is how an
    # operator says no. The Config page ships this field EMPTY and pressing Save
    # writes an empty value - SM782 names the same shape for backup_retention - so
    # reading empty as "trust nothing" would turn the feature off for any site
    # whose operator merely saved the page, silently, and put the proxy's address
    # back on every submission.
    if    ( !length $spec )       { @words = _trusted_proxy_default() }
    elsif ( lc($spec) eq 'none' ) { return ( [], [] ) }
    else                          { @words = split /[\s,]+/, $spec }
    my ( @set, @rejected );
    for my $w (@words) {
        my ( $addr, $bits ) = split m{/}, $w, 2;
        my $packed = _packed_address( $addr // '' );
        if ( !length $packed ) { push @rejected, $w; next }
        my $width = length($packed) * 8;
        $bits = $width if !defined $bits || !length $bits;
        # A zero-length prefix would match every peer, which makes the trust check
        # vacuous - the fault this whole change exists to remove. Refused, not
        # honoured: an operator who means that can name the ranges.
        if ( $bits !~ /\A[0-9]+\z/ || $bits + 0 > $width || $bits + 0 == 0 ) {
            push @rejected, $w;
            next;
        }
        push @set, [ $packed, $bits + 0 ];
    }
    return ( \@set, \@rejected );
}

# The address as bytes, or '' when it is not one. '' rather than undef so a caller
# tests `length` in any context - a bare `return` in list context is the trap
# feedback_bare_return_list_context names.
sub _packed_address {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    return '' if $text =~ /[^0-9A-Fa-f:.]/;
    my $family = ( index( $text, ':' ) >= 0 ) ? AF_INET6 : AF_INET;
    my $packed = eval { inet_pton( $family, $text ) };
    return ( defined $packed && length $packed ) ? $packed : '';
}

# One address, one spelling - the same reasoning as lowercasing the request host.
sub _text_address {
    my ($packed) = @_;
    my $family   = length($packed) == 4 ? AF_INET : AF_INET6;
    my $text     = eval { inet_ntop( $family, $packed ) };
    return defined $text ? $text : '';
}

sub _address_in_set {
    my ( $packed, $set ) = @_;
    return 0 unless defined $packed && length $packed;
    for my $entry ( @{$set} ) {
        my ( $net, $bits ) = @{$entry};
        # Same family only: an IPv4 range never contains an IPv6 address, and
        # comparing their bytes would say otherwise.
        next unless length($net) == length($packed);
        my $whole = int( $bits / 8 );
        my $rest  = $bits % 8;
        next if $whole && substr( $packed, 0, $whole ) ne substr( $net, 0, $whole );
        if ($rest) {
            my $mask = 0xFF & ( 0xFF << ( 8 - $rest ) );
            next
                if ( ord( substr $packed, $whole, 1 ) & $mask )
                != ( ord( substr $net, $whole, 1 ) & $mask );
        }
        return 1;
    }
    return 0;
}

# THE one answer to "who is this request from". Give it the `trusted_proxies` spec
# (trusted_proxy_spec() reads it; the processor passes its own parsed value).
#
# With no forwarded header this returns exactly what every caller read before -
# REMOTE_ADDR, verbatim, not canonicalised - so a directly-served site is
# unaffected and that property is worth keeping rather than tidying.
sub request_address {
    my ($spec) = @_;
    my $peer   = $ENV{REMOTE_ADDR} // '';
    my ($set)  = parse_trusted_proxies($spec);
    return $peer unless @{$set};
    return $peer unless _address_in_set( _packed_address($peer), $set );
    my @chain = split /,/, ( $ENV{HTTP_X_FORWARDED_FOR} // '' );
    for my $hop ( reverse @chain ) {
        $hop =~ s/\A\s+//;
        $hop =~ s/\s+\z//;
        my $packed = _packed_address($hop);
        return $peer                  unless length $packed;
        return _text_address($packed) unless _address_in_set( $packed, $set );
    }
    return $peer;
}

# The value an allowlisted ${VAR} expands to. Only SERVER_NAME is special, and it
# is the whole of SM926's build: it resolves to the host PRESENTED, falling back to
# $ENV{SERVER_NAME} when there is no usable Host header - a CLI run, or a client
# that sent something that is not a hostname. Everything else is read from %ENV as
# before.
sub _env_value {
    my ($name) = @_;
    return $name eq 'SERVER_NAME'
        ? ( request_host() || $ENV{SERVER_NAME} )
        : $ENV{$name};
}

# Expand only allowlisted ${VAR}s. An allowlisted variable that is not SET
# expands to the empty string (the processor's behaviour, kept); one that is not
# allowlisted is left verbatim, so an unexpected placeholder stays visible rather
# than silently becoming ''.
sub interpolate_env {
    my ($val) = @_;
    return $val unless defined $val;
    $val =~ s{\$\{(\w+)\}}{
        $ENV_ALLOWLIST{$1} ? ( _env_value($1) // '' ) : "\${$1}"
    }ge;
    return $val;
}

# Did every ${VAR} in this value resolve to something? A cron- or CLI-driven
# caller has no CGI environment at all, so interpolate_env correctly returns
# `://` - and a caller building a LINK needs to know that rather than emit it.
# Notify uses this to fall back to a relative path.
sub env_interpolation_complete {
    my ($val) = @_;
    return 1 unless defined $val && $val =~ /\$\{/;
    while ( $val =~ /\$\{(\w+)\}/g ) {
        # SM926: through the SAME resolver interpolate_env uses, or this would
        # report `${SERVER_NAME}` as unresolvable on a request that has a Host
        # header and no SERVER_NAME - and Notify would then emit a relative path
        # on a site where the absolute one was perfectly available.
        return 0 unless $ENV_ALLOWLIST{$1} && length( _env_value($1) // '' );
    }
    return 1;
}

# Minimal JSON string escaper for the structured log format.
sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

# Levelled logging to STDERR (text or json), honouring LAZYSITE_LOG_LEVEL and
# LAZYSITE_LOG_FORMAT. Component comes from $COMPONENT. Emitted diagnostics are
# ALSO forwarded to syslog - at WARN and above unless forward_diagnostics says
# otherwise, SM932 (see below). STDERR alone is not a sink this code can verify.
sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts     = POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    no warnings 'uninitialized';    # helper subs in unit tests may pass undef
    my $line;
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        $line = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' ) . '}';
    }
    else {
        my $extras = join ' ', map { "$_=" . ( $extra{$_} // '' ) } keys %extra;
        my $ctx    = $context // '';
        $line = "[$ts] [$level] [$COMPONENT] [$ctx] $message";
        $line .= " $extras" if $extras;
    }
    print STDERR "$line\n";
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    forward_line( 'diag', $prio{$level} // 'info', $line );
    return;
}

# --- External log forwarding (the 'Logging & forwarding' plugin, log.pl) ----
#
# forward_audit / forward_diagnostics / syslog_facility in lazysite.conf control
# best-effort syslog copies of the two streams: audit-trail lines (the pipe
# format, at LOG_INFO) and log_event diagnostics (at their mapped priority).
# Config resolution rides the same path as log_level: an env override wins
# (LAZYSITE_FORWARD_AUDIT / LAZYSITE_FORWARD_DIAGNOSTICS /
# LAZYSITE_SYSLOG_FACILITY), else ONE cheap peek at lazysite.conf per process
# (located via $Lazysite::Audit::LAZYSITE_DIR, else DOCUMENT_ROOT); the result
# is cached, so a request pays at most one small-file read - and syslog is
# only opened when a stream is actually enabled. Sys::Syslog is core Perl.
#
# SM932, ruled 2026-09-30: DIAGNOSTICS FORWARDING IS ON BY DEFAULT, at WARN and
# above. Until this release log_event's only unconditional sink was
# `print STDERR`, and on a stack where a FastCGI child's STDERR does not reach
# the web server's error_log the engine had no reachable voice at all - an
# operator debugging a live site grepped error_log through four failing
# submissions and found nothing, while the same code from a terminal printed the
# cause at once. One unverifiable sink was the whole of it. A second sink does
# not make the first one work; it stops "nothing reached anybody" being the
# default outcome.
#
# The THRESHOLD is WARN rather than everything, and that is measured rather than
# preferred: cannot_read() logs at WARN, so WARN-and-above carries every repair
# the four-state work of 0.15.0 and 0.15.1 produced, while forwarding nothing
# new at INFO means no install's syslog volume changes on upgrade.
#
# forward_audit stays a boolean and stays OFF by default - it is a copy of an
# access record, not a diagnostic, and nobody has been unable to read it.
#
# Forwarding failure NEVER propagates: everything is eval-guarded, with a
# single WARN per process. Test seam (test-only): LAZYSITE_SYSLOG_DUMP=<file>
# appends "<priority> <line>" to that file instead of calling syslog, so tests
# can assert what would have been forwarded without a running syslogd.

my %FWD;                # cached forwarding config (per process)
my $fwd_warned;         # WARN once per process on forwarding TRANSPORT failure
my $fwd_conf_warned;    # WARN once per process on a bad/unreadable forwarding CONFIG
my $syslog_open;

sub _conf_bool {
    my $v = lc( $_[0] // '' );
    return $v =~ /^(?:1|on|yes|true|enabled)$/ ? 1 : 0;
}

# SM932: forward_diagnostics is a LEVEL, not a boolean, and absent means "WARN
# and above" rather than "off". Returns two values:
#   ( minimum rank to forward | undef to forward nothing, unrecognised value | undef )
#
#   absent              => 2   WARN and above - the default this release sets
#   off / 0 / no / false => undef, forward nothing
#   on / 1 / yes / true / all => 0, every level
#   a level name        => that rank (debug info warn|warning error|err)
#
# on/true meaning EVERY level is deliberate and is the backward-compatibility
# half of the change: an operator who switched forwarding on before this release
# asked for the whole stream and still gets exactly it, so no configured install
# changes behaviour. Only an install that never set the key moves, and it moves
# from nothing to WARN and above.
#
# An unrecognised value returns the default AND the offending value, so the
# caller can say so - a value the code silently ignores is the shape
# feedback_a_declaration_the_code_ignores exists to refuse.
sub _conf_diag_rank {
    my $v = lc( $_[0] // '' );
    $v =~ s/\A\s+//;
    $v =~ s/\s+\z//;
    return ( 2,     undef ) if $v eq '';
    return ( undef, undef ) if $v =~ /\A(?:0|off|no|false|disabled)\z/;
    return ( 0,     undef ) if $v =~ /\A(?:1|on|yes|true|enabled|all)\z/;
    my %rank = ( debug => 0, info => 1, warn => 2, warning => 2, error => 3, err => 3 );
    return ( $rank{$v}, undef ) if exists $rank{$v};
    return ( 2,         $v );
}

# The inverse of log_event's level -> syslog priority map, so forward_line can
# apply the diagnostics threshold to a line it only ever sees as a priority.
#
# An unknown priority ranks as err, not info: it is forwarded under every
# setting except "off". The point of this filing is diagnostics that went
# nowhere, so a line we cannot classify is one to pass on rather than drop.
my %SYSLOG_RANK = ( debug => 0, info => 1, warning => 2, err => 3 );

sub _syslog_rank { return $SYSLOG_RANK{ lc( $_[0] // '' ) } // 3 }

# SM932: reported only AFTER %FWD is fully built - never during. log_event calls
# forward_line calls _forward_conf, so warning mid-construction would forward
# against half-set values; by the time this runs $FWD{loaded} short-circuits the
# re-entry and every field has its value. Its own latch, separate from
# $fwd_warned, so a transport failure cannot suppress a config complaint.
sub _forward_conf_warn {
    my ( $message, $path, $detail ) = @_;
    return if $fwd_conf_warned++;
    log_event( 'WARN', 'forwarding', $message,
        file  => ( $path   // '' ),
        error => ( $detail // '' ) );
    return;
}

# Service killswitches (0.9.0): a network surface (MCP, OAuth, the control-API
# token path, token exchange) is OFF unless the operator explicitly enables it in
# lazysite.conf - the same posture WebDAV already has (webdav_enabled, default
# off). $docroot is DOCUMENT_ROOT (lazysite.conf is at $docroot/lazysite/). Absent
# / blank / false value => 0 (disabled). Cheap single-pass read; each surface
# calls this once at request entry.
sub service_enabled {
    my ( $docroot, $key ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $key && length $key;
    open my $fh, '<', Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" or return 0;
    my $val = '';
    while ( my $l = <$fh> ) {
        if ( $l =~ /^\Q$key\E\s*:\s*(\S+)/ ) { $val = $1; last }
    }
    close $fh;
    return _conf_bool($val);
}

sub _forward_conf {
    return \%FWD if $FWD{loaded};
    $FWD{loaded} = 1;
    my %want = (
        audit    => $ENV{LAZYSITE_FORWARD_AUDIT},
        diag     => $ENV{LAZYSITE_FORWARD_DIAGNOSTICS},
        facility => $ENV{LAZYSITE_SYSLOG_FACILITY},
    );
    my ( $conf_path, $conf_error );
    unless ( defined $want{audit} && defined $want{diag} && defined $want{facility} ) {
        my $dir =
            defined $Lazysite::Audit::LAZYSITE_DIR ? $Lazysite::Audit::LAZYSITE_DIR
            : defined $ENV{DOCUMENT_ROOT} ? Lazysite::Paths::lazysite_dir( $ENV{DOCUMENT_ROOT} )
            :                               undef;
        if ( defined $dir ) {
            $conf_path = "$dir/lazysite.conf";

            # SM932: this read decides whether the engine has a second sink, so
            # it may not fail in silence. It had no else branch at all, which is
            # the four-state defect SM917 swept out of the store readers - and
            # the one place it could not be fixed the same way, because
            # cannot_read() logs through log_event and log_event arrives here.
            # $! is captured immediately and reported at the end of the sub.
            if ( open my $fh, '<', $conf_path ) {    # not a store - site config
                while ( my $l = <$fh> ) {
                    $want{audit}    //= $1 if $l =~ /^forward_audit\s*:\s*(\S+)/;
                    $want{diag}     //= $1 if $l =~ /^forward_diagnostics\s*:\s*(\S+)/;
                    $want{facility} //= $1 if $l =~ /^syslog_facility\s*:\s*(\S+)/;
                }
                close $fh;
            }
            elsif ( !$!{ENOENT} ) {
                $conf_error = "$!";
            }
        }
    }
    $FWD{audit} = _conf_bool( $want{audit} );
    my ( $diag_rank, $diag_bad ) = _conf_diag_rank( $want{diag} );
    $FWD{diag} = $diag_rank;
    my $fac = lc( $want{facility} // 'daemon' );
    $fac = 'daemon' unless $fac =~ /^(?:daemon|local[0-7])$/;
    $FWD{facility} = $fac;

    # Both of these are reported through log_event, which re-enters this sub -
    # safe only because %FWD is complete and $FWD{loaded} is already 1. They
    # share one latch: an unreadable conf yields no value to be unrecognised, so
    # the two cannot both be true from the file, and one complaint is enough.
    _forward_conf_warn(
        'cannot read the log forwarding config - forwarding falls back to its defaults',
        $conf_path, $conf_error )
        if defined $conf_error;
    _forward_conf_warn(
        'unrecognised forward_diagnostics value - forwarding WARN and above instead',
        $conf_path, $diag_bad )
        if defined $diag_bad;
    return \%FWD;
}

sub _forward_warn {
    my ($err) = @_;
    $err = defined $err ? "$err" : '';
    $err =~ s/\s+$//;
    # Once per process; incremented BEFORE the nested log_event so its own
    # forward attempt cannot recurse back into a second warning.
    return if $fwd_warned++;
    log_event( 'WARN', 'forwarding', 'log forwarding failed', error => $err );
    return;
}

sub forward_line {
    my ( $stream, $priority, $line ) = @_;
    my $cfg = _forward_conf();

    # SM932: the audit stream stays a boolean; the diagnostics stream carries a
    # THRESHOLD, applied here rather than in log_event because four plugins
    # (audit, form-handler, form-smtp, payment-demo) carry their own log_event
    # copy and call straight into this sub. One gate, five callers.
    if ( $stream eq 'audit' ) {
        return unless $cfg->{audit};
    }
    else {
        return unless defined $cfg->{diag};
        return if _syslog_rank($priority) < $cfg->{diag};
    }
    if ( defined $ENV{LAZYSITE_SYSLOG_DUMP} && length $ENV{LAZYSITE_SYSLOG_DUMP} ) {
        my $ok = eval {
            open my $fh, '>>', $ENV{LAZYSITE_SYSLOG_DUMP} or die "$!\n";
            print {$fh} "$priority $line\n";
            close $fh;
            1;
        };
        _forward_warn("syslog dump: $@") unless $ok;
        return;
    }
    my $ok = eval {
        require Sys::Syslog;
        unless ($syslog_open) {
            Sys::Syslog::openlog( 'lazysite', 'ndelay,pid', $cfg->{facility} );
            $syslog_open = 1;
        }
        Sys::Syslog::syslog( $priority, '%s', $line );
        1;
    };
    _forward_warn($@) unless $ok;
    return;
}

# SM110 phase 2: the host-keyed page cache. An alias host's rendered pages
# live at lazysite/cache/hosts/<host>/<rel>.html (written by the processor,
# mirroring the page's docroot-relative path). Every surface that removes or
# overwrites a page's sibling .html cache must ALSO drop the per-host copies,
# or an alias host keeps serving the stale render after an edit.
#
# unlink_host_copies($docroot, $abs_html): given the SIBLING cache path
# ($docroot/<rel>.html), unlink <rel>.html under every host slot. Returns the
# number removed. Guards against traversal in the rel path (callers pass
# sysop/user-derived paths).
sub unlink_host_copies {
    my ( $docroot, $abs_html ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $abs_html;
    my $hosts = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts";
    return 0 unless -d $hosts;
    ( my $rel = $abs_html ) =~ s{^\Q$docroot\E/?}{};
    return 0 unless length $rel && $rel =~ /\.html\z/;
    return 0 if index( $rel, 'lazysite/' ) == 0;                # never a slot path itself
    return 0 if $rel =~ m{(?:^|/)\.\.(?:/|$)} || $rel =~ /\0/;  # no traversal
    my $n = 0;
    opendir my $dh, $hosts or return 0;
    for my $h ( readdir $dh ) {
        next if $h =~ /^\./;
        my $copy = "$hosts/$h/$rel";
        $n++ if -f $copy && unlink $copy;
    }
    closedir $dh;
    return $n;
}

# unlink_host_page($docroot, $host, $rel_html): remove ONE host's copy of a page
# (lazysite/cache/hosts/<host>/<rel>.html), so a per-host cache entry can be
# cleared surgically without touching the other language/domain siblings.
# Returns 1 if a file was removed. Host must be DNS-shaped; the rel path is
# traversal-guarded (callers pass operator/user-derived values).
sub unlink_host_page {
    my ( $docroot, $host, $rel ) = @_;
    return 0 unless defined $docroot && length $docroot;
    return 0 unless defined $host && $host =~ /\A[A-Za-z0-9.-]+\z/ && $host !~ /\.\./;
    ( my $r = ( $rel // '' ) ) =~ s{^/+}{};
    return 0 unless length $r && $r =~ /\.html\z/;
    return 0 if $r =~ m{(?:^|/)\.\.(?:/|$)} || $r =~ /\0/;
    my $copy = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts/$host/$r";
    return ( -f $copy && unlink $copy ) ? 1 : 0;
}

# clear_host_cache($docroot): remove the whole hosts tree. Used where a sweep
# already drops every sibling cache (clear-all, theme/layout activation, nav
# change, backup restore) - wholesale removal is the simple, always-correct
# choice there; everything regenerates on the next request per host.
sub clear_host_cache {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    my $hosts = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts";
    return 0 unless -d $hosts;
    require File::Path;
    File::Path::remove_tree( $hosts, { safe => 1 } );
    return 1;
}

1;
