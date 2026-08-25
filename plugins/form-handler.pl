#!/usr/bin/perl
# lazysite-form-handler.pl - form POST receiver, validation, dispatch
use strict;
use warnings;
use POSIX       qw(strftime);
use Digest::SHA qw(hmac_sha256_hex);
use Fcntl       qw(:flock O_RDWR O_CREAT);
use DB_File;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(encode_json decode_json);

my $LOG_COMPONENT = 'form-handler';

if ( grep { $_ eq '--describe' } @ARGV ) {
    print encode_json( {
            id            => 'form-handler',
            name          => 'Form Handler',
            description   => 'Receives and dispatches contact form submissions',
            version       => '1.1',
            config_file   => '',
            config_schema => [],
            handler_types => [
                {
                    type   => 'smtp',
                    label  => 'Send email (SMTP)',
                    schema => [
                        { key => 'name', label => 'Name', type => 'text', required => JSON::PP::true, default => 'Email delivery' },
                        { key => 'enabled', label => 'Enabled', type => 'boolean', default => 'true' },
                        { key => 'from', label => 'From address', type => 'email', required => JSON::PP::true, default => 'webforms@example.com' },
                        { key => 'to', label => 'To address', type => 'email', required => JSON::PP::true, default => 'admin@example.com' },
                        { key => 'subject_prefix', label => 'Subject prefix', type => 'text', default => '[Contact] ' },
                        { key => 'attach_files', label => 'Attach uploaded files', type => 'boolean', default => 'false',
                            note => 'When on, files uploaded with the form are attached to the email and listed (name + size) below the message. Off by default. Mind your mail server\'s attachment size limits.' },
                    ],
                    note => 'SMTP connection settings (host, port, TLS) are configured under the Email (SMTP) group header.',
                },
                {
                    type   => 'db',
                    label  => 'Store in a data table',
                    schema => [
                        { key => 'name', label => 'Name', type => 'text', required => JSON::PP::true, default => 'Store submissions' },
                        { key => 'enabled', label => 'Enabled', type => 'boolean', default => 'true' },
                        { key => 'table', label => 'Table', type => 'text', required => JSON::PP::true,
                            note => 'A table declared under Data tables. It must exist before submissions arrive.' },
                        { key => 'fields', label => 'Field mapping', type => 'text', required => JSON::PP::true,
                            default => 'name=name,email=email,message=message',
                            note => 'form field=column, comma separated. REQUIRED, and it is what keeps a visitor from choosing where their data goes: a form field nobody maps here is dropped, so a form gaining a field cannot start writing a column.' },
                    ],
                    note => 'Needs the Data tables plugin to be enabled. Values are checked against the table\'s declared types, so a submission that does not fit is refused rather than stored wrong - the visitor is told the submission failed instead of being thanked for a lost one.',
                },
                {
                    type   => 'file',
                    label  => 'Save to file',
                    schema => [
                        { key => 'name', label => 'Name', type => 'text', required => JSON::PP::true },
                        { key => 'enabled', label => 'Enabled', type => 'boolean', default => 'true' },
                        { key => 'path', label => 'Storage directory', type => 'text', default => 'lazysite/forms/submissions' },
                    ],
                },
                {
                    type   => 'webhook',
                    label  => 'Webhook',
                    schema => [
                        { key => 'name', label => 'Name', type => 'text', required => JSON::PP::true },
                        { key => 'enabled', label => 'Enabled', type => 'boolean', default => 'true' },
                        { key => 'url', label => 'Webhook URL', type => 'text', required => JSON::PP::true },
                        { key => 'format', label => 'Format', type => 'select', options => [ 'json', 'slack' ], default => 'json' },
                    ],
                },
            ],
            child_configs => {
                pattern    => 'lazysite/forms/*.conf',
                exclude    => [ 'smtp.conf', 'handlers.conf' ],
                label_from => 'filename',
            },
            actions => [],
    } );
    exit 0;
}

my $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $FORMS_DIR    = "$LAZYSITE_DIR/forms";
# SM415: where a native (no-JS) post redirects back to, captured after
# parse_post and consumed by respond_ok/respond_error at the bottom -
# declared here because the capture site precedes them in file order.
our ( $REDIRECT_PAGE, $REDIRECT_FORM ) = ( '', '' );

# Hard ceiling on a POST body, so a hostile upload can't exhaust memory before the
# per-form size limits are even checked. Generous; real limits are per-form.
my $MAX_POST_BYTES = 64 * 1024 * 1024;
# SM523: the underscore keys a CLIENT may send (see parse_post).
my %PROTOCOL_KEY = map { $_ => 1 } qw(_form _page _hp _ts _tk);

# --- Main ---

my $name = '';    # hoisted so the catch below can attribute a block to its form
eval {
    reject('Method not allowed')
        unless ( $ENV{REQUEST_METHOD} // '' ) eq 'POST';

    my %form = parse_post();
    $name = $form{_form} // '';
    $name =~ s/[^a-zA-Z0-9_-]//g;
    reject('Missing form name') unless $name;

    # SM415: capture where a native post goes back to, BEFORE any check can
    # die - the redirect answers refusals too. Validation is the whole guard
    # against an open redirect: same-site absolute path or nothing.
    {
        my $pg = $form{_page} // '';
        if ( $pg =~ m{\A/} && $pg !~ m{\A//} && $pg !~ /[\r\n]/ && length($pg) <= 500 ) {
            $REDIRECT_PAGE = $pg;
            $REDIRECT_FORM = $name;
        }
    }

    # SM402: this handler reads NO identity from the request, because it has no
    # way to verify one.
    #
    # It is not behind the auth wrapper - the shipped templates front only
    # lazysite-processor.pl and lazysite-manager-api.pl, and /cgi-bin/ is
    # otherwise a plain ScriptAlias - so the processor's trust-header stripping
    # never runs for it and HTTP_X_REMOTE_USER arrives exactly as the client
    # sent it. There is no configuration under which it could be trusted here:
    # `auth_proxy_trusted` is consulted by the processor, on the request the
    # processor handles, and this handler cannot tell a proxied identity from an
    # invented one.
    #
    # It used to be recorded twice. `_auth_user` on the submission was DEAD -
    # every delivery target skips _-prefixed keys, so it never reached a stored
    # record, an email or a webhook. The audit entry was not: an unverifiable
    # name went into the actor column of lazysite/logs/audit.log, the shared
    # trail every other surface writes to with an identity it HAS verified.
    # A forged name there is a false record in the one artefact whose whole
    # purpose is to say who did something.
    #
    # A public form submission has no verified actor, so it is recorded as
    # having none. The address is still logged, which is the fact that is
    # actually known.

    my $conf     = load_form_conf($name);
    my %handlers = load_handlers();

    check_honeypot( $form{_hp} // '' );
    check_timestamp( $form{_ts} // '', $form{_tk} // '', load_form_secret() );

    # SM425: a signed-in member is not the traffic the anonymous rate limit
    # exists to stop, and meeting it mid-form reads as the site being broken.
    # The session cookie is verified CRYPTOGRAPHICALLY (SM411's shared
    # verifier - HMAC over the payload, registry and account checks inside),
    # which is different in kind from the header identity SM402 rightly
    # stripped: nothing here reads X-Remote-User, and the verified name is
    # used as a BOOLEAN for this one decision - it is not recorded on the
    # submission, not written to the audit actor column, and not passed to
    # any handler. The submission stays actor-less; only the limiter learns
    # that SOME verified member is asking.
    # THE MODULE TREE HAS TO BE FOUND FIRST (the resolve_db lesson, SM473):
    # `prove -l` puts lib/ on @INC and a real install does not, so a bare
    # require here passes every test and dies on every deployed submission.
    # Same locate as the db target below - and the whole attempt degrades to
    # ANONYMOUS on any failure, because a broken exemption must cost a member
    # a rate limit, never anybody a form.
    my $signed_in = eval {
        unless ( $INC{'Lazysite/Auth/Session.pm'} ) {
            require Cwd;
            require File::Basename;
            my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
            for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
                if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
            }
        }
        # SM557: the package is require'd at runtime, so this file mentions the
        # variable once by design - t/lint/04 refuses the 'used only once' warning.
        no warnings 'once';
        require Lazysite::Auth::Session;
        local $Lazysite::Auth::Session::LAZYSITE_DIR = $LAZYSITE_DIR;
        my ($session) = Lazysite::Auth::Session::verify_session_cookie();
        ( ref $session eq 'HASH' ) ? 1 : 0;
    } // 0;
    if ($signed_in) {
        log_event( 'INFO', 'form', 'rate limit waived: verified session' );
    }
    else {
        check_rate_limit( $ENV{REMOTE_ADDR} // '0.0.0.0', $conf->{rate_limit} );
    }

    # Binary uploads: reject up front (before any handler runs) if the form does
    # not accept files, or a file breaks the form's size / type / count limits.
    if ( my $files = $form{_files} ) {
        reject_user('This form does not accept file uploads.') unless $conf->{upload};
        validate_uploads( $files, $conf->{upload} );
    }

    # Reject a contentless submission - every visible field blank and no file
    # uploaded. HTML5 `required` stops this in a browser, so it is almost always an
    # automated/blank POST; saving a "thank you" + an empty record is worse than an
    # honest error.
    my $has_content = ( $form{_files} && @{ $form{_files} } ) ? 1 : 0;
    unless ($has_content) {
        for my $k ( keys %form ) {
            next if $k =~ /^_/;
            if ( defined $form{$k} && $form{$k} =~ /\S/ ) { $has_content = 1; last }
        }
    }
    reject_user('Please fill in the form before submitting.') unless $has_content;

    # SM216: score the (valid) submission; a suspect one is STORED but flagged so
    # it stays out of the notification bell and lands under the Quarantine filter.
    my ( $quarantined, $spam_reason ) = _spam_assessment( \%form, $conf );
    if ($quarantined) {
        $form{_quarantined} = 1;
        $form{_spam_reason} = $spam_reason;
    }

    my $delivered = 0;
    for my $target ( @{ $conf->{targets} } ) {
        $delivered += ( dispatch( $target, \%form, \%handlers ) ? 1 : 0 );
    }

    # If NOTHING actually accepted the submission - every target disabled, unknown,
    # or failed (e.g. the form handler / its delivery plugin is turned off) - the
    # submission was NOT saved. Fail loudly instead of showing a false "thank you".
    unless ($delivered) {
        log_event( 'ERROR', $name, 'form not delivered - no active target',
            ip => $ENV{REMOTE_ADDR} // 'unknown' );
        reject_user( 'This form is not accepting submissions right now '
                . '(no active delivery target). Please contact the site owner.' );
    }

    log_event( 'INFO', $name, 'form received', ip => $ENV{REMOTE_ADDR} // 'unknown' );
    _audit_submission( $name, '', $ENV{REMOTE_ADDR} // '' );    # SM402: no verified actor
        # SM216: a quarantined (suspect) submission is stored but does NOT ring the
        # bell - the operator finds it under the Submissions Quarantine filter.
    _notify_submission($name) unless $form{_quarantined};    # SM113 badge
    _record_form_event( $name, $form{_quarantined} ? 'quarantined' : 'stored' ); # SM216-2
    respond_ok('Thank you - your message has been sent.');
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    log_event( 'ERROR', $name, 'processing failed', error => $err, ip => $ENV{REMOTE_ADDR} // 'unknown' );
    # SM216-2: an anti-spam control blocked this POST - count it (per form, by
    # reason) so the report shows "controls stopped N", not silence.
    if ( my $reason = _block_reason($err) ) { _record_form_event( $name, 'blocked', $reason ); }
    # USER: messages (e.g. upload too large / wrong type) are safe to show the
    # submitter; everything else gets a generic message.
    if ( $err =~ /^USER:(.*)/s ) { respond_error($1); }
    else { respond_error('An error occurred - please try again.'); }
}

# --- Config ---

sub load_handlers {
    my $path = "$FORMS_DIR/handlers.conf";
    return () unless -f $path;

    open my $fh, '<:utf8', $path or return ();
    my $text = do { local $/; <$fh> };
    close $fh;

    my %handlers;
    while ( $text =~ /^\s{2}-\s+id:\s*(\S+)(.*?)(?=^\s{2}-\s+id:|\z)/gmsx ) {
        my ( $id, $block ) = ( $1, $2 );
        my %h = ( id => $id );
        while ( $block =~ /^\s{4}(\w+)\s*:\s*(.+)$/mg ) {
            $h{$1} = $2;
            $h{$1} =~ s/\s+$//;
        }
        $handlers{$id} = \%h;
    }

    return %handlers;
}

# SM231: is a top-level boolean key in a form's own config explicitly OFF?
# Absent, unreadable or anything else => 0 (not off), so the caller's default
# stands. Never rejects, never dies - it is consulted from the notification
# path, which must not be able to affect a submission.
sub _form_conf_flag_off {
    my ( $name, $key ) = @_;
    return 0 unless defined $name && $name =~ /\A[\w.-]+\z/;
    open my $fh, '<:utf8', "$FORMS_DIR/$name.conf" or return 0;
    my $off = 0;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\Q$key\E\s*:\s*(.+?)\s*$/;
        $off = ( $1 =~ /^(?:0|off|false|no)$/i ) ? 1 : 0;
        last;
    }
    close $fh;
    return $off;
}

sub load_form_conf {
    my ($name) = @_;
    my $path = "$FORMS_DIR/$name.conf";
    reject("Form '$name' not configured") unless -f $path;

    open( my $fh, '<:utf8', $path ) or reject("Cannot read form config");
    my $text = do { local $/; <$fh> };
    close $fh;

    my @targets;

    # New format: handler references
    while ( $text =~ /^\s*-\s+handler:\s*(\S+)/mg ) {
        push @targets, { handler => $1 };
    }

    # Legacy format: inline type config
    if ( !@targets ) {
        while ( $text =~ /^\s*-\s+type:\s*(\w+)\s*$(.*?)(?=^\s*-\s+type:|\z)/gms ) {
            my ( $type, $block ) = ( $1, $2 );
            my %t = ( type => $type );
            $t{url}    = $1 if $block =~ /^\s*url:\s*(.+)$/m;
            $t{format} = $1 if $block =~ /^\s*format:\s*(.+)$/m;
            $t{path}   = $1 if $block =~ /^\s*path:\s*(.+)$/m;
            $t{$_} =~ s/^\s+|\s+$//g for grep { defined $t{$_} } keys %t;
            push @targets, \%t;
        }
    }

    reject("No targets configured for form '$name'") unless @targets;

    # Optional binary-upload constraints. Present any of these keys to enable file
    # uploads on the form; absent = the form accepts no files.
    #   upload_max_kb:    <int>           max size of EACH file, KiB
    #   upload_max_files: <int>           max number of files per submission
    #   upload_accept:    jpg, png, pdf   allowed extensions (also matched loosely
    #                                     against the part's Content-Type)
    my $upload;
    if ( $text =~ /^\s*upload_(?:max_kb|max_files|accept)\s*:/m ) {
        my ($kb)   = $text =~ /^\s*upload_max_kb\s*:\s*(\d+)/m;
        my ($maxn) = $text =~ /^\s*upload_max_files\s*:\s*(\d+)/m;
        my ($acc)  = $text =~ /^\s*upload_accept\s*:\s*(.+?)\s*$/m;
        my @accept = grep { length }
            map { my $x = lc $_; $x =~ s/^\s+|\s+$//g; $x =~ s/^\.//; $x }
            split /[,\s|]+/, ( $acc // '' );
        $upload = {
            max_kb    => ( $kb   ? $kb + 0   : 5120 ),    # 5 MiB default
            max_files => ( $maxn ? $maxn + 0 : 5 ),
            accept    => \@accept,                        # empty = any type
        };
    }

    # SM401: per-form submission ceiling, submissions per address per hour.
    # Absent leaves the shipped default of 5; `off` (or 0) removes the limit for
    # a form whose access is already controlled another way.
    my $rate_limit;
    if ( my ($rl) = $text =~ /^\s*rate_limit\s*:\s*(\S+)/m ) {
        $rate_limit = ( lc $rl eq 'off' || lc $rl eq 'none' ) ? 0
            : ( $rl =~ /^\d+$/ ) ? $rl + 0
            :                      undef;
    }

    # SM216: per-form quarantine scoring config. quarantine defaults ON - a false
    # positive still arrives (just unannounced, under the Quarantine filter), so
    # cheap heuristics are safe on by default. spam_keywords is a comma-separated
    # operator list; spam_url_threshold is the min URL count that flags (default 2).
    my ($q)  = $text =~ /^\s*quarantine\s*:\s*(\S+)/m;
    my ($kw) = $text =~ /^\s*spam_keywords\s*:\s*(.+?)\s*$/m;
    my ($ut) = $text =~ /^\s*spam_url_threshold\s*:\s*(\d+)/m;

    return {
        targets            => \@targets,
        upload             => $upload,
        quarantine         => ( defined $q  ? $q      : 'on' ),
        spam_keywords      => ( defined $kw ? $kw     : '' ),
        spam_url_threshold => ( defined $ut ? $ut + 0 : 2 ),
        rate_limit         => $rate_limit,    # SM401; undef = default
    };
}

# SM216: quarantine scoring - store-but-flag a suspect submission (kept out of the
# notification bell, shown under the Submissions Quarantine filter) rather than
# reject it. A false positive costs nothing (the message still arrives, just
# unannounced), which is what makes cheap content heuristics safe on by default.
# Signals: >= spam_url_threshold URLs in the visible text, and any operator keyword.
# Returns (0|1, reason). Content-based and server-side - no tracker, no CAPTCHA.
sub _spam_assessment {
    my ( $form, $conf ) = @_;
    return ( 0, '' )
        if lc( $conf->{quarantine} // 'on' ) =~ /^(?:0|off|no|false|disabled)$/;

    my $text = '';
    for my $k ( keys %$form ) {
        next if $k =~ /^_/;
        $text .= ' ' . $form->{$k}
            if defined $form->{$k} && !ref $form->{$k};
    }

    my @reasons;
    my $threshold = ( $conf->{spam_url_threshold} // 2 ) + 0;
    my $urls      = () = $text =~ m{https?://}gi;
    push @reasons, "$urls urls" if $threshold > 0 && $urls >= $threshold;

    if ( defined $conf->{spam_keywords} && length $conf->{spam_keywords} ) {
        for my $kw ( split /\s*,\s*/, $conf->{spam_keywords} ) {
            next unless length $kw;
            if ( $text =~ /\Q$kw\E/i ) { push @reasons, "keyword '$kw'"; last }
        }
    }

    return @reasons ? ( 1, join( ' + ', @reasons ) ) : ( 0, '' );
}

# --- Dispatch ---

sub dispatch {
    my ( $target, $form, $handlers_ref ) = @_;

    my %h_config;
    if ( $target->{handler} ) {
        my $id = $target->{handler};
        unless ( $handlers_ref->{$id} ) {
            log_event( 'WARN', $form->{_form} // '-', 'unknown handler', handler => $id );
            return 0;
        }
        %h_config = %{ $handlers_ref->{$id} };

        if ( lc( $h_config{enabled} // 'true' ) eq 'false' ) {
            return 0;    # handler disabled - did NOT deliver
        }
    }
    else {
        %h_config = %$target;
    }

    my $type = $h_config{type} // '';

    if    ( $type eq 'file' )  { return dispatch_file( \%h_config, $form ) }
    elsif ( $type eq 'db' )    { return dispatch_db( \%h_config, $form ) }
    elsif ( $type eq 'table' ) { return dispatch_table( \%h_config, $form ) }
    elsif ( $type eq 'smtp' )  { return dispatch_smtp( \%h_config, $form ) }
    elsif ( $type eq 'webhook' || $type eq 'api' ) { return dispatch_webhook( \%h_config, $form ) }
    else {
        log_event( 'WARN', $form->{_form} // '-', 'unknown handler type', type => $type );
        return 0;
    }
}

# DP-4: a form submission becomes a row in a typed table.
#
# THIS IS THE ANONYMOUS WRITE PATH, AND THE ONLY ONE. lazysite-data.pl refuses
# an anonymous POST and says a form is how you collect data from visitors -
# this is what it is pointing at. The difference is not the storage, it is
# everything around it: a form has rate limits, spam assessment, quarantine, an
# audit trail, and a handler an operator configured. A data binding taking
# anonymous writes would rebuild that surface without any of it.
#
# SO THE OPERATOR'S HANDLER DECIDES EVERYTHING STRUCTURAL, and the visitor
# decides only values. The table and the column names come from handlers.conf,
# which is operator-only; the form supplies values and nothing else. A form
# that grows a field cannot grow a column, and a field nobody mapped is
# DROPPED rather than guessed at.
#
#     - id: enquiries
#       type: db
#       table: enquiries
#       fields: name=name,email=email,message=body
#
# `fields` reads FORM=COLUMN. It is REQUIRED: mapping same-named fields
# automatically would mean a form gaining a field silently starts writing to a
# column, which is the accident this whole shape exists to prevent.
#
# THE ROW GOES THROUGH THE SAME COERCION AS ANY OTHER WRITE, so a form cannot
# put anything into the store that the API could not - a date that is not one,
# a value outside an enum, a decimal with too many places. A refused value
# fails the delivery rather than storing something wrong, because a visitor
# told "thank you" about a submission that was silently dropped is the worst of
# the available outcomes.
#
# THE MODULES ARE FOUND, NOT ASSUMED. This plugin loads no Lazysite modules -
# it has the same standalone property the processor has - so the tree is
# located here exactly as resolve_db locates it, and a host without the data
# modules gets a DIAGNOSIS rather than a die that becomes a 500 (SM472).
sub dispatch_db {
    my ( $config, $form ) = @_;
    my $fname = $form->{_form} // '-';

    my $table = $config->{table} // '';
    unless ( $table =~ /\A[a-z][a-z0-9_]*\z/ ) {
        log_event( 'ERROR', $fname,
            'db handler has no usable table name', table => $table );
        return 0;
    }

    my $map = $config->{fields} // '';
    unless ( length $map ) {
        log_event( 'ERROR', $fname,
            'db handler has no fields mapping - it must say which form field '
                . 'goes in which column, as fields: name=name,email=email' );
        return 0;
    }

    my $ok = eval {
        unless ( $INC{'Lazysite/Data/Tables.pm'} ) {
            require Cwd;
            require File::Basename;
            my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
            for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
                if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
            }
        }
        require Lazysite::Data::Tables;
        require Lazysite::Manager::Plugins;
        1;
    };
    unless ($ok) {
        log_event( 'ERROR', $fname,
            'db handler needs the data modules and they could not be loaded',
            error => ( $@ || 'unknown' ) );
        return 0;
    }

    # A DISABLED PLUGIN STORES NOTHING. SM409's rule is that off means off, and
    # a form quietly writing to a table an operator has switched off would be
    # the plugin still running after being turned off.
    {
        no warnings 'once';    # SM557
        local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
        unless (
            Lazysite::Manager::Plugins::plugin_enabled('plugins/data.pl') )
        {
            log_event( 'ERROR', $fname,
                'the data plugin is disabled, so this form cannot store a row',
                table => $table );
            return 0;
        }
    }

    # VALUES ONLY. Every column is named by the operator's mapping; the form is
    # read for values at those names and for nothing else.
    my %row;
    for my $pair ( split /\s*,\s*/, $map ) {
        my ( $from, $to ) = split /\s*=\s*/, $pair, 2;
        next unless defined $from && defined $to && length $from && length $to;
        unless ( $to =~ /\A[a-z][a-z0-9_]*\z/ ) {
            log_event( 'ERROR', $fname,
                'db handler maps to something that is not a column name',
                column => $to );
            return 0;
        }
        next if $from =~ /\A_/;    # the _-prefixed keys are the form's own
        $row{$to} = $form->{$from} if exists $form->{$from};
    }

    unless (%row) {
        log_event( 'WARN', $fname,
            'db handler stored nothing - no mapped field was submitted',
            table => $table );
        return 0;
    }

    my $r = Lazysite::Data::Tables::insert_row( $DOCROOT, $table, \%row );
    unless ( $r && $r->{ok} ) {
        # SAID, WITH THE REASON. "the submission failed" sends an operator to
        # look at the form; "field 'when': '32nd' is not a date" sends them to
        # the one line that is wrong.
        log_event( 'ERROR', $fname, 'db handler could not store the row',
            table => $table, why => ( $r->{error} // 'unknown' ) );
        return 0;
    }

    log_event( 'INFO', $fname, 'form stored a row', table => $table );
    return 1;
}

# SM569: a `table` handler is DP-4's db insert AND the JSONL submissions
# store, together. The row goes through dispatch_db unchanged - the same
# operator-only mapping, the same plugin-enabled gate, the same insert_row
# coercion as a live write - and the JSONL copy that the Submissions page,
# the audit trail and SM187's bulk delete depend on is written alongside.
# When the row is REFUSED (a value the declared types will not take), the
# copy is still written and carries _row_refused: the rejected-import shape,
# no row landed and the record says so - while the handler reports failure,
# so the visitor is not thanked for a submission the table refused.
sub dispatch_table {
    my ( $config, $form ) = @_;
    my $stored = dispatch_db( $config, $form );
    my %copy   = %$form;
    $copy{_row_refused} = 1 unless $stored;
    my $filed = dispatch_file( $config, \%copy );
    log_event( 'ERROR', $form->{_form} // '-',
        'table handler stored the row but not the submissions copy' )
        if $stored && !$filed;
    return $stored;
}

# SM115: record a submission in the audit trail. The submitter is the public, so the
# user is usually blank; written directly in Lazysite::Audit's pipe format (origin
# "form"), since the handler does not load the lib.
sub _audit_submission {
    my ( $form, $user, $ip ) = @_;
    my $logdir = "$DOCROOT/lazysite/logs";
    return unless -d $logdir;
    $_ = defined $_ ? "$_" : '' for ( $form, $user, $ip );
    s/[|\r\n]+/ /g for ( $form, $user, $ip );
    my $ts = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    open my $fh, '>>', "$logdir/audit.log" or return;
    print {$fh} "$ts | $user | submit | $form | $ip | ok | form\n";
    close $fh;
    return;
}

# SM216-2: map an anti-spam reject message to a stable reason code, or '' if the
# failure was not a spam control (method / validation / delivery - not counted).
sub _block_reason {
    my ($err) = @_;
    return 'honeypot' if $err =~ /Spam detected/;
    return 'too_fast' if $err =~ /Submission too fast/;
    return 'expired'  if $err =~ /Submission expired/;
    return 'token'    if $err =~ /Invalid submission/;
    return 'rate'     if $err =~ /Rate limit exceeded/;
    return '';
}

# SM216-2: append one outcome line so the stats plugin can fold blocked-vs-stored
# counts into its day-buckets. Append-only, one line per event, so concurrent
# POSTs never race (O_APPEND under a lock). Counts only - the form name, an
# outcome (stored|quarantined|blocked) and, for a block, a reason code; never any
# submitted field. Best-effort: a stats hiccup must never fail a submission.
sub _record_form_event {
    my ( $form, $outcome, $reason ) = @_;
    ( my $f = defined $form ? "$form" : '' ) =~ s/[^a-zA-Z0-9_-]//g;
    return unless length $f;
    my $dir = "$DOCROOT/lazysite/stats/form-events";
    eval {
        make_path($dir) unless -d $dir;
        my $day = strftime( '%Y-%m-%d', localtime );
        my %ev  = ( t => time(), day => $day, form => $f, outcome => "$outcome" );
        $ev{reason} = "$reason" if defined $reason && length $reason;
        if ( open my $fh, '>>', "$dir/$day.jsonl" ) {
            flock $fh, LOCK_EX;
            print {$fh} encode_json( \%ev ) . "\n";
            close $fh;
        }
        1;
    };
    return;
}

# SM113: raise an operator notification for a new submission. Append-only store
# the manager reads for its unread badge. Best-effort (never blocks delivery).
sub _notify_submission {
    my ($form) = @_;
    my $logdir = "$DOCROOT/lazysite/logs";
    return unless -d $logdir;
    ( my $f = defined $form ? "$form" : '' ) =~ s/[\r\n]+/ /g;

    # SM231 emission control, PER FORM. A partner's three-day programme
    # established the scale: 46 form steps per participant across 15
    # participants is 690 notices where five were wanted. Batching them would
    # need pending state and a timer lazysite does not have; the answer is that
    # a form says whether it announces itself.
    #
    # Default ON, so every existing form behaves exactly as before and a site
    # that never sets this notices nothing. `notify: off` in the form's own
    # .conf silences that form alone - the other forty-one steps stay quiet
    # while the five that matter still speak. (Site-wide silencing of the whole
    # type is the separate `emit.submission` key in notify.conf.)
    # Read the one key directly rather than through load_form_conf, which
    # returns delivery targets and calls reject() on a missing or empty config -
    # aborting a request from inside a best-effort notification would be a
    # spectacular way to fail.
    return if _form_conf_flag_off( $form, 'notify' );

    # SM136: prefer the shared notify path (bell + optional XMPP delivery). This
    # plugin ships without `use lib`, so locate the module tree the same way the
    # processor's lazy-require does; on any failure fall through to the plain
    # bell-store append below so a submission notice is never lost.
    my $sent = eval {
        unless ( $INC{'Lazysite/Notify.pm'} ) {
            require Cwd;
            require File::Basename;
            my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
            for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
                if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
            }
            require Lazysite::Notify;
        }
        Lazysite::Notify::notify( $DOCROOT, {
                type    => 'submission',
                message => "New form submission: $f",
                target  => $f,
                url     => '/manager/plugins',
        } );
    };
    return if $sent;

    my $line = encode_json( {
            ts      => time(),
            type    => 'submission',
            message => "New form submission: $f",
            target  => $f,
            url     => '/manager/plugins',
    } );
    open my $fh, '>>', "$logdir/notices.jsonl" or return;
    print {$fh} "$line\n";
    close $fh;
    return;
}

sub dispatch_file {
    my ( $config, $form ) = @_;

    my $dir = $config->{path} || 'lazysite/forms/submissions';
    $dir = "$DOCROOT/$dir" unless $dir =~ m{^/};
    make_path($dir) unless -d $dir;

    my $form_name = $form->{_form} // 'unknown';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;

    my %record;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $record{$k} = $form->{$k};
    }
    $record{_submitted} = strftime( '%Y-%m-%dT%H:%M:%S', localtime );
    $record{_ip}        = $ENV{REMOTE_ADDR} // 'unknown';
    $record{_form}      = $form_name;

    # SM216: carry the quarantine flag + reason onto the stored record so the
    # Submissions viewer can surface and triage it. (The dispatch loop's own copy
    # of %form set these; _-prefixed keys are otherwise dropped above.)
    if ( $form->{_quarantined} ) {
        $record{_quarantined} = JSON::PP::true;
        $record{_spam_reason} = $form->{_spam_reason} // '';
    }

    # SM569: a table handler's JSONL copy records a refused row like a
    # rejected import - the row did not land, and the copy says so.
    $record{_row_refused} = JSON::PP::true if $form->{_row_refused};

    # Binary uploads: store the files in a per-submission subdir next to the
    # <form>.jsonl, and record the (sanitised) filenames + their dir in the record.
    if ( $form->{_files} && @{ $form->{_files} } ) {
        my $id = strftime( '%Y%m%dT%H%M%S', localtime )
            . '-' . sprintf( '%04x', int( rand 65536 ) );
        my ( $saved, $rel ) = save_uploads( $form->{_files}, $dir, $form_name, $id );
        if (@$saved) {
            $record{_files}     = $saved;
            $record{_files_dir} = $rel;
        }
    }

    my $log_path = "$dir/$form_name.jsonl";
    open( my $fh, '>>:utf8', $log_path ) or do {
        log_event( 'ERROR', $form->{_form} // '-', 'file write failed', path => $log_path, error => $! );
        return 0;
    };
    flock( $fh, LOCK_EX );
    my $wrote = print $fh encode_json( \%record ) . "\n";
    flock( $fh, LOCK_UN );
    # SM020 checked-write (review D5): a failed print surfaces at close (buffer
    # flush). Without the check a disk-full submission was acknowledged as
    # delivered while the record never landed - fail closed so the visitor is
    # told delivery failed rather than thanked for a lost submission.
    unless ( close($fh) && $wrote ) {
        log_event( 'ERROR', $form->{_form} // '-', 'file write failed (flush)', path => $log_path, error => $! );
        return 0;
    }
    return 1;
}

# Enforce the form's upload constraints; reject() (die) on the first violation.
sub validate_uploads {
    my ( $files, $cfg ) = @_;
    reject_user("Too many files (max $cfg->{max_files}).")
        if @$files > $cfg->{max_files};
    my %ok = map { $_ => 1 } @{ $cfg->{accept} };
    for my $f (@$files) {
        my $kb = int( ( length( $f->{data} ) + 1023 ) / 1024 );
        reject_user("File '$f->{filename}' is too large (max $cfg->{max_kb} KiB).")
            if $kb > $cfg->{max_kb};
        next unless keys %ok;
        my ($ext) = lc( $f->{filename} ) =~ /\.([a-z0-9]+)$/;
        reject_user( "File type not allowed: $f->{filename} (accepted: "
                . join( ', ', @{ $cfg->{accept} } ) . ').' )
            unless $ext && $ok{$ext};
    }
    return;
}

# Path-safe: strip any directory component (traversal) and keep a conservative
# whitelist of characters. Returns a bare, safe basename.
sub _safe_filename {
    my ($n) = @_;
    $n =~ s{.*[\\/]}{};
    $n =~ s/[^A-Za-z0-9._-]/_/g;
    $n =~ s/^\.+//;
    $n = 'file' unless length $n;
    return substr( $n, 0, 100 );
}

# Write the uploaded files into <dir>/<form>.files/<id>/. Returns (\@saved_names,
# $relative_subdir).
sub save_uploads {
    my ( $files, $dir, $form_name, $id ) = @_;
    my $rel  = "$form_name.files/$id";
    my $fdir = "$dir/$rel";
    make_path($fdir) unless -d $fdir;
    my @saved;
    my $i = 0;
    for my $f (@$files) {
        $i++;
        my $safe = _safe_filename( $f->{filename} );
        $safe = "$i-$safe" if -e "$fdir/$safe";    # keep both if names collide
        open my $w, '>:raw', "$fdir/$safe" or next;
        print {$w} $f->{data};
        close $w;
        push @saved, $safe;
    }
    return ( \@saved, $rel );
}

sub dispatch_smtp {
    my ( $config, $form ) = @_;

    my $script = find_script('form-smtp.pl');
    unless ($script) {
        log_event( 'WARN', $form->{_form} // '-', 'smtp script not found' );
        return;
    }

    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my %payload = ( config => $config, form => \%fields );

    # When the SMTP handler is set to attach uploads, hand the files (base64) to
    # form-smtp.pl so it can attach them and list them under the message.
    my $attach = defined $config->{attach_files}
        && lc("$config->{attach_files}") =~ /^(?:1|true|yes|on|enabled)$/;
    if ( $attach && $form->{_files} && @{ $form->{_files} } ) {
        require MIME::Base64;
        $payload{files} = [ map {
                { filename => $_->{filename},
                    type => $_->{type},
                    size => length( $_->{data}                      // '' ),
                    data => MIME::Base64::encode_base64( $_->{data} // '' ),
                }
        } @{ $form->{_files} } ];
    }

    my $json = encode_json( \%payload );

    require IPC::Open2;
    my ( $child_out, $child_in );
    my $pid = IPC::Open2::open2( $child_out, $child_in, $^X, $script, '--pipe' );
    print $child_in $json;
    close $child_in;
    my $result = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;

    my $r = eval { decode_json( $result // '' ) } // {};
    unless ( $r->{ok} ) {
        log_event( 'WARN', $form->{_form} // '-', 'smtp dispatch failed',
            error => ( $r->{error} // 'no output' ) );
    }
    return $r->{ok} ? 1 : 0;
}

sub dispatch_webhook {
    my ( $config, $form ) = @_;
    my $url = $config->{url} or return;

    my %fields;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $fields{$k} = $form->{$k};
    }

    my $body;
    if ( ( $config->{format} // 'json' ) eq 'slack' ) {
        my $text = join "\n", map { "*$_*: $fields{$_}" } sort keys %fields;
        $body = encode_json( { text => $text } );
    }
    else {
        $body = encode_json( \%fields );
    }

    require LWP::UserAgent;
    my $ua  = LWP::UserAgent->new( timeout => 10 );
    my $res = $ua->post( $url,
        'Content-Type' => 'application/json',
        Content        => $body );

    unless ( $res->is_success ) {
        log_event( 'WARN', $form->{_form} // '-', 'webhook failed',
            url => $url, status => $res->status_line );
    }
    return $res->is_success ? 1 : 0;
}

sub find_script {
    my ($name) = @_;
    # D022: $DOCROOT/../plugins/ is now the canonical home.
    # The other paths stay as fallbacks so 0.1.0 installs
    # still work during the upgrade transition, and operators
    # who choose a system-wide install layout keep working.
    for my $path (
        "$DOCROOT/../plugins/$name",
        "$DOCROOT/../cgi-bin/$name",
        "$DOCROOT/../$name",
        "/usr/local/lib/lazysite/$name",
    ) {
        return $path if -f $path;
    }
    return;
}

# --- POST parsing ---

sub parse_post {
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    my $type = $ENV{CONTENT_TYPE}   || '';
    my $data = '';

    reject('Upload too large') if $len > $MAX_POST_BYTES;

    binmode STDIN;    # binary-safe: file parts carry raw bytes
    if ( $len > 0 ) { read( STDIN, $data, $len ); }
    else            { local $/; $data = <STDIN> // ''; }

    my %form;
    my @files;
    if ( $type =~ m{multipart/form-data.*boundary=(.+)}i ) {
        my $boundary = $1;
        $boundary =~ s/^\s+//;
        $boundary =~ s/["\s]+$//;
        for my $part ( split /--\Q$boundary\E/, $data ) {
            # part = optional CRLF, headers, blank line, body, trailing CRLF
            next unless $part =~ /\A\r?\n?(.*?)\r?\n\r?\n(.*)\z/s;
            my ( $head, $body ) = ( $1, $2 );
            next unless $head =~ /name="([^"]*)"/i;
            my $name = $1;
            $body =~ s/\r?\n\z//;    # drop the CRLF that precedes the next boundary
            if ( $head =~ /filename="([^"]*)"/i ) {
                my $filename = $1;
                next unless length $filename;    # an empty file input - skip
                my ($ctype) = $head =~ /Content-Type:\s*([^\r\n]+)/i;
                push @files, {
                    field    => $name,
                    filename => $filename,
                    type     => ( $ctype // 'application/octet-stream' ),
                    data     => $body,
                };
            }
            else {
                _field_add( \%form, $name, sanitise_header( $body, 10000 ) );
            }
        }
    }
    else {
        for my $pair ( split /&/, $data ) {
            my ( $k, $v ) = split /=/, $pair, 2;
            next unless defined $k;
            $k =~ s/\+/ /g;
            $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $v //= '';
            $v =~ s/\+/ /g;
            $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            _field_add( \%form, $k, sanitise_header( $v, 10000 ) );
        }
    }
    # SM523: the engine's status meta is ENGINE-OWNED. Every key that reaches a
    # gate, a target or a stored record with a leading underscore is set HERE
    # or downstream (_files, _quarantined, _spam_reason, _submitted, _ip) -
    # except the five protocol keys the renderer emits. A visitor who posted
    # _quarantined=1 used to mute their own notification and skew the counts,
    # because the SM216 block only ever SET the flags on top of what arrived.
    for my $k ( keys %form ) {
        next unless $k =~ /^_/;
        next if $PROTOCOL_KEY{$k};
        delete $form{$k};
    }
    $form{_files} = \@files if @files;
    _fold_quantities( \%form );
    return %form;
}

# SM401: a REPEATED key accumulates rather than overwriting.
#
# One name submitted several times is how HTML has always expressed a
# multi-select, and a plain assignment kept only the last one - so a checkbox
# group silently lost every tick but the final one. Silently, because the
# submission still arrived and still looked well-formed. SM539: the multipart
# branch kept that assignment after the urlencoded one had learnt better, so
# a form with an upload lost its ticks; both branches now come through here.
sub _field_add {
    my ( $form, $k, $v ) = @_;
    if ( exists $form->{$k} && length $form->{$k} ) {
        $form->{$k} .= "; $v" if length $v;
    }
    else {
        $form->{$k} = $v;
    }
    return;
}

# SM401: fold `field~qty~OPTION` inputs back into their field.
#
# checklist-qty asks a question the flat name/value shape cannot carry: WHICH
# options, and HOW MANY of each. The alternative was to teach this handler the
# form's field types, which it does not have and should not - the page defines
# the form, the handler receives it. Encoding the relationship in the NAME keeps
# the handler generic: it needs no schema, only a rule.
#
# A quantity is kept only when its option was actually ticked, so unticking a box
# and leaving a number behind - which is exactly what a person does when they
# change their mind - does not submit a quantity for something they deselected.
sub _fold_quantities {
    my ($form) = @_;
    my %qty;
    for my $k ( keys %$form ) {
        next unless $k =~ /\A(.+)~qty~(.+)\z/s;
        my ( $base, $opt ) = ( $1, $2 );
        my $v = $form->{$k};
        delete $form->{$k};
        next unless defined $v && $v =~ /\A\s*\d+\s*\z/ && $v + 0 > 0;
        $qty{$base}{$opt} = $v + 0;
    }
    for my $base ( keys %qty ) {
        my @ticked = grep { length } split /\s*;\s*/, ( $form->{$base} // '' );
        my @out;
        for my $opt (@ticked) {
            push @out, exists $qty{$base}{$opt} ? "$opt=$qty{$base}{$opt}" : $opt;
        }
        $form->{$base} = join '; ', @out if @out;
    }
    return;
}

# --- Security ---

sub check_honeypot {
    my ($hp) = @_;
    reject('Spam detected') if defined $hp && length $hp;
}

sub check_timestamp {
    my ( $ts, $tk, $secret ) = @_;
    reject('Invalid submission') unless $ts && $tk;
    reject('Invalid submission') unless $ts =~ /^\d+$/;
    my $expected = hmac_sha256_hex( $ts, $secret );
    reject('Invalid submission') unless $tk eq $expected;
    my $age = time() - $ts;
    reject('Submission too fast') if $age < 3;
    reject('Submission expired')  if $age > 7200;
}

# SM401: the limit is PER FORM, and the default is unchanged.
#
# Five an hour per address is right for a public contact form and wrong for an
# authenticated office team working through twenty-five data-entry pages from one
# office address - which is a real deployment, not a hypothetical.
#
# WHY NOT "EXEMPT LOGGED-IN USERS" ON A HEADER - AND WHY THE COOKIE PATH NOW
# DOES (SM425). This handler is NOT behind the auth wrapper: the templates
# front only lazysite-processor.pl and lazysite-manager-api.pl with it, and
# /cgi-bin/ is otherwise a plain ScriptAlias. So HTTP_X_REMOTE_USER arrives
# here exactly as the client sent it, and exempting on it would mean any
# request carrying `X-Remote-User: anything` skipped the limit - a spam
# control one header away from useless. That refusal STANDS for headers. The
# SM425 exemption above is different in kind: it verifies the session COOKIE
# cryptographically (SM411's shared verifier - HMAC, registry, account
# checks), which no client can mint without the site secret. The identity it
# yields is used as a boolean for the limiter and recorded nowhere, so the
# SM402 line holds unchanged. See SM402 for the
# related finding that the same header is already trusted for ATTRIBUTION here.
#
# An operator setting `rate_limit:` on the one gated form they built is explicit,
# auditable, and needs no trust decision about a header nobody verified.
sub check_rate_limit {
    my ( $ip, $limit ) = @_;
    return unless $ip;

    # Absent = 5, the shipped default. 0 or `off` = no limit, for a form whose
    # access is already controlled by something better than an address count.
    $limit = defined $limit ? $limit : 5;
    return if $limit <= 0;
    _ensure_dir_for("$FORMS_DIR/.rate-limit.db");
    my %db;
    tie( %db, 'DB_File', "$FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_HASH ) or return;
    my $hour  = int( time() / 3600 );
    my $key   = "$ip:$hour";
    my $count = $db{$key} || 0;
    if ( $count >= $limit ) { untie %db; reject('Rate limit exceeded'); }
    $db{$key} = $count + 1;
    for my $k ( keys %db ) {
        delete $db{$k} if $k =~ /:(\d+)$/ && $1 < $hour - 1;
    }
    untie %db;
}

sub load_form_secret {
    my $secret_path = "$FORMS_DIR/.secret";
    _ensure_dir_for($secret_path);
    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or die "Cannot read form secret\n";
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }
    die "Form secret not found - render a form page first to generate it\n";
}

# --- Response ---

# SM415: a post WITHOUT JavaScript used to land on raw JSON - with HTTP 200
# on failure. The JS path declares Accept: application/json and keeps
# today's reply byte-for-byte; a native post (a browser says text/html) is
# answered the way login answers: a redirect back to the page it came from,
# carrying the outcome for the form renderer to show as a banner. The page
# rides in the _page hidden field the renderer embeds - validated here as a
# same-site absolute path (no scheme, no protocol-relative, no CRLF), and
# ABSENT means JSON: a stale cached page without the field must never be
# redirected to nowhere.
sub _wants_json {
    return 1 if ( $ENV{HTTP_ACCEPT} // '' ) =~ m{application/json};
    return 1 unless length $REDIRECT_PAGE;
    return 0;
}

sub _redirect_back {
    my ($outcome) = @_;
    $outcome =~ s/([^A-Za-z0-9\-. _])/sprintf '%%%02X', ord $1/ge;
    $outcome =~ tr/ /+/;
    my $to = $REDIRECT_PAGE . '?form=' . $REDIRECT_FORM . '&outcome=' . $outcome;
    print "Status: 303 See Other\r\n";
    print "Location: $to\r\n\r\n";
}

sub respond_ok {
    my ($msg) = @_;
    binmode( STDOUT, ':utf8' );
    return _redirect_back('ok') unless _wants_json();
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1, message => $msg } );
}

sub respond_error {
    my ($msg) = @_;
    binmode( STDOUT, ':utf8' );
    return _redirect_back($msg) unless _wants_json();
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $msg } );
}

sub reject { die "$_[0]\n"; }

# Like reject(), but the message IS shown to the submitter (upload limits etc.).
sub reject_user { die "USER:$_[0]\n"; }

# --- Utilities ---

sub sanitise_header {
    my ( $val, $max ) = @_;
    $max //= 1000;
    $val =~ s/[\r\n]/ /g;
    $val = substr( $val, 0, $max ) if length($val) > $max;
    return $val;
}

sub _ensure_dir_for {
    my ($path) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
}

sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts     = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
        _forward_diag( $level, $json );
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
        _forward_diag( $level, $line );
    }
}

# SM540: a best-effort copy of the line to syslog through Lazysite::Util's
# forward_line, so `forward_diagnostics: true` covers this plugin's
# diagnostics as the docs promise. The module tree is located at runtime (the
# SM473 lesson: `prove -l` puts lib/ on @INC and a real install does not) and
# the require is eval-guarded, the SM425 posture: a missing lib costs the
# operator a syslog copy, never a submission - STDERR has the line either way.
sub _forward_diag {
    my ( $level, $line ) = @_;
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    eval {
        unless ( $INC{'Lazysite/Util.pm'} ) {
            require Cwd;
            require File::Basename;
            my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
            for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
                if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
            }
            require Lazysite::Util;
        }
        Lazysite::Util::forward_line( 'diag', $prio{$level} // 'info', $line );
        1;
    };
    return;
}

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
