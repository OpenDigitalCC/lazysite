package Lazysite::Handlers;

# SM842: ONE WAY TO DELIVER.
#
# A handler is a named, reusable function that takes a flat set of fields and
# delivers it somewhere: an email, a file, a row in a data table, or a call
# through a connector. A form calls handlers by name; the timer calls handlers
# by name. There is no second way to say where data goes.
#
# WHAT THIS REPLACES, and why it was debt rather than variety:
#
#   * THREE PARSERS of lazysite/forms/handlers.conf - the submission path, the
#     manager module and the MCP server - and they disagreed. The MCP one read
#     an absent `enabled` as FALSE while delivery read it as TRUE, so a handler
#     an agent was told was off took every submission.
#   * INLINE TARGETS in a form's own config (`- type: webhook` with a url), a
#     second way to name a destination that no operator vetted and no listing
#     showed. Converted into named handlers once, on upgrade, and not read
#     after that.
#   * WEBHOOK AND API HANDLERS, an outbound HTTP path with no credential, no
#     modes, no rate cap and no call record, beside connectors, which have all
#     four (SM579). Outbound HTTP now goes through a connector and nowhere
#     else; a connector with only a URL is the simple case.
#   * THE CONNECTOR'S OWN TIMER (schedule_every), a schedule that could call one
#     kind of thing. The schedule below calls any handler.
#   * `db` BESIDE `table`, two types for one destination that differed by
#     whether a copy was kept. One type, `table`, with keep_copy.
#
# THE DESTINATION DECIDES WHO MAY CONFIGURE IT (the release manager,
# 2026-09-11). Creating or editing a handler needs the capability that governs
# where it sends: a table handler writes rows, so it needs manage_data; a
# connector handler sends data off the site, so manage_connectors; email and
# file delivery are the form owner's own business, so manage_forms. Binding a
# form to a handler that already exists needs manage_forms and nothing else -
# the vetting happened when the handler was made. Delivery itself checks
# nothing: a visitor submitting a form, or the timer at 03:00, runs a function
# somebody with the right grant already wrote.
#
# THE STORE. handlers.conf and schedule.conf live beside the forms they serve
# in lazysite/forms/, and the SM766 rule applies to both: a file that exists
# and cannot be opened is not an empty file. Every reader answers undef for
# "cannot tell", and every write refuses to land on something it could not
# read - SM785 lost every account's settings to exactly that shape, and a
# handler save over an unreadable handlers.conf would have replaced every
# handler with one.
use strict;
use warnings;
use JSON::PP        ();
use File::Path      qw(make_path);
use File::Basename  qw(dirname);
use POSIX           qw(strftime);
use Fcntl           qw(:flock);
use Lazysite::Util  qw(log_event cannot_read);
use Lazysite::Paths ();

our $VERSION = '1.0';
our $DOCROOT = '';

# --- the catalogue -----------------------------------------------------------
#
# Every handler carries id, type, name and enabled. What else it carries is its
# type's schema, and nothing else: a key the schema does not declare is refused
# at save by name, never kept and ignored (SM772 found a required key dropped
# with ok:true; the converse, a key accepted and never read, is the same fault).
#
# `cap` is the destination's capability - the one gate for creating, editing,
# deleting and scheduling a handler of the type, and the one the timer's job
# account must hold to run it.
#
# Field types: text, email, boolean, and two that name something the engine
# already knows - `table` (a declared data table) and `connector` (a configured
# connector). Those are chosen from a list on every surface that draws a form,
# never typed (SM806).
our @TYPE_ORDER = qw(smtp file table connector notify odoo);
our %TYPES      = (
    smtp => {
        label  => 'Send email',
        cap    => 'manage_forms',
        schema => [
            { key => 'from', label => 'From address', type => 'email', required => 1 },
            { key => 'to',   label => 'To address',   type => 'email', required => 1 },
            { key => 'subject_prefix', label => 'Subject prefix', type => 'text',
                default => '[Contact] ' },
            { key => 'attach_files', label => 'Attach uploaded files', type => 'boolean',
                default => 'false',
                note => 'Files uploaded with a form are attached and listed (name and size) '
                    . 'below the message. Mind the mail server\'s attachment limits.' },
            # SM877: THE KEY IS NAMED FOR WHAT IT TURNS ON, not for the
            # mechanism. The filing's own shape was `to_field`, and its own
            # objection to it was that "an operator reading to_field: on a
            # familiar handler may not register what they have switched on".
            # The alternative considered was a separate handler type; that was
            # refused because SM842 spent a release REMOVING types that
            # duplicated a delivery path, and this duplicates the whole of one.
            # So: the same type, and a key that says the site will write to a
            # stranger.
            { key => 'mail_the_submitter_field', label => 'Also acknowledge the submitter',
                type => 'text',
                note => 'The name of a form field holding an email address. Set it and the '
                    . 'site sends a SECOND, separate message to whatever address that '
                    . 'field contains - an acknowledgement, receipt or confirmation. '
                    . 'Leave it blank and nothing changes. The address comes from the '
                    . 'submission, so the two caps below are what stand between this and '
                    . 'an open relay.' },
            { key => 'submitter_per_destination_hour',
                label   => 'Cap: messages to one address per hour', type => 'text',
                default => '3',
                note    => 'Counted per recipient. An acknowledgement flow needs one; an '
                    . 'attacker aiming at one inbox needs many.' },
            { key => 'submitter_per_site_hour',
                label => 'Cap: acknowledgements from this site per hour', type => 'text',
                default => '60',
                note => 'Counted across every form. The default is deliberately above a '
                    . 'real burst - one lead form took 18 in an hour at an expo - so it '
                    . 'bounds abuse without refusing a good day.' },
        ],
        note => 'How mail leaves the site - sendmail or an SMTP server - is the Form SMTP '
            . 'extension\'s configuration, shared by every email handler.',
    },
    file => {
        label  => 'Save to file',
        cap    => 'manage_forms',
        schema => [
            { key => 'path', label => 'Storage directory', type => 'text',
                default => 'lazysite/forms/submissions',
                note    => 'Relative to the site. Each form (or schedule entry) writes '
                    . '<name>.jsonl inside it; the Submissions page reads it.' },
        ],
    },
    table => {
        label  => 'Store in a data table',
        cap    => 'manage_data',
        schema => [
            { key => 'table', label => 'Table', type => 'table', required => 1 },
            # SM923: max_len 4000, not the generic 500. A pair is at most a
            # 128-character field name plus a 64-character column name, so 4000
            # carries any realistic form - the 31-field one that produced the
            # report needs about 1,000 - while still bounding the conf value,
            # which is what the cap is for. The map stays REQUIRED: it is the only
            # thing standing between a posted key and a column.
            { key => 'fields', label => 'Field mapping', type => 'text', required => 1,
                max_len => 4000,
                note => 'field=column, comma separated. It is what keeps a visitor from '
                    . 'choosing where their data goes: a field nobody maps is dropped, so a '
                    . 'form gaining a field cannot start writing a column - and neither can '
                    . 'a visitor who posts a key the form never had.' },
            { key => 'keep_copy', label => 'Keep a submissions copy', type => 'boolean',
                default => 'true',
                note => 'Also keep each submission in lazysite/forms/submissions, so the '
                    . 'Submissions page, exports and bulk delete work. A row the table '
                    . 'refuses is kept there and marked as refused.' },
            # SM905 U4: the uploads were reachable only from the submissions
            # record, so an operator working the table had a lead with no
            # photograph. The key names a COLUMN rather than switching a
            # behaviour on, because the row has to have somewhere to put it and
            # only the table's own descriptor says where.
            # SM857 (its open question 4, ruled 2026-09-29): THE HANDLER SAYS WHAT
            # ITS ROWS ARE. The ruling that gave a row a policy also said the time
            # to set one is at WRITE - "whatever is creating the row gets to say
            # the policy" - and a form handler is a writer with nothing to say it
            # with, so every row it wrote came out shared. On a table that declares
            # row_policy, that is the one outcome the declaration exists to
            # prevent: the filing's own words are that the safe case took extra
            # work, and it is the piece the expo depends on.
            { key => 'row_policy', label => 'Each row belongs to', type => 'text',
                note => 'Leave blank and each row is SHARED - anyone the table admits may '
                    . 'amend it, which is how a table without this behaves. Set it to '
                    . 'personal and each row belongs to the account that submitted it, so '
                    . 'one applicant maintains their own application and nobody else\'s. '
                    . 'personal needs the table to declare row_policy: true, and it needs '
                    . 'the SUBMITTER TO BE SIGNED IN - a public form records no account, so '
                    . 'its rows would belong to nobody and only an operator could amend '
                    . 'them. The delivery says so when that happens.' },
            { key => 'files_column', label => 'Column for the uploaded files', type => 'text',
                note => 'The name of a column in the table above. Each submission\'s uploaded '
                    . 'files are written into it as site-relative paths, comma separated, so '
                    . 'the row an operator works from reaches the photograph. A submission '
                    . 'with no files leaves the column empty. Needs the submissions copy, '
                    . 'which is what stores the files.' },
        ],
        note => 'Needs the Data tables extension to be enabled. Values are checked against '
            . 'the table\'s declared types: a submission that does not fit is refused, and '
            . 'the visitor is told, rather than stored wrong.',
    },
    connector => {
        label  => 'Send through a connector',
        cap    => 'manage_connectors',
        schema => [
            { key => 'connector', label => 'Connector', type => 'connector', required => 1,
                note => 'A form can use it only if the connector permits public '
                    . 'invocation; the schedule only if it permits scheduled invocation.' },

            # SM905 U1: THE DIFFERENCE BETWEEN A PHOTOGRAPH BEING STORED AND
            # BEING PROCESSED.
            #
            # A connector is already the governed way out - an operator-vetted
            # destination, a credential in the reserved tree, declared modes, a
            # rate cap, one audit record per call. Every control that ought to
            # apply to sending a customer's photograph to a service already
            # applies. The only thing missing was that the payload could not
            # contain the photograph: the handler passed the visible text fields
            # and never read the files, though `$ctx` was on the line above.
            #
            # Same name, same shape and the same default as the email handler's,
            # which is the working template a few lines up this file.
            { key => 'attach_files', label => 'Send uploaded files', type => 'boolean',
                default => 'false',
                note    => 'Uploaded files are added to the payload as `files` - name, '
                    . 'type, size and base64 data - the same shape the email '
                    . 'handler sends. The destination decides what to do with '
                    . 'them; the answer comes back on the connector\'s own JSON '
                    . 'contract.' },
            { key => 'attach_max_kb', label => 'Attachment ceiling (KB)', type => 'number',
                default => '1024',
                note    => 'Total across all files. A request over the ceiling is '
                    . 'REFUSED and says so, rather than being sent short - a '
                    . 'truncated payload is worse than a refusal, because the '
                    . 'destination cannot tell. A phone photograph is 3 to 8 MB, '
                    . 'so raise this deliberately rather than by default.' },
        ],
        note => 'Everything that leaves the site over HTTP goes through a connector. A '
            . 'connector with only a URL is the simple case.',
    },

    # SM1019 (SM1010 phase 1): A NOTIFICATION RULE. Delivering one queues the
    # event (Lazysite::Outbox::enqueue) and returns; the daemon's notify-outbox
    # job resolves the recipients and sends, once each. The grammar of
    # `recipients` and the rulings it is built to are in Lazysite::Outbox.
    #
    # ITS OWN CAPABILITY, by ruling ("New 'manage_notifications' cap"): a rule
    # can write to people taken from data, which is a different decision from
    # mailing the form's owner or storing a row.
    notify => {
        label  => 'Notify people',
        cap    => 'manage_notifications',
        schema => [
            { key => 'recipients', label => 'Recipients', type => 'text', required => 1,
                max_len => 4000,
                note => 'A JSON list of sources: {"accounts":[...]}, {"owners_of":{"table":..,'
                    . '"where":{column: field}}}, {"addresses_from":{"table":..,"column":..,'
                    . '"where":{..}}}, {"fixed":[addresses]}, {"submitter":"account"} or '
                    . '{"submitter":{"field":..}}. A where whose field the event lacks '
                    . 'matches nobody. Whether a recipient may be written to is the '
                    . 'operator\'s responsibility; the engine sends one message to each '
                    . 'address, once.' },
            { key => 'channels', label => 'Channels', type => 'text', default => 'email',
                note => 'email, bell, or both (comma separated). The bell reaches accounts '
                    . 'only, each seeing their own.' },
            { key => 'template', label => 'Template', type => 'text',
                note => 'A name: lazysite/notify-templates/<name>.email.tt (a first line '
                    . '"Subject: ..." then the body) and <name>.bell.tt. Blank uses the '
                    . 'built-in message listing the event\'s fields.' },
            { key => 'from', label => 'From address', type => 'email',
                note => 'Blank uses the Form SMTP extension\'s default.' },
            { key => 'notify_actor', label => 'Also notify whoever caused the event',
                type => 'boolean', default => 'false',
                note => 'Off: the account that submitted the form is left out, even when it '
                    . 'is a recipient (a commenter is not told about their own comment).' },
            { key => 'per_recipient_hour', label => 'Cap: messages to one recipient per hour',
                type => 'number', default => '3',
                note => 'Counted per recipient for this rule, on every channel. Past it, the '
                    . 'events are held and sent as one message when the hour moves on.' },
            { key => 'unsubscribe', label => 'Unsubscribe link', type => 'boolean',
                default => 'true',
                note => 'On: every email carries a one-click link that stops this rule '
                    . 'writing to that recipient, with no sign-in, and List-Unsubscribe '
                    . 'headers (RFC 8058).' },
            { key => 'unsubscribe_path', label => 'Subscriptions page', type => 'text',
                note => 'Optional: a path on this site (/account/following) where a recipient '
                    . 'manages what they follow, linked beside the one-click link.' },
        ],
        note => 'Queued, and sent by the scheduler\'s notify-outbox job - the site must run '
            . 'the daemon. Quarantined submissions notify nobody.',
    },

    # SM747 CU: AN ODOO BINDING - a named OOM operation, run as the site's
    # connection user (the Odoo extension's config), with what a request may set
    # and who may cause it. The parsing and the safety rules are
    # Lazysite::Odoo::Binding's; the call is Lazysite::Odoo::call's. Configuring
    # one is manage_connectors' until slice E brings manage_odoo (OM3): it is
    # authority over where site data goes, which is that capability's.
    odoo => {
        label  => 'Run an Odoo operation',
        cap    => 'manage_connectors',
        schema => [
            { key => 'operation', label => 'Operation', type => 'text', required => 1,
                note => 'The name of an installed OOM operation, such as pack.action. What '
                    . 'it may touch in Odoo is its own declared scope and the connection '
                    . 'user\'s rights in Odoo.' },
            { key => 'params', label => 'Parameters from the request', type => 'text',
                max_len => 4000,
                note => 'field=parameter, comma separated. Only these come from a visitor, '
                    . 'and only into plain-value parameters; anything else the request '
                    . 'sends is refused at the page endpoint and dropped from a form.' },
            { key => 'fixed', label => 'Fixed parameters', type => 'text', max_len => 4000,
                note => 'parameter=value, comma separated. Set here and never by a request.' },
            { key => 'visitor_param', label => 'Visitor parameter', type => 'text',
                note => 'The parameter that receives the visitor\'s own key (a basket, say). '
                    . 'The server mints the key; a visitor cannot choose or see another\'s.' },
            { key => 'modes', label => 'Who may run it', type => 'text',
                default => 'authenticated',
                note => 'Comma separated: authenticated (a signed-in account in the caller '
                    . 'groups), public (any visitor - opt in deliberately), scheduled.' },
            { key => 'callers', label => 'Caller groups', type => 'text',
                note => 'Groups whose signed-in members may run it in authenticated mode.' },
            { key => 'apply', label => 'Applying a change', type => 'text', default => 'confirm',
                note => 'confirm: a write operation\'s plan is shown and applied when its '
                    . 'maker confirms it. immediate: applied in the same request, with '
                    . 'nobody confirming - the ruled basket case (Q1). Odoo\'s rights for '
                    . 'the connection user still bound what it can do.' },
            { key => 'credential', label => 'Whose Odoo account runs it', type => 'text',
                default => 'connection',
                note => 'connection: the connection user. session: the person signed in '
                    . 'to Odoo through the page, with their own Odoo rights; the binding is '
                    . 'authenticated mode only, names no callers, and is never run by a page '
                    . 'render, a form, the schedule or an agent.' },
            { key => 'signin_addresses', label => 'Session binding: only from (address lists)', type => 'text',
                note => 'Optional, session bindings only: names of ALLOW address lists, comma '
                    . 'separated. A call of this binding from any other address is refused. It can '
                    . 'only narrow the site\'s signin_addresses, never widen it.' },
            { key => 'signin_addresses_deny', label => 'Session binding: never from (address lists)', type => 'text',
                note => 'Optional, session bindings only: names of DENY address lists. A call of '
                    . 'this binding from one of these addresses is refused.' },
            { key => 'rows_max', label => 'Cap: rows in a list a request gives', type => 'number',
                note => 'Optional. A parameter the operation declares as a list of rows has a cap '
                    . 'of its own; this can only lower it, for this binding.' },
            # SM1162: a binding that takes a file from a multipart request.
            { key => 'file_params', label => 'Files from the request', type => 'text',
                max_len => 4000,
                note => 'field=parameter, comma separated: a request file field mapped to a '
                    . 'parameter the operation declares as a file or a list of files (or to a '
                    . 'set.<field> of a binary field). Needs file_max_kb.' },
            { key => 'file_max_kb', label => 'Cap: size of one file (KB)', type => 'number',
                note => 'Required when files are mapped. A whole number, at most the operation\'s '
                    . 'own max_bytes and the endpoint\'s ceiling. A request larger than this is '
                    . 'refused before it is read.' },
            { key => 'file_types', label => 'Types of file accepted', type => 'text',
                note => 'Optional: type/subtype names, comma separated, such as '
                    . 'image/jpeg,image/png,application/pdf. The type is read from the file\'s '
                    . 'bytes, never taken from the browser. Empty: any type.' },
            # SM1173: NO schema default - a default here is saved into the binding
            # and would pin a read to the write numbers. Empty stands for the
            # default of what the binding does.
            { key => 'rate_per_visitor_hour', label => 'Cap: runs per visitor per hour',
                type => 'number',
                note => 'Leave empty for the default: 2000 for a read, 20 for a write. A number here replaces it, higher or lower.' },
            { key => 'rate_per_hour', label => 'Cap: runs of this binding per hour',
                type => 'number',
                note => 'Leave empty for the default: 20000 for a read, 200 for a write. A number here replaces it, higher or lower.' },
        ],
        note => 'Needs the Odoo extension enabled and configured, with the connection '
            . 'user\'s API key set.',
    },
);

# Form names a form may not take, because the file beside it is not a form.
our %RESERVED_FORM = map { $_ => 1 } qw(handlers smtp schedule);

# The schedule's floor, in seconds: the scheduler ticks its job every 300s, and
# an entry asking for less would be told it ran every minute while it did not.
our $SCHEDULE_FLOOR = 300;

sub is_reserved_form { return $RESERVED_FORM{ $_[0] // '' } ? 1 : 0 }

sub types { return [ map { { type => $_, %{ $TYPES{$_} } } } @TYPE_ORDER ] }

sub cap_for_type {
    my ($type) = @_;
    return undef unless defined $type && $TYPES{$type};
    return $TYPES{$type}{cap};
}

# The capabilities that admit a caller to the handler actions at all. The
# destination then decides; this is only the door.
sub door_caps { my %s; return [ grep { !$s{$_}++ } map { $TYPES{$_}{cap} } @TYPE_ORDER ] }

sub valid_id { return defined $_[0] && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/ }

sub enabled {
    my ($h) = @_;
    return ( ( $h->{enabled} // 'true' ) =~ /\A\s*(?:false|no|off|0)\s*\z/i ) ? 0 : 1;
}

# --- where things are --------------------------------------------------------

sub _lz {
    my $lz = Lazysite::Paths::lazysite_dir($DOCROOT);
    return ( defined $lz && length $lz ) ? $lz : undef;
}
sub forms_dir     { my $lz = _lz();       return defined $lz ? "$lz/forms"       : undef }
sub handlers_file { my $d  = forms_dir(); return defined $d ? "$d/handlers.conf" : undef }
sub schedule_file { my $d  = forms_dir(); return defined $d ? "$d/schedule.conf" : undef }
sub form_file     { my $d  = forms_dir(); return defined $d ? "$d/$_[0].conf"    : undef }

# SM877: THE COUNTER FOR MAIL THIS SITE SENDS TO ADDRESSES IT WAS GIVEN.
#
# It holds a timestamp and a HASH of the recipient, never the address. Two
# reasons, and the second is the one that matters: a counter needs to know
# "this one again", not who; and a file of every address a site has ever
# acknowledged is a mailing list, which is not what anybody agreed to when they
# filled in a form. The hash is enough to count and useless to mail.
#
# It lives under lazysite/forms/, which Lazysite::Stores already classifies as a
# store with this module as its reader - so no new catalogue entry, and the
# four-state rule already applies here.
#
# It sits BELOW the aligned block above rather than inside it: a multi-line sub
# dropped in the middle of those one-liners breaks the column perltidy aligns
# them on, and four untouched lines would have re-flowed to pay for one new one.
sub submitter_mail_file {
    my $d = forms_dir();
    return defined $d ? "$d/submitter-mail.jsonl" : undef;
}

# Where a file handler's store is. A path under lazysite/ is in the ENGINE tree,
# which is not always inside the docroot (SM293 moves it beside it); an absolute
# path is an operator's own choice on a shell and is taken as written.
#
# Anything else is in the SITE's tree, and is resolved as every other write to
# that tree is (SM852): a store inside a protected section is in the private
# store, with its section. Built as "$DOCROOT/$r", the next submission made a
# public copy of the gated folder and appended the visitor's data there - and a
# public folder at a gated path then pulled every later write under it out of
# the store too. The readers call this as well, so they find what was written.
sub store_path {
    my ($rel) = @_;
    $rel = 'lazysite/forms/submissions' unless defined $rel && length $rel;
    return $rel if $rel =~ m{\A/};
    ( my $r = $rel ) =~ s{/+\z}{};
    if ( $r =~ m{\Alazysite(?:/(.*))?\z} ) {
        my $tail = $1;
        my $lz   = _lz() // return undef;    # no docroot: nowhere to put it
        return defined $tail && length $tail ? "$lz/$tail" : $lz;
    }
    require Lazysite::Private;
    my ($abs) = Lazysite::Private::resolve_for_write( $DOCROOT, $r );
    return $abs // "$DOCROOT/$r";
}

# SM855: WHERE THIS FORM'S SUBMISSIONS ARE - one answer, for every reader.
#
# A form's store is not "the default directory": it is the path of the file
# handler the form is bound to, and that handler may name its own (`path:`). The
# control API's form-list worked this out inline, and MCP's read_form_submissions
# did not - it built "lazysite/forms/submissions/<form>.jsonl" and answered
# `ok: true, total: 0` for a store it had not looked at, naming a file that was
# not the store. The site agent found it with a row sitting in the real one.
#
# Returns the absolute .jsonl path, or undef when there is no docroot to resolve
# against. A form with no file handler has no store, and that is said by
# returning the DEFAULT location, which the caller then finds absent - the same
# answer as a form that has simply had no submissions.
# The store DIRECTORY as configured - relative, as handlers.conf writes it.
# Readers that confine a path (the submissions readers check it against the
# configured stores) need the relative form; form_store_file below resolves it.
sub form_store_dir {
    my ($form) = @_;
    my $dir = 'lazysite/forms/submissions';
    return $dir unless defined $form && length $form;
    my $fc = form_file($form);
    if ( defined $fc && -f $fc ) {
        my $text = _slurp( $fc, "form $form" );
        if ( defined $text ) {
            my ($ids) = parse_form_conf($text);
            my $list = read_handlers() || [];
            for my $id ( @{ $ids || [] } ) {
                my $h = find_handler( $list, $id ) or next;
                next unless ( $h->{type} // 'file' ) eq 'file';
                $dir = $h->{path} if defined $h->{path} && length $h->{path};
                last;
            }
        }
    }
    return $dir;
}

sub form_store_file {
    my ($form) = @_;
    return undef unless defined $form && length $form;
    my $abs = store_path( form_store_dir($form) ) // return undef;
    return "$abs/$form.jsonl";
}

# --- the one parser ----------------------------------------------------------
#
# The file shape is the one sysops have always hand-written, so it is read
# leniently about indentation and strictly about everything else:
#
#   handlers:
#     - id: enquiries
#       type: table
#       table: enquiries
#
# A record starts at a list item naming `id:`; every indented `key: value` after
# it belongs to it. An empty value is an absent key. Comments are skipped.
sub parse_records {
    my ($text) = @_;
    my ( @out, $cur );
    for my $line ( split /\r?\n/, ( $text // '' ) ) {
        next if $line =~ /\A\s*(?:#|\z)/;
        if ( $line =~ /\A[ \t]*-[ \t]+id[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) {
            $cur = { id => $1 };
            push @out, $cur;
            next;
        }
        if ( $cur && $line =~ /\A[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
            $cur->{$1} = $2 if length $2;
            next;
        }
        undef $cur if $line =~ /\A\S/;    # a new top-level key ends the list
    }
    return \@out;
}

sub render_records {
    my ( $top, $records, $head ) = @_;
    my $out = $head // '';
    $out .= "$top:\n";
    for my $r (@$records) {
        $out .= "  - id: $r->{id}\n";
        for my $k ( _key_order($r) ) {
            my $v = $r->{$k};
            next unless defined $v && length $v;
            $out .= "    $k: $v\n";
        }
    }
    return $out;
}

sub _key_order {
    my ($r)   = @_;
    my @first = grep { exists $r->{$_} } qw(type name enabled handler every);
    my %f     = map  { $_ => 1 } @first, 'id';
    return ( @first, sort grep { !$f{$_} } keys %$r );
}

# Read a file the SM766 way: absent is empty (''), unopenable is undef.
sub _slurp {
    my ( $path, $what ) = @_;
    return undef unless defined $path;
    open my $fh, '<:utf8', $path or return $!{ENOENT} ? '' : cannot_read( $what, $path );
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

# Temp and rename, the existing mode carried across; a new file is group
# writable, because the manager (the web server's user) and the CLI (the site
# owner) both write it.
sub _write_text {
    my ( $path, $text ) = @_;
    return ( 0, 'no docroot: nowhere to write' ) unless defined $path;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:utf8', $tmp or return ( 0, _cannot_write($path) );
    my $ok = print {$fh} $text;
    unless ( close($fh) && $ok ) { unlink $tmp; return ( 0, _cannot_write($path) ) }
    my @st = stat $path;
    chmod( ( @st ? $st[2] & 07777 : 0664 ), $tmp );
    unless ( rename $tmp, $path ) { unlink $tmp; return ( 0, _cannot_write($path) ) }
    return ( 1, '' );
}

sub _cannot_write {
    my ($path) = @_;
    my $err    = "$!";
    my ($who)  = getpwuid($>);
    ( my $leaf = $path ) =~ s{.*/}{};
    return "cannot write forms/$leaf: $err (unix user " . ( $who // $> ) . ')';
}

sub _unreadable {
    my ($leaf) = @_;
    my ($who)  = getpwuid($>);
    return "forms/$leaf exists but cannot be opened by this process (unix user "
        . ( $who // $> ) . ') - see the event log';
}

# --- handlers ----------------------------------------------------------------

# Every handler, in file order. undef when the file exists and cannot be read.
sub read_handlers {
    my $path = handlers_file();
    unless ( defined $path ) {
        log_event( 'WARN', 'handlers', 'no docroot: cannot locate handlers.conf' );
        return undef;
    }
    my $text = _slurp( $path, 'handlers.conf' );
    return undef unless defined $text;
    return parse_records($text);
}

sub write_handlers {
    my ($list) = @_;
    return _write_text( handlers_file(),
        render_records( 'handlers', $list,
            "# Delivery handlers - named functions a form or the schedule calls.\n"
                . "# Written by the manager, the control API, MCP and lazysite-handlers.pl.\n\n" ) );
}

sub find_handler {
    my ( $list, $id ) = @_;
    my ($h) = grep { defined $_->{id} && $_->{id} eq $id } @{ $list || [] };
    return $h;
}

# --- form bindings -----------------------------------------------------------
#
# A form's config is lazysite/forms/<form>.conf. Its `targets:` list names
# handlers and nothing else:
#
#   targets:
#     - handler: enquiries
#
# The other keys in the file (upload limits, rate_limit, quarantine and the
# rest) belong to the submission path and are carried through a rewrite
# untouched - bind_form used to rewrite the whole file with one target and
# dropped them.

sub valid_form_name {
    my ($f) = @_;
    return defined $f && $f =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/ && !$RESERVED_FORM{$f};
}

# ( \@handler_ids, \@inline_entries, \@other_lines ). An inline entry is any
# list item under targets: that is not `handler: <id>` - read so a check can
# report it and the conversion can convert it, and never delivered.
sub parse_form_conf {
    my ($text) = @_;
    my ( @ids, @inline, @other );
    my ( $in_targets, $cur ) = ( 0, undef );
    for my $line ( split /\r?\n/, ( $text // '' ) ) {
        if ( $line =~ /\Atargets[ \t]*:[ \t]*\z/ ) { $in_targets = 1; undef $cur; next }
        if ($in_targets) {
            if ( $line =~ /\A[ \t]*-[ \t]+handler[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) {
                push @ids, $1;
                undef $cur;
                next;
            }
            if ( $line =~ /\A[ \t]*-[ \t]+([A-Za-z_]\w*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
                $cur = { $1 => $2 };
                push @inline, $cur;
                next;
            }
            if ( $line =~ /\A[ \t]+([A-Za-z_]\w*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ && $cur ) {
                $cur->{$1} = $2;
                next;
            }
            next            if $line =~ /\A\s*\z/;
            $in_targets = 0 if $line =~ /\A\S/;
            next            if $in_targets;
        }
        push @other, $line;
    }
    return ( \@ids, \@inline, \@other );
}

sub render_form_conf {
    my ( $ids, $other ) = @_;
    my $out = "targets:\n";
    $out .= "  - handler: $_\n" for @$ids;
    my @rest = @{ $other || [] };
    shift @rest while @rest && $rest[0] =~ /\A\s*\z/;
    $out .= join( "\n", @rest ) . "\n" if @rest;
    return $out;
}

# The names of every configured form. undef when the directory cannot be read.
sub form_names {
    my $dir = forms_dir() // return undef;
    opendir my $dh, $dir or return $!{ENOENT} ? [] : cannot_read( 'the forms directory', $dir );
    my @n = sort grep { valid_form_name($_) } map { /\A(.+)\.conf\z/ ? $1 : () } readdir $dh;
    closedir $dh;
    return \@n;
}

# { form => [handler ids] } for every form, or undef when unreadable.
sub bindings {
    my $names = form_names() // return undef;
    my %b;
    for my $f (@$names) {
        my $t = _slurp( form_file($f), "forms/$f.conf" );
        return undef unless defined $t;
        my ($ids) = parse_form_conf($t);
        $b{$f} = $ids;
    }
    return \%b;
}

# What is wrong with a form config's text, as sentences - [] when nothing is.
# The WebDAV surface refuses a PUT that has any, so a hand-written config meets
# the same rules as one the binding actions write.
sub form_conf_problems {
    my ($text) = @_;
    my ( $ids, $inline ) = parse_form_conf($text);
    my @p;
    for my $e (@$inline) {
        my ($k) = keys %$e;
        push @p, "targets: '- $k: ...' is not a handler reference - a form's targets name "
            . 'handlers only (- handler: <id>); create the handler first';
    }
    my $all = read_handlers();
    if ( defined $all ) {
        for my $id (@$ids) {
            push @p, "targets: no handler '$id' - the configured handlers are: "
                . ( join( ', ', map { $_->{id} } @$all ) || 'none' )
                unless find_handler( $all, $id );
        }
    }
    return \@p;
}

# --- the schedule ------------------------------------------------------------
#
#   schedule:
#     - id: nightly-export
#       handler: crm
#       every: 86400
#       enabled: true
#       payload: {"source":"timer"}
#
# `payload` is a flat JSON object on one line: the fields the handler is
# called with, fixed in configuration, so nothing a visitor sends ever reaches
# a scheduled call.

sub read_schedule {
    my $path = schedule_file();
    unless ( defined $path ) {
        log_event( 'WARN', 'handlers', 'no docroot: cannot locate schedule.conf' );
        return undef;
    }
    my $text = _slurp( $path, 'schedule.conf' );
    return undef unless defined $text;
    my $list = parse_records($text);
    for my $e (@$list) {
        my $raw = $e->{payload};
        my $p = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
        if ( ref $p eq 'HASH' ) { $e->{payload} = $p }
        else {
            $e->{payload} = {};
            $e->{invalid} = 'payload is not a JSON object';
        }
    }
    return $list;
}

sub write_schedule {
    my ($list) = @_;
    my @rows = map {
        my %r = %$_;
        delete $r{invalid};
        $r{payload} = JSON::PP->new->canonical->encode( $r{payload} || {} );
        \%r;
    } @$list;
    return _write_text( schedule_file(),
        render_records( 'schedule', \@rows,
            "# The schedule - which handler the timer calls, how often, with what.\n\n" ) );
}

# --- who uses what -----------------------------------------------------------

sub used_by {
    my ( $id, $bindings, $schedule ) = @_;
    return {
        forms => [ sort grep { grep { $_ eq $id } @{ $bindings->{$_} } } keys %{ $bindings || {} } ],
        schedule => [ map { $_->{id} } grep { ( $_->{handler} // '' ) eq $id } @{ $schedule || [] } ],
    };
}

# --- authority ---------------------------------------------------------------
#
# $who is { caps => {...} } for a caller the capability model governs, or
# { unconstrained => 1 } for the shell, which is the operator (the users tool
# and the ACL tool act the same way). Returns '' when allowed, else the sentence.
sub _may {
    my ( $who, $cap, $what ) = @_;
    return '' if $who->{unconstrained};
    return '' if defined $cap && ( $who->{caps} || {} )->{$cap};
    return "$what needs the '$cap' permission - the destination decides who may configure "
        . 'it. An administrator can grant it on the Groups page.';
}

# --- validation --------------------------------------------------------------

sub _declared_tables {
    my @t = eval {
        require Lazysite::Data::Tables;
        @{ Lazysite::Data::Tables::list_tables($DOCROOT) || [] };
    };
    return \@t;
}

sub _connector_store {
    my $all = eval {
        require Lazysite::Manager::Connectors;
        no warnings 'once';
        local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
        Lazysite::Manager::Connectors::connectors();
    };
    return $all;    # undef: cannot tell
}

sub _check_path {
    my ($p) = @_;
    return 'path must be relative to the site'        if $p =~ m{\A/};
    return 'path must not step outside the site (..)' if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 'path must not contain a newline'          if $p =~ /[\r\n]/;
    require Lazysite::Manager::Common;
    ( my $n = $p ) =~ s{/+\z}{};
    return "path '$p' is in an engine-owned area - a store may be under lazysite/forms/ or "
        . 'in the site\'s own tree'
        if Lazysite::Manager::Common::path_is_reserved($n)
        && $n !~ m{\Alazysite/forms(?:/|\z)};
    return '';
}

# The field mapping, parsed. ( \%form_to_column, '' ) or ( undef, why ).
sub parse_fields {
    my ($map) = @_;
    my %m;
    for my $pair ( split /\s*,\s*/, ( $map // '' ) ) {
        next unless length $pair;
        my ( $from, $to ) = split /\s*=\s*/, $pair, 2;
        return ( undef, "fields: '$pair' is not field=column" )
            unless defined $to && length $from && length $to;
        return ( undef, "fields: '$to' is not a column name" )
            unless $to =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        return ( undef, "fields: '$from' is not a form field name" )
            unless $from =~ /\A[A-Za-z][A-Za-z0-9_.~-]{0,127}\z/;
        $m{$from} = $to;
    }
    return ( undef, 'fields must map at least one form field to a column' ) unless %m;
    return ( \%m,   '' );
}

# A record, validated against its type. ( \%clean, '' ) or ( undef, why ).
# `field` travels with a refusal so a surface can put the message beside the
# input it is about.
sub validate_handler {
    my ($in) = @_;
    return ( undef, 'a handler is required', 'id' ) unless ref $in eq 'HASH';
    my $id = $in->{id};
    return ( undef, 'id is required', 'id' ) unless defined $id && length $id;
    return ( undef, "id '$id' must be letters, digits, - or _ (at most 64)", 'id' )
        unless valid_id($id);
    my $type = $in->{type};
    return ( undef, 'type is required - one of: ' . join( ', ', @TYPE_ORDER ), 'type' )
        unless defined $type && length $type;
    return ( undef,
        "there is no '$type' handler any more: outbound HTTP goes through a connector (SM842). "
            . 'Create the connector with the URL on the Connectors page, then a handler of type '
            . "'connector' naming it.", 'type' )
        if $type eq 'webhook' || $type eq 'api';
    return ( undef, "there is no 'db' handler any more: use type 'table' with keep_copy: false (SM842)",
        'type' )
        if $type eq 'db';
    my $def = $TYPES{$type}
        or return ( undef, "no handler type '$type' - the types are: " . join( ', ', @TYPE_ORDER ),
        'type' );

    my %declared = map { $_->{key} => $_ } @{ $def->{schema} };
    my @unknown  = sort grep {
        !$declared{$_} && !/\A(?:id|type|name|enabled|domain|csrf_token)\z/
    } keys %$in;
    return ( undef,
        "a $type handler does not take: " . join( ', ', @unknown )
            . '. It takes: name, enabled, ' . join( ', ', map { $_->{key} } @{ $def->{schema} } ),
        $unknown[0] )
        if @unknown;

    my %out  = ( id => $id, type => $type );
    my $name = $in->{name} // '';
    return ( undef, 'name is required', 'name' ) unless length $name;
    return ( undef, 'name must be one line of at most 80 characters', 'name' )
        if $name =~ /[\r\n]/ || length $name > 80;
    $out{name}    = $name;
    $out{enabled} = _bool( $in->{enabled} // 'true' );

    # SM1051 (P-4): `domain` binds the handler to one configured domain - its
    # editors may create, change and delete it, and its forms bind it
    # (Manager::Common::handler_reach_refusal). Absent or empty is an instance
    # handler, as every handler was. A host, as list_domains names it.
    my $dom = $in->{domain};
    return ( undef, 'domain must be a single value', 'domain' ) if ref $dom;
    if ( defined $dom && length $dom ) {
        $dom = lc $dom;
        return ( undef, "domain '$dom' is not a host name - give a domain as list_domains names it",
            'domain' )
            unless $dom =~ /\A [a-z0-9] [a-z0-9-]{0,62} (?: \. [a-z0-9] [a-z0-9-]{0,62} )* \z/x;
        $out{domain} = $dom;
    }

    for my $f ( @{ $def->{schema} } ) {
        my $k = $f->{key};
        my $v = $in->{$k};
        $v = "$v" if defined $v && !ref $v;
        return ( undef, "$k must be a single value", $k ) if ref $v;
        if ( !defined $v || !length $v ) {
            if ( defined $f->{default} && length $f->{default} ) { $v = $f->{default} }
            elsif ( $f->{required} ) { return ( undef, "$k is required for a $type handler", $k ) }
            else                     { next }
        }
        return ( undef, "$k must be one line", $k ) if $v =~ /[\r\n]/;

        # SM923: THE BOUND IS PER FIELD, because one of them was binding something
        # worth binding. 500 characters is a sensible bound for a path, an address
        # or a table name and was the wrong bound for a field MAP: at 31 fields it
        # left about sixteen characters per `field=column` pair, so an operator
        # building a long form had to abbreviate column names until they no longer
        # matched the field names on their own form - and then hold the mapping in
        # their head when reading the table.
        #
        # RULED 2026-10-01, amending the 2026-09-30 ruling on measurement: the map
        # stays REQUIRED and the cap moves. The original ruling was to default the
        # map to identity, which would have made it optional - and measuring what
        # reaches a handler showed the map is also the FILTER. `_visible_fields`
        # strips only `_`-prefixed keys, so every other key a visitor posts arrives
        # here; with an explicit map an undeclared key is dropped, and under an
        # identity default it would write a column of its own name. The schema note
        # below says the map is "what keeps a visitor from choosing where their data
        # goes", and that is literally true, so it is the cap that gives way.
        my $max = $f->{max_len} // 500;
        return ( undef, "$k is longer than $max characters", $k ) if length $v > $max;
        if    ( $f->{type} eq 'boolean' ) { $v = _bool($v) }
        elsif ( $f->{type} eq 'email' ) {
            # SM1017: the one definition, so a handler's own `to` cannot name two
            # recipients either.
            require Lazysite::Mail;
            my ( $one, $bad ) = Lazysite::Mail::one_address($v);
            return ( undef, "$k must be an email address - $bad", $k ) unless defined $one;
        }
        elsif ( $f->{type} eq 'table' ) {
            return ( undef, "$k must be a table name", $k ) unless $v =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        }
        elsif ( $f->{type} eq 'connector' ) {
            return ( undef, "$k must be a connector id", $k )
                unless $v =~ /\A[a-z0-9][a-z0-9_-]{0,63}\z/;
        }
        $out{$k} = $v;
    }

    if ( $type eq 'file' ) {
        my $why = _check_path( $out{path} );
        return ( undef, $why, 'path' ) if length $why;
    }
    if ( $type eq 'table' ) {
        my ( $m, $why ) = parse_fields( $out{fields} );
        return ( undef, $why, 'fields' ) unless $m;
        # SM857 q4: THE VOCABULARY IS THE STORE'S, not a second copy of it. A
        # misspelt policy stored here would reach the row as a value nothing
        # recognises, and Data::Value refuses it at the visitor's submission -
        # the wrong place to find out, for SM807's reason.
        #
        # REQUIRED LAZILY, like every other reach into the data layer from this
        # file: Handlers.pm must not load it at compile time, or a site with the
        # extension switched off pays for it on every form post. And if it cannot
        # be loaded the check does not refuse - unvalidated is not invalid, which
        # is the rule _destination_problem states for the same situation.
        if ( defined $out{row_policy} && length $out{row_policy} ) {
            my $ok = eval { require Lazysite::Data::Owned; 1 };
            if ( $ok && !Lazysite::Data::Owned::valid_policy( $out{row_policy} ) ) {
                return ( undef,
                    'row_policy must be one of: '
                        . join( ', ', Lazysite::Data::Owned::POLICIES() )
                        . " - '$out{row_policy}' is not one of them. Leave it blank for "
                        . 'shared, which is what a table without policies does.',
                    'row_policy' );
            }
        }
    }
    if ( $type eq 'notify' ) {
        my ( $p, $field, $why ) = _notify_problem( \%out );
        return ( undef, $why, $field ) if length $why;
    }
    if ( $type eq 'odoo' ) {
        # The shape, in the one parser the call uses - so what is saved is what
        # will run. Whether the operation exists is _destination_problem's.
        require Lazysite::Odoo::Binding;
        my ( $b, $why, $field ) = Lazysite::Odoo::Binding::parse( \%out );
        return ( undef, $why, $field ) unless $b;
    }
    return ( \%out, '' );
}

# SM1019: what a notify handler's own settings say wrong, as ( undef, field,
# why ) - checked at save, for SM807's reason (a rule that cannot work is found
# by its author, not by the first event).
sub _notify_problem {
    my ($h) = @_;
    require Lazysite::Outbox;
    my ( $src, $why ) = Lazysite::Outbox::parse_recipients( $h->{recipients} );
    return ( undef, 'recipients', $why ) unless $src;
    # The account that caused the event is left out unless the rule says
    # notify_actor, so a source that names exactly that account and nothing
    # else would be refused at every send - said here instead.
    return ( undef, 'recipients',
        '{"submitter":"account"} writes to whoever caused the event, which this rule leaves '
            . 'out - set notify_actor: true to send it' )
        if ( $h->{notify_actor} // 'false' ) ne 'true'
        && grep { defined $_->{submitter} && !ref $_->{submitter} } @$src;
    my @ch = grep { length } split /\s*,\s*/, lc( $h->{channels} // 'email' );
    return ( undef, 'channels', 'channels must name email, bell or both' )
        if !@ch || grep { !/\A(?:email|bell)\z/ } @ch;
    my %seen;
    $h->{channels} = join ',', grep { !$seen{$_}++ } @ch;
    return ( undef, 'template', 'template must be a name: letters, digits, - or _' )
        if defined $h->{template} && length $h->{template}
        && $h->{template} !~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    return ( undef, 'per_recipient_hour', 'per_recipient_hour must be a whole number, 0 to 1000' )
        unless ( $h->{per_recipient_hour} // '' ) =~ /\A\d{1,4}\z/ && $h->{per_recipient_hour} <= 1000;
    # SM1073 (SM1010 R4): the unsubscribe link is the engine's own one-click
    # link, so a rule no longer needs a page for it; unsubscribe_path, where it
    # is given, is offered beside it as the page to manage subscriptions on.
    if ( defined $h->{unsubscribe_path} && length $h->{unsubscribe_path} ) {
        return ( undef, 'unsubscribe_path', 'unsubscribe_path must be a path starting /' )
            unless $h->{unsubscribe_path} =~ m{\A/(?!/)[A-Za-z0-9._~/%-]*\z};
    }
    return ( $src, '', '' );
}

sub _bool { return ( defined $_[0] && $_[0] =~ /\A\s*(?:false|no|off|0)\s*\z/i ) ? 'false' : 'true' }

# What the destination itself says about the record - checked against the
# live site at save, because saving a mapping that cannot work and failing at
# a visitor's submission is the worst arrangement of the two (SM807). A store
# that cannot be read is NOT a refusal: unvalidated is not invalid.
sub _destination_problem {
    my ($h) = @_;
    # SM1051: a handler's domain is one this instance serves, and not the
    # primary (whose handlers are the instance's). A domain list that cannot be
    # read is not a refusal, for the reason this sub states above.
    if ( defined $h->{domain} && length $h->{domain} ) {
        my $list = eval {
            require Lazysite::Manager::Domains;
            no warnings 'once';
            local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
            Lazysite::Manager::Domains::domains_list();
        };
        if ( ref $list eq 'HASH' && $list->{ok} ) {
            my @hosts = map { lc $_->{host} } grep { !$_->{is_primary} } @{ $list->{domains} || [] };
            return "domain: '$h->{domain}' is not a configured domain - the configured domains are: "
                . ( join( ', ', @hosts ) || 'none' )
                unless grep { $_ eq $h->{domain} } @hosts;
        }
    }
    if ( $h->{type} eq 'table' ) {
        my $tables = _declared_tables();
        return "table: no table '$h->{table}' is declared - the declared tables are: "
            . ( join( ', ', @$tables ) || 'none' )
            if @$tables && !grep { $_ eq $h->{table} } @$tables;
        my $d = eval {
            require Lazysite::Data::Tables;
            Lazysite::Data::Tables::load_table( $DOCROOT, $h->{table} );
        };
        # SM905 U4: a files column that names nothing would be found by the
        # first visitor who attached a photograph, whose row the store would
        # then refuse - so it is checked here, with the mapping, for SM807's
        # reason. The declared column is checked even when `fields` is clean,
        # because the two are written independently.
        my $col = $h->{files_column} // '';
        return 'files_column: the files are stored with the submissions copy, so '
            . '`keep_copy: false` leaves the column pointing at files this site never '
            . 'keeps. Turn the copy on, or clear files_column.'
            if length $col && _bool( $h->{keep_copy} // 'true' ) eq 'false';
        if ( ref $d eq 'HASH' && $d->{ok} && ref $d->{fields} eq 'HASH' ) {
            my ($m) = parse_fields( $h->{fields} );
            my $key = $d->{key} // 'id';
            my @bad = sort grep { !exists $d->{fields}{$_} && $_ ne $key } values %{ $m || {} };
            return "fields: '$h->{table}' has no "
                . ( @bad > 1 ? 'columns ' : 'column ' )
                . join( ', ', @bad )
                . ' - its columns are: '
                . join( ', ', sort( keys %{ $d->{fields} } ) )
                if @bad;
            # The key is checked BEFORE existence, for Data::Value's reason: an
            # auto key is not listed in `fields`, so the existence check would
            # say "no column id" about the one column that certainly exists, and
            # send a sysop looking for a spelling mistake.
            # SM857 q4: a handler declaring `personal` on a table that does not
            # declare row_policy is a declaration the store cannot honour - the
            # column is not there, so the write would be refused at a visitor's
            # submission. Checked here with the mapping, for SM807's reason.
            return "row_policy: '$h->{table}' does not declare row_policy, so its rows "
                . 'cannot belong to anybody - add `row_policy: true` to the table first, '
                . 'or leave this blank and its rows stay shared'
                if ( $h->{row_policy} // '' ) eq 'personal' && !$d->{row_policy};
            return "files_column: '$col' is the key of '$h->{table}' - name a column the row "
                . 'can carry'
                if length $col && $col eq $key;
            return "files_column: '$h->{table}' has no column $col - its columns are: "
                . join( ', ', sort( keys %{ $d->{fields} } ) )
                if length $col && !exists $d->{fields}{$col};
        }
    }
    # SM1019: every table a notify rule reads must be declared, an owners_of
    # table must record who wrote each row (timestamps: true gives it created_by),
    # and an addresses_from column and every where column must exist.
    if ( $h->{type} eq 'notify' ) {
        require Lazysite::Outbox;
        my ($src) = Lazysite::Outbox::parse_recipients( $h->{recipients} );
        my $tables = _declared_tables();
        for my $pair ( @{ Lazysite::Outbox::tables_named($src) } ) {
            my ( $k, $s ) = @$pair;
            return "recipients: $k names no table '$s->{table}' - the declared tables are: "
                . ( join( ', ', @$tables ) || 'none' )
                if @$tables && !grep { $_ eq $s->{table} } @$tables;
            my $d = eval {
                require Lazysite::Data::Tables;
                Lazysite::Data::Tables::load_table( $DOCROOT, $s->{table} );
            };
            next unless ref $d eq 'HASH' && $d->{ok} && ref $d->{fields} eq 'HASH';
            my %cols = ( %{ $d->{fields} }, ( $d->{key} // 'id' ) => 1 );
            $cols{$_} = 1 for eval { require Lazysite::Data::Owned; Lazysite::Data::Owned::owned_columns($d) };
            return "recipients: owners_of '$s->{table}' does not record who wrote its rows - "
                . 'it needs timestamps: true, which gives every row created_by'
                if $k eq 'owners_of' && !$d->{timestamps};
            for my $c ( ( $k eq 'addresses_from' ? $s->{column} : () ), sort keys %{ $s->{where} } ) {
                return "recipients: '$s->{table}' has no column $c - its columns are: "
                    . join( ', ', sort keys %cols )
                    unless $cols{$c};
            }
        }
    }
    if ( $h->{type} eq 'connector' ) {
        my $all = _connector_store();
        return "connector: no connector '$h->{connector}' - the configured connectors are: "
            . ( join( ', ', sort keys %$all ) || 'none' )
            if defined $all && !exists $all->{ $h->{connector} };
    }
    if ( $h->{type} eq 'odoo' ) {
        # SM747: the binding against the operation's OWN declaration, when the
        # registry can be read. OOM absent or the connection unconfigured is NOT
        # a refusal - unvalidated is not invalid - and the call checks again.
        my $problem = eval {
            require Lazysite::Odoo;
            require Lazysite::Odoo::Binding;
            no warnings 'once';
            local $Lazysite::Odoo::DOCROOT = $DOCROOT;
            my ($have) = Lazysite::Odoo::oom_check();
            my ($conn) = $have ? Lazysite::Odoo::connection() : ();
            return '' unless $conn;
            my ($b) = Lazysite::Odoo::Binding::parse($h);
            my ( $class, $why ) = Lazysite::Odoo::operation_class( $conn, $b->{operation} );
            return "operation: $why" unless $class;
            my $w = Lazysite::Odoo::Binding::check_against( $b, $class );
            return "params: $w" if length $w;

            # SM1180: what the request path needs of the operation, kept beside the
            # binding and stamped, so a call that oomd answers loads no OOM.
            Lazysite::Odoo::store_decl( $b->{id}, $class, $b->{operation}, $conn );
            return '';
        };
        return $problem if defined $problem && length $problem;
    }
    return '';
}

# SM913 S4: A FORM'S QUARANTINE STATE, read for the manager.
#
# An operator could not tell from any page whether a public form's quarantine
# was on. The form handler (plugins/form-handler.pl, load_form_conf) is a CGI the
# manager cannot load, so this reads the same four keys with the same defaults;
# t/unit/forms/35 posts through the real handler for every spelling and asserts
# the two agree, so they cannot drift apart unseen.
sub form_quarantine_state {
    my ($text) = @_;
    $text = '' unless defined $text;
    my ($q)  = $text            =~ /^\s*quarantine\h*:\h*(\S+)/m;
    my ($kw) = $text            =~ /^\s*spam_keywords\h*:\h*(.+?)\h*$/m;
    my ($ut) = $text            =~ /^\s*spam_url_threshold\h*:\h*(\d+)/m;
    my ($od) = $text            =~ /^\s*spam_own_domain\h*:\h*(\S+)/m;
    my $on   = lc( $q // 'on' ) =~ /^(?:0|off|no|false|disabled)$/ ? 0 : 1;
    my @kw   = grep { length } split /\s*,\s*/, ( $kw // '' );
    return {
        on            => $on ? JSON::PP::true : JSON::PP::false,
        url_threshold => ( defined $ut ? $ut + 0 : 2 ),
        keywords      => scalar @kw,
        own_domain => ( lc( $od // 'off' ) =~ /^(?:1|on|yes|true)$/ ? JSON::PP::true : JSON::PP::false ),
    };
}

# SM858: WHICH FIELD OF THIS FORM IS THE ADDRESS AN ACCOUNT IS APPROVED FROM.
#
# `account_email: <field>` in a form's conf turns its submissions into account
# requests: the Submissions view offers Approve on a row and the approval reads
# the address from that field. Absent means an ordinary form, and nothing offers
# to approve anything - the flow is opt-in per form.
#
# THE ONE READER. The form handler does not act on this key (it stores fields
# by the names they were posted under), so the manager is its only consumer;
# t/unit/manager/200 posts through the real handler and approves from the row
# it stored, which is what holds the conf's field name to the stored key.
#
# A value that cannot be a field name reads as ABSENT, never as a guess: a
# typo'd declaration offers no button rather than one that reads the wrong
# column. A name starting `_` is the handler's own bookkeeping, never a field.
sub form_account_email {
    my ($text) = @_;
    return '' unless defined $text;
    my ($f) = $text =~ /^\s*account_email\h*:\h*(\S+)\h*$/m;
    return '' unless defined $f && $f =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/;
    return $f;
}

# --- the actions (every surface calls these) ---------------------------------

sub action_handler_list {
    my (%who) = @_;
    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') } unless defined $all;
    my $b = bindings()      // {};
    my $s = read_schedule() // [];

    # SM1010 R5 (ruled 2026-10-12 with SM1034 Q9): manage_notifications opens
    # this door on its own, and the destination rule keeps it to what it may
    # configure. A caller holding none of the three capabilities that opened it
    # before is shown only the handlers whose type it governs (notify), and not
    # the site's form bindings - binding is manage_forms'. A caller who passes no
    # grant (the daemon, the CLI) and every caller who held the door before see
    # the list exactly as they did.
    my $narrow = %who && !$who{unconstrained}
        && !grep { ( $who{caps} || {} )->{$_} } qw(manage_forms manage_data manage_connectors);
    if ($narrow) {
        $all = [ grep { my $c = cap_for_type( $_->{type} ); defined $c && ( $who{caps} || {} )->{$c} } @$all ];
        $b = {};
    }
    # SM1072 (SM1010 R3, Q5 as ruled): a notify rule's row says what its queue
    # holds and what it last did - and "waiting for the scheduler" when the
    # daemon is not taking it. Counts only: who the events go to is the outbox
    # view's, behind manage_notifications.
    my $states;
    if ( grep { ( $_->{type} // '' ) eq 'notify' } @$all ) {
        require Lazysite::Outbox;
        $states = Lazysite::Outbox::rule_states($DOCROOT);
    }
    my @out = map {
        my %h = %$_;
        $h{enabled} = enabled($_) ? JSON::PP::true : JSON::PP::false;
        $h{cap}     = cap_for_type( $h{type} );
        $h{used_by} = used_by( $h{id}, $b, $s );
        $h{problem} = _legacy_problem($_) if length _legacy_problem($_);
        if ( ( $h{type} // '' ) eq 'notify' ) {
            $h{outbox} = defined $states
                ? ( $states->{ $h{id} } // { queued => 0, retrying => 0, failed => 0, held => 0 } )
                : { error => 'the notification outbox could not be read; see the log' };
        }
        \%h;
    } @$all;
    # SM938 D2: where each form's submission notice will be announced, and if
    # an endpoint will not get it, the one thing that says no. Beside `forms`
    # rather than inside it, because `forms` is name => [handler ids] and every
    # caller already reads it as that.
    my ( %notify, %quarantine );
    for my $f ( keys %$b ) {    # SM913 S4
        my $t = _slurp( form_file($f), "forms/$f.conf" );
        $quarantine{$f} = form_quarantine_state($t) if defined $t;
    }
    if ( eval { require Lazysite::Notify; 1 } ) {
        for my $f ( keys %$b ) {
            my $t = _slurp( form_file($f), "forms/$f.conf" );
            next unless defined $t;
            my ($mode) = Lazysite::Notify::form_notify_mode($t);
            $notify{$f} = Lazysite::Notify::route_report( $DOCROOT, 'submission', $mode );
        }
    }

    # Every form and the handlers it calls - the unbound ones included, which
    # used_by cannot show - so a page binding forms needs this one read.
    return { ok => 1, handlers => \@out, types => types(), forms => $b,
        form_notify => \%notify, form_quarantine => \%quarantine };
}

# A record the conversion has not reached yet, said on the listing so it is
# not a silent non-delivery.
sub _legacy_problem {
    my ($h) = @_;
    my $t = $h->{type} // '';
    return '' if $TYPES{$t};
    return "a '$t' handler no longer delivers - run lazysite-handlers.pl convert (SM842)"
        if $t =~ /\A(?:webhook|api|db)\z/;
    return "unknown type '$t'";
}

sub action_handler_save {
    my ( $in, %who ) = @_;
    my ( $h, $why, $field ) = validate_handler($in);
    return { ok => 0, kind => 'invalid', field => $field, error => $why } unless $h;

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was written' }
        unless defined $all;
    my $old = find_handler( $all, $h->{id} );

    # Editing needs authority over what the handler does NOW as well as over
    # what it will do - turning an email handler into a table handler is a
    # change to both destinations.
    my $deny = _may( \%who, cap_for_type( $h->{type} ), "a $h->{type} handler" );
    $deny ||= _may( \%who, cap_for_type( $old->{type} ), "the existing $old->{type} handler '$h->{id}'" )
        if $old && cap_for_type( $old->{type} ) && ( $old->{type} ne $h->{type} );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;

    my $problem = _destination_problem($h);
    return { ok => 0, kind => 'invalid', field => ( $problem =~ /\A(\w+):/ )[0], error => $problem }
        if length $problem;

    if ($old) { %$old = %$h }
    else      { push @$all, $h }
    my ( $ok, $err ) = write_handlers($all);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', ( $old ? 'handler updated' : 'handler created' ),
        handler => $h->{id}, type => $h->{type} );
    return { ok => 1, id => $h->{id}, handler => $h, created => ( $old ? 0 : 1 ) };
}

sub action_handler_delete {
    my ( $id, %who ) = @_;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was deleted' }
        unless defined $all;
    my $h = find_handler( $all, $id )
        or return { ok => 0, kind => 'not-found', error => "no handler '$id'" };
    my $cap  = cap_for_type( $h->{type} ) // 'manage_forms';
    my $deny = _may( \%who, $cap, "deleting a $h->{type} handler" );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;

    # A FUNCTION IN USE IS NOT DELETED. Removing it would leave each form that
    # names it refusing every submission, and each schedule entry failing every
    # interval - both silently until somebody reads the log. Say which.
    my $b = bindings();
    my $s = read_schedule();
    return { ok => 0, error => 'cannot tell whether the handler is in use - a form config or the '
            . 'schedule could not be read; nothing was deleted' }
        unless defined $b && defined $s;
    my $u = used_by( $id, $b, $s );
    if ( @{ $u->{forms} } || @{ $u->{schedule} } ) {
        return { ok => 0, kind => 'in-use', used_by => $u,
            error => "handler '$id' is in use - "
                . join( '; ',
                ( @{ $u->{forms} } ? 'forms: ' . join( ', ', @{ $u->{forms} } ) : () ),
                ( @{ $u->{schedule} } ? 'schedule entries: ' . join( ', ', @{ $u->{schedule} } ) : () ) )
                . '. Unbind or remove those first.' };
    }
    my ( $ok, $err ) = write_handlers( [ grep { $_->{id} ne $id } @$all ] );
    return { ok => 0, error => $err } unless $ok;
    if ( ( $h->{type} // '' ) eq 'odoo' ) { # SM1180: its stored operation declaration goes with it
        eval {
            require Lazysite::Odoo;
            no warnings 'once';
            local $Lazysite::Odoo::DOCROOT = $DOCROOT;
            Lazysite::Odoo::forget_decl($id);
        };
    }
    # SM1093: a notify rule's unsent events go with it (see Outbox::purge_rule).
    # The rule is already gone, so a failed read is said in the result and does
    # not undo the delete.
    my %extra;
    if ( ( $h->{type} // '' ) eq 'notify' ) {
        require Lazysite::Outbox;
        my $n = Lazysite::Outbox::purge_rule( $DOCROOT, $id );
        if ( defined $n ) { $extra{outbox_removed} = $n }
        else {
            $extra{outbox_removed} = 0;
            $extra{warning} = 'the rule is deleted but its queued notifications could not be read; '
                . 'the outbox job clears them on its next run';
        }
    }
    log_event( 'INFO', 'handlers', 'handler deleted', handler => $id,
        ( exists $extra{outbox_removed} ? ( outbox_removed => $extra{outbox_removed} ) : () ) );
    return { ok => 1, id => $id, deleted => $id, %extra };
}

sub action_form_targets_read {
    my ($form) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form', error => "invalid form name '$form'" }
        unless valid_form_name($form);
    my $text = _slurp( form_file($form), "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") } unless defined $text;
    my ( $ids, $inline ) = parse_form_conf($text);
    return { ok => 1, form => $form, targets => [ map { { handler => $_ } } @$ids ],
        handlers => $ids,
        ( @$inline ? ( problem => 'this form has inline targets that no longer deliver - run '
                    . 'lazysite-handlers.pl convert (SM842)' ) : () ) };
}

# Bind a form to handlers by id, replacing its targets. manage_forms is the
# caller's gate; every id must name a handler that exists, and a connector
# handler must be one a form can use.
sub action_form_targets_save {
    my ( $form, $ids ) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form',
        error => "invalid form name '$form'"
            . ( $RESERVED_FORM{$form} ? " - $form.conf is not a form" : '' ) }
        unless valid_form_name($form);
    return { ok => 0, kind => 'invalid', field => 'handlers',
        error => 'handlers must be a list of handler ids' }
        unless ref $ids eq 'ARRAY';
    my @want;
    my %seen;
    for my $t (@$ids) {
        my $id = ref $t eq 'HASH' ? $t->{handler} : $t;
        return { ok => 0, kind => 'invalid', field => 'handlers',
            error => 'a target names a handler by id - inline targets were removed in 0.13.13 '
                . '(SM842): create a handler and bind that' }
            if ref $t eq 'HASH' && !defined $t->{handler};
        return { ok => 0, kind => 'invalid', field => 'handlers', error => 'a handler id is empty' }
            unless defined $id && length $id;
        push @want, $id unless $seen{$id}++;
    }

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was written' }
        unless defined $all;
    for my $id (@want) {
        my $h = find_handler( $all, $id )
            or return { ok => 0, kind => 'not-found', field => 'handlers',
            error => "no handler '$id' - the configured handlers are: "
                . ( join( ', ', map { $_->{id} } @$all ) || 'none' ) };
        my $p = _form_use_problem($h);
        return { ok => 0, kind => 'invalid', field => 'handlers', error => $p } if length $p;
    }

    my $path = form_file($form);
    my $text = _slurp( $path, "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") . '; nothing was written' }
        unless defined $text;
    my ( undef, undef, $other ) = parse_form_conf($text);
    my ( $ok, $err ) = _write_text( $path, render_form_conf( \@want, $other ) );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'form bound', form => $form, handlers => join( ',', @want ) );
    return { ok => 1, form => $form, handlers => \@want, path => "/lazysite/forms/$form.conf" };
}

# SM905 U5: TURNING UPLOADS ON IS A THING SOMEBODY CAN DO OVER THE API.
#
# The form handler reads three keys out of a form's own conf - upload_max_kb,
# upload_max_files, upload_accept - and refuses every upload until at least one
# of them exists, so that a form never accepts files by accident. The only writer
# was form-targets-save, which writes `targets:` and nothing else. So an agent
# building an upload form over the API could create the handler, bind the form,
# render the file input, and then watch every submission be refused with "this
# form does not accept file uploads" and have no action to fix it. Confirmed from
# outside during the 0.15.0 edge walk, which had to hand-write the conf over
# WebDAV to finish the job.
#
# `uploads` is the switch and it is EXPLICIT, rather than inferred from whether
# any limit was passed: turning the feature off by omitting a field is how a
# caller disables something it meant to leave alone.
sub action_form_uploads_save {
    my ( $form, $on, $limits ) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form',
        error => "invalid form name '$form'"
            . ( $RESERVED_FORM{$form} ? " - $form.conf is not a form" : '' ) }
        unless valid_form_name($form);

    # A JSON CLIENT SENDS A JSON BOOLEAN, and the walk found handler-save refusing
    # exactly that for attach_files - "must be a single value" - while wanting the
    # string "true". A new action does not get to repeat that: true, 1, "true",
    # "on" and "yes" all mean on; false, 0, "" and absent all mean off.
    $on = ( defined $on && "$on" =~ /\A(?:1|true|on|yes)\z/i ) ? 1 : 0;

    $limits = {} unless ref $limits eq 'HASH';
    my %write;
    if ($on) {
        # Defaults are the form handler's own, so a caller that says "uploads on"
        # and nothing else gets exactly what an unconfigured form got before.
        my %spec = ( max_kb => 5120, max_files => 5 );
        for my $k ( sort keys %spec ) {
            my $v = $limits->{$k};
            $v = $spec{$k} unless defined $v && length $v;
            return { ok => 0, kind => 'invalid', field => $k,
                error => "$k must be a whole number of "
                    . ( $k eq 'max_kb' ? 'kilobytes' : 'files' ) . ", not '$v'" }
                unless $v =~ /\A\d+\z/ && $v > 0;
            $write{"upload_$k"} = 0 + $v;
        }
        my $accept = $limits->{accept};
        if ( defined $accept && length $accept ) {
            # EXTENSIONS, not media types, and the refusal says so - because the
            # page grammar's `accept:` IS a media-type pattern one page away, and
            # `image/*` here matches nothing while looking correct.
            my @ext = grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $accept;
            return { ok => 0, kind => 'invalid', field => 'accept',
                error => 'upload_accept is a list of file EXTENSIONS matched against the '
                    . "filename - `png, jpg, pdf` - not a media type. '$accept' would "
                    . 'match nothing. (The page grammar\'s `accept:` rule is the '
                    . 'media-type one.)' }
                if grep { m{[/*]} } @ext;
            return { ok => 0, kind => 'invalid', field => 'accept',
                error => 'an extension is letters and digits only' }
                if grep { !/\A[A-Za-z0-9]{1,10}\z/ } @ext;
            $write{upload_accept} = join ', ', @ext;
        }
    }

    my $path = form_file($form);
    my $text = _slurp( $path, "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") . '; nothing was written' }
        unless defined $text;
    my ( $ids, undef, $other ) = parse_form_conf($text);

    # Every upload_* line goes, then the wanted ones are appended. Rewriting in
    # place would keep a stale key that the reader still honours.
    my @rest = grep { !/\A\s*upload_(?:max_kb|max_files|accept)\s*:/ } @{ $other || [] };
    push @rest, map { "$_: $write{$_}" } sort keys %write;

    my ( $ok, $err ) = _write_text( $path, render_form_conf( $ids, \@rest ) );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', ( $on ? 'form uploads enabled' : 'form uploads disabled' ),
        form => $form, %write );
    return { ok => 1, form => $form, uploads => ( $on ? 1 : 0 ), limits => \%write,
        path => "/lazysite/forms/$form.conf" };
}

# SM938 D4 / R17: SET WHAT A FORM ANNOUNCES, FROM THE MANAGER.
#
# D2 made the Handlers page say where a form's notice goes and what stops it; the
# form's own `notify:` was the one deciding place an operator still had to edit
# as text over WebDAV. This writes it - into the form's conf, the text that stays
# the source of truth - and returns D2's report, read back after the write, so the
# caller sees the effect rather than assuming it.
#
# Three values and nothing else: off (no notice), on (one line), full (the notice
# carries the submission, SM928). Anything else is refused naming the three -
# the parse that reads this line treats an unknown value as `on`, so writing one
# would look like it took and change nothing.
sub action_form_notify_save {
    my ( $form, $mode ) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form',
        error => "invalid form name '$form'"
            . ( $RESERVED_FORM{$form} ? " - $form.conf is not a form" : '' ) }
        unless valid_form_name($form);
    $mode = lc( $mode // '' );
    return { ok => 0, kind => 'invalid', field => 'notify',
        error => "notify must be off, on or full, not '$mode'" }
        unless $mode =~ /\A(?:off|on|full)\z/;

    my $path = form_file($form);
    my $text = _slurp( $path, "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") . '; nothing was written' }
        unless defined $text;
    my ( $ids, undef, $other ) = parse_form_conf($text);

    # Every notify: line goes and one is written. The reader takes the FIRST, so
    # an edit in place that left a second behind could be the one that wins.
    my @rest = grep { !/\Anotify\s*:/ } @{ $other || [] };
    push @rest, "notify: $mode";

    my ( $ok, $err ) = _write_text( $path, render_form_conf( $ids, \@rest ) );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'form notify set', form => $form, notify => $mode );

    my %r = ( ok => 1, form => $form, notify => $mode, path => "/lazysite/forms/$form.conf" );
    if ( eval { require Lazysite::Notify; 1 } ) {
        my $again = _slurp( $path, "forms/$form.conf" );
        my ($read) = Lazysite::Notify::form_notify_mode($again);
        $r{announces} = Lazysite::Notify::route_report( $DOCROOT, 'submission', $read );
    }
    return \%r;
}

# Why a form cannot use this handler, or ''. A connector that refuses public
# invocation would refuse every submission, so the binding is refused instead,
# at the moment of the mistake.
sub _form_use_problem {
    my ($h) = @_;
    my $t = $h->{type} // '';
    return "handler '$h->{id}' is a '$t' handler, which no longer delivers - run "
        . 'lazysite-handlers.pl convert (SM842)'
        unless $TYPES{$t};
    if ( $t eq 'connector' ) {
        my $all = _connector_store();
        my $c   = defined $all ? $all->{ $h->{connector} // '' } : undef;
        return "handler '$h->{id}' sends through connector '$h->{connector}', which does not "
            . 'permit public invocation, so it would refuse every submission - set modes.public '
            . 'on the connector first'
            if $c && !( $c->{modes} || {} )->{public};
    }
    return '';
}

sub action_schedule_list {
    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') } unless defined $s;
    my $all = read_handlers() // [];
    my @out = map {
        my %e = %$_;
        my $h = find_handler( $all, $e{handler} // '' );
        $e{enabled}      = enabled($_) ? JSON::PP::true             : JSON::PP::false;
        $e{handler_type} = $h          ? $h->{type}                 : undef;
        $e{cap}          = $h          ? cap_for_type( $h->{type} ) : undef;
        $e{problem}      = "no handler '$e{handler}'" unless $h;
        \%e;
    } @$s;
    return { ok => 1, schedule => \@out, floor => $SCHEDULE_FLOOR };
}

sub action_schedule_save {
    my ( $in, %who ) = @_;
    return { ok => 0, kind => 'invalid', error => 'a schedule entry is required' }
        unless ref $in eq 'HASH';
    my $id = $in->{id};
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    return { ok => 0, kind => 'invalid', field => 'id',
        error => "id '$id' must be letters, digits, - or _ (at most 64)" }
        unless valid_id($id);
    my $hid = $in->{handler};
    return { ok => 0, kind => 'invalid', field => 'handler', error => 'handler is required' }
        unless defined $hid && length $hid;
    my $every = $in->{every};
    return { ok => 0, kind => 'invalid', field => 'every', error => 'every is required (seconds)' }
        unless defined $every && length $every;
    return { ok => 0, kind => 'invalid', field => 'every',
        error => "every must be a whole number of seconds, at least $SCHEDULE_FLOOR" }
        unless $every =~ /\A\d+\z/ && $every >= $SCHEDULE_FLOOR;
    my $payload = $in->{payload} // {};
    if ( !ref $payload && length $payload ) {
        $payload = eval { JSON::PP::decode_json($payload) };
        return { ok => 0, kind => 'invalid', field => 'payload',
            error => 'payload must be a JSON object of fields' }
            unless ref $payload eq 'HASH';
    }
    return { ok => 0, kind => 'invalid', field => 'payload', error => 'payload must be an object of fields' }
        unless ref $payload eq 'HASH';
    return { ok => 0, kind => 'invalid', field => 'payload', error => 'payload names more than 64 fields' }
        if keys %$payload > 64;
    for my $k ( keys %$payload ) {
        return { ok => 0, kind => 'invalid', field => 'payload', error => "payload: '$k' is not a field name" }
            unless $k =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/;
        return { ok => 0, kind => 'invalid', field => 'payload',
            error => "payload: '$k' must be text or a number - a scheduled call carries fixed values only" }
            if ref $payload->{$k};
        $payload->{$k} = defined $payload->{$k} ? "$payload->{$k}" : '';
    }

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') } unless defined $all;
    my $h = find_handler( $all, $hid )
        or return { ok => 0, kind => 'not-found', field => 'handler',
        error => "no handler '$hid' - the configured handlers are: "
            . ( join( ', ', map { $_->{id} } @$all ) || 'none' ) };
    my $cap = cap_for_type( $h->{type} )
        or return { ok => 0, kind => 'invalid', field => 'handler', error => _form_use_problem($h) };
    my $deny = _may( \%who, $cap, "scheduling a $h->{type} handler" );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;
    if ( $h->{type} eq 'connector' ) {
        my $cs = _connector_store();
        my $c  = defined $cs ? $cs->{ $h->{connector} // '' } : undef;
        return { ok => 0, kind => 'invalid', field => 'handler',
            error => "handler '$hid' sends through connector '$h->{connector}', which does not permit "
                . 'scheduled invocation, so the timer would be refused every time - set '
                . 'modes.scheduled on the connector first' }
            if $c && !( $c->{modes} || {} )->{scheduled};
    }

    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was written' }
        unless defined $s;
    my ($old) = grep { $_->{id} eq $id } @$s;
    if ( $old && ( my $oh = find_handler( $all, $old->{handler} // '' ) ) ) {
        my $d2 = _may( \%who, cap_for_type( $oh->{type} ), "changing an entry that schedules a $oh->{type} handler" );
        return { ok => 0, kind => 'forbidden', error => $d2 } if length $d2;
    }
    my %e = ( id => $id, handler => $hid, every => 0 + $every,
        enabled => _bool( $in->{enabled} // 'true' ), payload => $payload );
    if ($old) { %$old = %e }
    else      { push @$s, \%e }
    my ( $ok, $err ) = write_schedule($s);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', ( $old ? 'schedule entry updated' : 'schedule entry created' ),
        entry => $id, handler => $hid, every => $every );
    return { ok => 1, id => $id, entry => \%e, created => ( $old ? 0 : 1 ) };
}

sub action_schedule_delete {
    my ( $id, %who ) = @_;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was deleted' }
        unless defined $s;
    my ($e) = grep { $_->{id} eq $id } @$s;
    return { ok => 0, kind => 'not-found', error => "no schedule entry '$id'" } unless $e;
    my $all = read_handlers() // [];
    my $h   = find_handler( $all, $e->{handler} // '' );
    my $cap = $h ? cap_for_type( $h->{type} ) : undef;
    # An entry naming a handler that is gone is anybody's to clear who may reach
    # the schedule at all - there is no destination left to decide.
    if ($cap) {
        my $deny = _may( \%who, $cap, "removing an entry that schedules a $h->{type} handler" );
        return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;
    }
    my ( $ok, $err ) = write_schedule( [ grep { $_->{id} ne $id } @$s ] );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'schedule entry deleted', entry => $id );
    return { ok => 1, id => $id, deleted => $id };
}

# --- delivery ----------------------------------------------------------------
#
# deliver( $handler_id, \%fields, %ctx ) calls one handler. %ctx:
#
#   origin   'form' or 'timer' - the audit origin, and what the connector is
#            told it is (a form is public invocation, the timer scheduled)
#   source   'form:<name>' or 'timer:<entry>' - named on every record
#   store    the name a file handler files under (<store>.jsonl): the form's
#            name, or the schedule entry's id
#   ip       the submitter's address, when there is one
#   actor    the account the call runs as - blank for a public form, the job
#            account for the timer
#   files    uploads, from a form only
#   quarantined, spam_reason   SM216's flag, carried onto the stored copy
#   handlers a list already read, so a form with three targets reads the file once
#
# Returns { ok, handler, type, why }. Every call is one audit line naming the
# source, the handler and the outcome - never the fields.
sub deliver {
    my ( $id, $fields, %ctx ) = @_;
    $ctx{origin} //= 'form';
    $ctx{source} //= $ctx{origin};
    my $all = $ctx{handlers} // read_handlers();
    my $r;
    if ( !defined $all ) {
        $r = { ok => 0, why => 'handlers.conf could not be read' };
    }
    elsif ( my $h = find_handler( $all, $id ) ) {
        $r = _deliver_one( $h, $fields || {}, \%ctx );
        $r->{type} = $h->{type};
    }
    else {
        $r = { ok => 0, why => "no handler '$id'" };
    }
    $r->{handler} = $id;
    _audit_delivery( $id, $r, \%ctx );
    log_event(
        ( $r->{ok} && !length( $r->{note} // '' ) ? 'INFO' : 'WARN' ),
        'handlers',
        ( $r->{ok} ? 'delivered' : 'not delivered' ),
        handler => $id,
        source  => $ctx{source},
        ( $r->{ok}
            ? ( length( $r->{note} // '' ) ? ( note => $r->{note} ) : () )
            : ( why => $r->{why} // '' ) ) );
    return $r;
}

sub _deliver_one {
    my ( $h, $fields, $ctx ) = @_;
    return { ok => 0, why => "handler '$h->{id}' is switched off" } unless enabled($h);
    my $t = $h->{type} // '';
    return _to_file( $h, $fields, $ctx )      if $t eq 'file';
    return _to_table( $h, $fields, $ctx )     if $t eq 'table';
    return _to_smtp( $h, $fields, $ctx )      if $t eq 'smtp';
    return _to_connector( $h, $fields, $ctx ) if $t eq 'connector';
    return _to_notify( $h, $fields, $ctx )    if $t eq 'notify';
    return _to_odoo( $h, $fields, $ctx )      if $t eq 'odoo';
    return { ok => 0, why => _legacy_problem($h) };
}

# SM747 CU: a form or the timer runs an Odoo binding. A form is PUBLIC - this
# path has no verified actor (SM402) - and the timer is SCHEDULED, exactly as a
# connector is told; the binding's modes decide whether either may.
#
# NEITHER HAS A VISITOR OR ANYBODY TO CONFIRM. A binding that works on a
# visitor's key belongs on a page (the Odoo endpoint mints and checks the key),
# and a write that waits for a confirm would wait for ever - so both are
# refused here by name rather than planned into a void.
sub _to_odoo {
    my ( $h, $fields, $ctx ) = @_;
    require Lazysite::Odoo;
    require Lazysite::Odoo::Binding;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $DOCROOT;
    my ( $b, $why ) = Lazysite::Odoo::Binding::parse($h);
    return { ok => 0, why => "the Odoo binding cannot be used: $why" } unless $b;
    return { ok => 0, why => "the Odoo binding '$b->{id}' works on a visitor's key, which only "
            . 'the Odoo page endpoint carries - bind it on a page, not a form or the schedule' }
        if length $b->{visitor_param};
    return { ok => 0, why => "the Odoo binding '$b->{id}' runs as a person signed in to Odoo, which "
            . 'only the Odoo page endpoint carries - not a form or the schedule' }
        if ( $b->{credential} // '' ) eq 'session';
    return { ok => 0, why => "the Odoo binding '$b->{id}' waits for a confirm, and a form or the "
            . 'schedule has nobody to give one - set apply: immediate on it (Q1)' }
        if $b->{apply} ne 'immediate' && _odoo_writes($b);
    my $r = Lazysite::Odoo::call( $b, { _visible($fields) },
        mode  => ( ( $ctx->{origin} // '' ) eq 'timer' ? 'scheduled' : 'public' ),
        actor => $ctx->{actor} // '',
        ip    => $ctx->{ip}    // '',
        # E-Q1: a form is a request on a host, and a domain's binding runs only
        # there; the timer has no host and runs what the operator scheduled.
        ( ( $ctx->{origin} // '' ) eq 'timer' ? () : ( host => _odoo_host() ) ) );
    return { ok => 1 } if $r->{ok};

    # SM1148 (OOM Lab L-3): APPLIED WITH A WARNING IS DELIVERED. OOM reports an
    # apply as not ok when an invariant on the result failed after the change was
    # made (its O-4: the record WAS made). That reached here as a failure, so a
    # form sent the visitor to outcome=undelivered, they sent it again, and Odoo
    # held a duplicate. It is delivered, with the warning in `note` - which the
    # delivery's audit line carries as its detail and the event log as a WARN
    # (deliver, above) - and the engine's call record already holds the kind. Only
    # a result in which every change that was attempted is done counts: a change
    # that failed, or was never attempted, is not a delivery and keeps its refusal.
    if ( ( $r->{kind} // '' ) eq 'apply-incomplete' && $r->{applied} ) {
        my $c = ( ref $r->{result} eq 'HASH' && ref $r->{result}{counts} eq 'HASH' ) ? $r->{result}{counts} : {};
        return { ok => 1,
            note => 'the change was applied in Odoo, and its checks afterwards reported apply-incomplete - see the Odoo call record' }
            if ( $c->{done} // 0 ) > 0 && !( $c->{failed} // 0 ) && !( $c->{unknown} // 0 ) && !( $c->{not_attempted} // 0 );
    }
    return { ok => 0, why => 'the Odoo operation did not complete: ' . ( $r->{error} // $r->{kind} // 'failed' ) };
}

# The host a form was posted to, as Lazysite::Util reads it (E-Q1).
sub _odoo_host {
    require Lazysite::Util;
    return Lazysite::Util::request_host();
}

# Whether the binding's operation writes - asked of OOM's registry, and treated
# as a WRITE when it cannot be asked, so the refusal above errs closed.
sub _odoo_writes {
    my ($b) = @_;
    my $w = eval { Lazysite::Odoo::writes_of($b) }; # SM1180: the stored declaration with the daemon on
    return defined $w ? $w : 1;
}

sub _audit_delivery {
    my ( $id, $r, $ctx ) = @_;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = _lz();
        # SM877: a delivery that SUCCEEDED may still have something to say - an
        # acknowledgement the cap refused, say. The state stays `ok`, because
        # the delivery did happen and a reader counting failures must not be
        # told otherwise; the detail field, empty until now for a success,
        # carries the note. A partial that appears nowhere is the silence this
        # release spent its time removing.
        Lazysite::Audit::audit_log( $ctx->{actor} // '', 'deliver', "$ctx->{source} -> $id",
            $ctx->{ip} // '', ( $r->{ok} ? 'ok' : 'failed' ), $ctx->{origin},
            ( $r->{ok} ? $r->{note} // '' : $r->{why} // '' ) );
        1;
    };
    return;
}

sub _visible {
    my ($f) = @_;
    return map { ( $_ => $f->{$_} ) } grep { !/\A_/ } sort keys %$f;
}

# A stored submission's id: the first 16 hex characters of the SHA-256 of its
# line as it is on disk (UTF-8 bytes). ONE definition: the file handler names
# the row it just wrote with it (SM938 D5 - the notice links to that row), and
# the submissions readers find a row by it. Two copies would be two ids.
sub submission_row_id {
    my ($line) = @_;
    $line =~ s/\s+\z//;
    utf8::encode($line) if utf8::is_utf8($line);
    require Digest::SHA;
    return substr( Digest::SHA::sha256_hex($line), 0, 16 );
}

sub _store_name {
    my ($ctx) = @_;
    ( my $n = $ctx->{store} // 'unknown' ) =~ s/[^A-Za-z0-9_-]//g;
    return length $n ? $n : 'unknown';
}

sub _to_file {
    my ( $h, $fields, $ctx, $extra ) = @_;
    my $dir = store_path( $h->{path} );
    eval { make_path($dir) unless -d $dir; 1 }
        or return { ok => 0, why => "cannot create the store directory: $@" };
    my $name = _store_name($ctx);
    my %rec  = _visible($fields);
    $rec{_submitted} = strftime( '%Y-%m-%dT%H:%M:%S', localtime );
    $rec{_ip}        = $ctx->{ip} // '';
    $rec{_form}      = $name;
    $rec{_source}    = $ctx->{source} if ( $ctx->{origin} // '' ) ne 'form';
    if ( $ctx->{quarantined} ) {
        $rec{_quarantined} = JSON::PP::true;
        $rec{_spam_reason} = $ctx->{spam_reason} // '';
    }
    $rec{_row_refused} = JSON::PP::true if $extra && $extra->{row_refused};
    # SM905 U4: a table handler pointing its row at the files has to save them
    # BEFORE the row is written, so it hands the result in rather than having
    # them saved twice under two stamps.
    my $up = $extra && $extra->{uploads};
    $up = _stage_uploads( $ctx->{files}, $dir, $name )
        if !$up && ref $ctx->{files} eq 'ARRAY' && @{ $ctx->{files} };
    if ( $up && @{ $up->{saved} } ) { $rec{_files} = $up->{saved}; $rec{_files_dir} = $up->{rel} }
    # A file that could not be written is named, not dropped. A record listing
    # two of the three files a visitor sent reads as a visitor who sent two.
    $rec{_files_failed} = $up->{failed} if $up && @{ $up->{failed} };
    my $path = "$dir/$name.jsonl";
    # SM961: the store's sidecar lock, the one delete/confirm/approve take across
    # their read-and-rewrite - a lock on the store file itself is lost to their rename.
    my $store_lock = Lazysite::Util::store_lock($path)
        or return { ok => 0, why => "cannot lock the store: $!" };
    open my $fh, '>>:utf8', $path or return { ok => 0, why => "cannot open the store: $!" };
    flock $fh, LOCK_EX;
    my $line  = JSON::PP->new->canonical->encode( \%rec );
    my $wrote = print {$fh} "$line\n";
    flock $fh, LOCK_UN;
    # SM020: a failed print surfaces at close. Without the check a disk-full
    # submission was acknowledged while the record never landed.
    return { ok => 0, why => "the store write did not complete: $!" } unless close($fh) && $wrote;
    # SM938 D5: WHICH ROW, so the notice can link to it. The store as the
    # readers name it - the handler's configured directory, relative - and the
    # row's id. Only the handler that wrote it knows either.
    ( my $rel_dir = ( defined $h->{path} && length $h->{path} ) ? $h->{path} : 'lazysite/forms/submissions' )
        =~ s{/+\z}{};
    return { ok => 1,
        stored => { file => "$rel_dir/$name.jsonl", id => submission_row_id($line) },
        ( $up && @{ $up->{failed} } ? ( note => _files_note($up) ) : () ) };
}

# SM905 U4: the delivery SUCCEEDED and something is still missing, which is the
# `note` state SM877 added - the record landed, and a file the visitor attached
# did not. A WARN and an audit detail, not a failure: reporting the submission as
# failed would lose the fields that did arrive.
sub _files_note {
    my ($up) = @_;
    return 'uploaded files that could not be written: ' . join( ', ', @{ $up->{failed} } )
        . ' (' . scalar( @{ $up->{saved} } ) . ' of '
        . ( scalar( @{ $up->{saved} } ) + scalar( @{ $up->{failed} } ) ) . ' stored)'
        . ( length( $up->{nodir} // '' ) ? " - the directory for them: $up->{nodir}" : '' );
}

sub _safe_filename {
    my ($n) = @_;
    $n =~ s{.*[\\/]}{};
    $n =~ s/[^A-Za-z0-9._-]/_/g;
    $n =~ s/\A\.+//;
    $n = 'file' unless length $n;
    return substr( $n, 0, 100 );
}

# One submission's uploads, written once. The stamp is minted HERE and the
# result carried, so the two records that describe the same files - the
# submissions copy and, since SM905 U4, the table row - cannot end up naming two
# different directories.
sub _stage_uploads {
    my ( $files, $dir, $name ) = @_;
    return undef unless ref $files eq 'ARRAY' && @{$files};
    my $sid = strftime( '%Y%m%dT%H%M%S', localtime ) . '-' . sprintf( '%04x', int rand 65536 );
    my ( $saved, $rel, $failed, $nodir ) = _save_uploads( $files, $dir, $name, $sid );
    return { saved => $saved, rel => $rel, failed => $failed, nodir => $nodir };
}

sub _save_uploads {
    my ( $files, $dir, $name, $sid ) = @_;
    my $rel  = "$name.files/$sid";
    my $fdir = "$dir/$rel";
    # make_path DIES, and the middle of a visitor's submission is not the place:
    # an uploads directory that could not be created took the whole POST down
    # with it, losing the fields as well as the files. It is a reason the files
    # are missing, reported with them.
    my $nodir = '';
    if ( !eval { make_path($fdir) unless -d $fdir; 1 } ) {
        $nodir = $@ || 'unknown';
        $nodir =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
        chomp $nodir;
    }
    my ( @saved, @failed, $i );
    for my $f (@$files) {
        $i++;
        my $safe = _safe_filename( $f->{filename} // '' );
        $safe = "$i-$safe" if !length $nodir && -e "$fdir/$safe";
        # A file that cannot be written USED TO BE SKIPPED IN SILENCE, which made
        # a partial save indistinguishable from a visitor who attached fewer
        # files. It is named instead, on the record and in the delivery note.
        my $w;
        if ( length $nodir || !open $w, '>:raw', "$fdir/$safe" ) {
            push @failed, $safe;
            next;
        }
        print {$w} $f->{data} // '';
        close $w;
        push @saved, $safe;
    }
    return ( \@saved, $rel, \@failed, $nodir );
}

# DP-4 and SM569 in one type. THIS IS THE ANONYMOUS WRITE PATH TO A TABLE, and
# the only one: the handler decides everything structural - which table, which
# columns - and the caller decides values and nothing else. The row goes
# through the same coercion as any other write, so a form cannot put into the
# store anything the API could not.
sub _to_table {
    my ( $h, $fields, $ctx ) = @_;
    my $keep = _bool( $h->{keep_copy} // 'true' ) eq 'true';
    my $copy = 'lazysite/forms/submissions';

    # SM905 U4: THE UPLOADS ARE SAVED FIRST when the row is to point at them,
    # and the same result is then handed to the copy. The order used to be row
    # then copy, and the copy is what saves the files - so the row was written
    # before the paths it needed existed. The two writes are mutually dependent
    # (the copy carries whether the row was refused, the row carries where the
    # files went), which is why the staging is separated from both.
    my $up;
    if ( length( $h->{files_column} // '' ) && $keep ) {
        my $dir = store_path($copy);
        if ( eval { make_path($dir) unless -d $dir; 1 } ) {
            $up = _stage_uploads( $ctx->{files}, $dir, _store_name($ctx) );
        }
    }
    my $stored = _table_row( $h, $fields, $ctx, ( $up ? { %{$up}, path => $copy } : undef ) );
    return $stored unless $keep;
    my $filed = _to_file( { path => $copy }, $fields, $ctx,
        { row_refused => !$stored->{ok}, ( $up ? ( uploads => $up ) : () ) } );
    return { ok => 0, why => ( $stored->{why} // '' ) . '; the submissions copy was not kept either' }
        if !$stored->{ok} && !$filed->{ok};
    return { ok => 1, why => 'the row was stored; the submissions copy was not: ' . ( $filed->{why} // '' ) }
        if $stored->{ok} && !$filed->{ok};
    # The copy is what wrote the files, so it is the half that knows one of them
    # did not land. Passing its note on is what puts the failure in the audit
    # line for a TABLE handler as well as a file one.
    # SM857 q4: JOINED, not overwritten. _table_row can now carry a note of its
    # own - a personal row that belongs to nobody - and assigning the copy's note
    # over it would drop whichever arrived first, which is how one true statement
    # silently replaces another.
    $stored->{note} = join '; ', grep { length } ( $stored->{note} // '' ), ( $filed->{note} // '' );
    delete $stored->{note} unless length $stored->{note};
    return $stored;
}

sub _table_row {
    my ( $h, $fields, $ctx, $up ) = @_;
    my $table = $h->{table} // '';
    return { ok => 0, why => "no usable table name ('$table')" } unless $table =~ /\A[a-z][a-z0-9_]*\z/;
    my ( $map, $why ) = parse_fields( $h->{fields} );
    return { ok => 0, why => $why } unless $map;
    my $ok = eval {
        require Lazysite::Data::Tables;
        require Lazysite::Manager::Plugins;
        1;
    };
    return { ok => 0, why => 'the data modules could not be loaded: ' . ( $@ || 'unknown' ) } unless $ok;
    {
        # SM409: off means off - a table handler writing into a store whose
        # extension an operator switched off would be the extension still
        # running after being turned off.
        no warnings 'once';
        local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
        return { ok => 0, why => 'the Data tables extension is disabled, so no row can be stored' }
            unless Lazysite::Manager::Plugins::plugin_enabled('plugins/data.pl');
    }
    my %row;
    for my $from ( sort keys %$map ) {
        next                                     if $from =~ /\A_/;
        $row{ $map->{$from} } = $fields->{$from} if exists $fields->{$from};
    }
    # The guard reads the MAPPED fields only, and deliberately runs before the
    # files column is added: a form whose mapping matches nothing is a
    # misconfiguration, and a row carrying only a file path would hide it.
    return { ok => 0, why => "no mapped field was given, so nothing was stored in '$table'" } unless %row;
    # SM905 U4: site-relative paths, comma separated, in the order the browser
    # sent them. A path an operator can paste into the Files page, one per file
    # rather than the directory, because a row that names a folder still needs
    # the submissions record read to find out what is in it. A submission with no
    # files leaves the column ALONE rather than writing an empty string - a
    # column that was never given a value is not the same as one holding nothing.
    my $col = $h->{files_column} // '';
    $row{$col} = join ', ', map { "$up->{path}/$up->{rel}/$_" } @{ $up->{saved} }
        if length $col && $up && @{ $up->{saved} };

    # SM857 q4: THE POLICY THE HANDLER DECLARES, written with the row. Absent
    # leaves the column alone, which is the shared default - the same treatment
    # the files column gets, and for the same reason: a column nothing was
    # written to is not a column holding nothing.
    my $policy = $h->{row_policy} // '';
    $row{ Lazysite::Data::Owned::policy_column() } = $policy if length $policy;

    # AND A PERSONAL ROW NEEDS SOMEBODY TO BELONG TO.
    #
    # `personal` plus no actor is a public form: created_by is empty, so the row
    # belongs to nobody and only an operator can amend it. That is SAFE - it is
    # more locked down, not less - and it is almost certainly not what was asked
    # for, which is the combination worth saying out loud. The row is still
    # written, because refusing it would lose the submission over a
    # configuration the visitor cannot see.
    my $orphan
        = ( $policy eq 'personal' && !length( $ctx->{actor} // '' ) )
        ? 'this row is marked personal and the submitter was not signed in, so it '
        . 'belongs to no account and only an operator can amend it - a personal row '
        . 'needs an authenticated form'
        : '';
    my $r = eval {
        Lazysite::Data::Tables::insert_row( $DOCROOT, $table, \%row,
            ( length( $ctx->{actor} // '' ) ? ( actor => $ctx->{actor} ) : () ) );
    };
    return { ok => 0, why => "the row could not be stored in '$table': " . ( $@ || 'unknown' ) } if $@;
    return { ok => 0, why => "the row could not be stored in '$table': " . ( $r->{error} // 'unknown' ) }
        unless $r && $r->{ok};
    return { ok => 1, key => $r->{key}, ( length $orphan ? ( note => $orphan ) : () ) };
}

# The email goes out through the Form SMTP extension's script, which owns the
# transport; the handler contributes its addresses, prefix and attach setting.
sub _to_smtp {
    my ( $h, $fields, $ctx ) = @_;
    my $script = _find_script('form-smtp.pl')
        or return { ok => 0, why => 'the Form SMTP extension\'s script was not found' };
    my %payload = ( config => {%$h}, form => { _visible($fields) } );
    if ( _bool( $h->{attach_files} // 'false' ) eq 'true'
        && ref $ctx->{files} eq 'ARRAY' && @{ $ctx->{files} } )
    {
        require MIME::Base64;
        $payload{files} = [ map {
                { filename => $_->{filename}, type => $_->{type},
                    size => length( $_->{data}                      // '' ),
                    data => MIME::Base64::encode_base64( $_->{data} // '' ) }
        } @{ $ctx->{files} } ];
    }
    my $r = _run_smtp_script( $script, \%payload );
    return { ok => 0, why => 'the mail was not sent: ' . ( $r->{error} // 'no answer' ) }
        unless $r->{ok};

    # SM877: THE OPERATOR'S COPY HAS ALREADY GONE, and the acknowledgement is a
    # second delivery that may fail on its own. It does not fail the submission:
    # the site got what it was told about, and a visitor whose form worked
    # should not be shown a failure because a cap stopped a courtesy message.
    # But it must not be silent either, so the reason travels on `note`, which
    # reaches the delivery's audit record and the event log.
    my $note = _acknowledge_submitter( $h, $fields, $ctx, $script );
    return length $note ? { ok => 1, note => $note } : { ok => 1 };
}

sub _run_smtp_script {
    my ( $script, $payload ) = @_;
    require IPC::Open2;
    local $ENV{DOCUMENT_ROOT} = $DOCROOT;
    my ( $out, $in );
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $pid = eval { IPC::Open2::open2( $out, $in, $^X, $script, '--pipe' ) }
        or return { ok => 0, error => "cannot run the Form SMTP script: $@" };
    print {$in} JSON::PP::encode_json($payload);
    close $in;
    my $res = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { JSON::PP::decode_json( $res // '' ) } // {};
}

# --- SM877: acknowledging the person who filled the form in -------------------

# The address the site will write to, or a refusal that names what is wrong.
# REFUSE RATHER THAN GUESS: an absent field and an empty one are both refusals,
# because a blank is the value a mistake produces and "send it nowhere" is not a
# thing anybody configured. The pattern is the one the schema's own `email` type
# uses (see _check_field), so the two agree about what an address is.
sub _submitter_address {
    my ( $h, $fields ) = @_;
    my $key = $h->{mail_the_submitter_field};
    return ( undef, '' ) unless defined $key && length $key;

    my $v = $fields->{$key};
    return ( undef, "the form has no field '$key', so there is no address to "
            . 'acknowledge - nothing was sent to the submitter' )
        unless exists $fields->{$key};
    return ( undef, "the form's '$key' field is empty, so there is no address to "
            . 'acknowledge - nothing was sent to the submitter' )
        unless defined $v && length $v;
    # SM1017 (SM1010 F2): EXACTLY ONE ADDRESS, refused otherwise. The shape this
    # had, "something, an @, something", admitted `root,victim@example.org` - one
    # @, two recipients once `sendmail -t` reads the To: header.
    require Lazysite::Mail;
    my ( $one, $bad ) = Lazysite::Mail::one_address($v);
    return ( undef, "the form's '$key' field is refused as the submitter's address - $bad - so "
            . 'nothing was sent to the submitter' )
        unless defined $one;
    return ( $one, '' );
}

sub _submitter_key {
    my ($addr) = @_;
    require Digest::SHA;
    return substr Digest::SHA::sha256_hex( lc $addr ), 0, 24;
}

# ( $per_destination, $per_site ) within the last hour, or ( undef, undef ) when
# the record exists and will not open. UNDEF IS NOT ZERO and the cap policy
# refuses on it: a counter nobody can read must not read as "this has never
# happened", which is the one reading that switches the control off exactly when
# something is wrong. An ABSENT record is a genuine zero - nothing has been sent
# yet - and says so.
sub _submitter_counts {
    my ($key) = @_;
    my $path = submitter_mail_file();
    return ( undef, undef ) unless defined $path;

    open my $fh, '<:utf8', $path or do {
        return ( 0, 0 ) if $!{ENOENT};
        cannot_read( 'the submitter-mail record', $path );
        return ( undef, undef );
    };
    my $since = time - 3600;
    my ( $dest, $site ) = ( 0, 0 );
    while ( my $line = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($line) } or next;
        next unless ref $r eq 'HASH' && ( $r->{t} // 0 ) >= $since;
        $site++;
        $dest++ if ( $r->{d} // '' ) eq $key;
    }
    close $fh;
    return ( $dest, $site );
}

sub _record_submitter_send {
    my ($key) = @_;
    my $path = submitter_mail_file();
    return unless defined $path;
    my $dir = dirname($path);
    eval { make_path($dir) unless -d $dir; 1 } or return;
    open my $fh, '>>:utf8', $path or do {
        log_event( 'WARN', 'handlers',
            'cannot record an acknowledgement, so its cap cannot count it',
            file => $path, error => "$!" );
        return;
    };
    flock $fh, LOCK_EX;
    print {$fh} JSON::PP::encode_json( { t => time, d => $key } ), "\n";
    close $fh;
    return;
}

# A cap read from configuration. A missing value takes the schema's default; a
# value that is not a whole number falls back to it as well rather than to NO
# cap, which is the trap SM905's ceiling walked into - a non-numeric limit
# numifies to zero, and zero here would refuse every acknowledgement while
# looking like a configuration that permits them.
sub _submitter_cap {
    my ( $h, $key, $default ) = @_;
    my $v = $h->{$key};
    return $default unless defined $v && $v =~ /\A\d+\z/;
    return 0 + $v;
}

# Sends the second, separate message. Returns '' when it went, or the reason it
# did not. A SEPARATE DELIVERY RATHER THAN A SECOND `To:` - the requester's own
# point, and for their reason: one message addressed to both would put the
# operator's address in a stranger's inbox.
sub _acknowledge_submitter {
    my ( $h, $fields, $ctx, $script ) = @_;

    # SM913's question, answered here because this is where it lands: a
    # QUARANTINED submission gets no acknowledgement.
    #
    # SM216 holds a suspect submission back from the notification bell on the
    # grounds that a spam run must not be able to make the site shout. Answering
    # it is louder than that: it makes the site write to an address the spammer
    # chose, which is the open-relay shape the caps exist to bound - and on the
    # form that produced SM913, four of four genuine-looking submissions were
    # spam.
    #
    # SM1017 (SM1010 F1): THE FLAG IS ASKED OF THE CONTEXT. This read
    # `$fields->{_quarantined}`, on the belief that the form handler left the flag
    # on the fields - and it does not: it strips every `_` key before delivery
    # and passes the flag as `quarantined` in the context. So on the real path
    # every quarantined submission WAS acknowledged; the only test called this
    # sub with the key in the fields, the one arrangement a visitor's post never
    # produces. t/unit/forms/60 now posts through the CGI. The fields are still
    # asked, so a caller that does carry the key there is not trusted less.
    return 'the submission is held in quarantine, so no acknowledgement was sent - '
        . 'answering a suspect submission writes to an address somebody else chose'
        if $ctx->{quarantined} || $fields->{_quarantined};

    my ( $addr, $why ) = _submitter_address( $h, $fields );
    return $why unless defined $addr;

    my $key = _submitter_key($addr);
    my ( $dest, $site ) = _submitter_counts($key);

    require Lazysite::Egress;
    my ( $ok, $refusal ) = Lazysite::Egress::within_caps(
        what => 'form',
        axes => [
            { name => 'per-recipient',
                limit   => _submitter_cap( $h, 'submitter_per_destination_hour', 3 ),
                used    => $dest,
                window  => 'hour',
                setting => 'submitter_per_destination_hour',
            },
            { name => 'per-site',
                limit   => _submitter_cap( $h, 'submitter_per_site_hour', 60 ),
                used    => $site,
                window  => 'hour',
                setting => 'submitter_per_site_hour',
            },
        ],
    );
    return $refusal unless $ok;

    # The acknowledgement carries the submission's visible fields, like the
    # operator's copy, and NEVER the uploaded files: the submitter sent those,
    # and mailing them back is volume without information.
    my %payload = (
        config => { %$h, to => $addr },
        form   => { _visible($fields) },
    );
    my $r = _run_smtp_script( $script, \%payload );
    return 'the acknowledgement was not sent: ' . ( $r->{error} // 'no answer' )
        unless $r->{ok};

    _record_submitter_send($key);
    return '';
}

# SM1020: the two, published for Lazysite::Outbox, which sends through the same
# extension script the same way.
sub find_script     { return _find_script(@_) }
sub run_smtp_script { return _run_smtp_script(@_) }

sub _find_script {
    my ($name) = @_;
    require Cwd;
    my $here = dirname( Cwd::abs_path(__FILE__) // __FILE__ );
    # SM1222: the dev server's --extensions directories first (real files only).
    for my $d ( Lazysite::Paths::dev_extension_dirs() ) {
        my $p = "$d/$name";
        return $p if -f $p && !-l $p;
    }
    for my $p ( "$here/../../plugins/$name", "$DOCROOT/../plugins/$name",
        "$DOCROOT/../cgi-bin/$name", '/usr/share/lazysite/plugins/' . $name )
    {
        return $p if -f $p;
    }
    return undef;
}

# SM579: the connector decides - its modes (a form is public invocation, the
# timer scheduled), its rate cap, its credential, its record.
sub _to_connector {
    my ( $h, $fields, $ctx ) = @_;
    require Lazysite::Manager::Connectors;
    no warnings 'once';
    local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
    # SM905 U1: the files, when the handler asks for them.
    #
    # Same shape as the email handler's payload - filename, type, size, base64
    # data - so a destination written for one reads the other. Bounded, and a
    # request over the ceiling is REFUSED: sending it short would leave the
    # service unable to tell it had been given part of a photograph.
    my %payload = ( _visible($fields) );
    if ( _bool( $h->{attach_files} // 'false' ) eq 'true'
        && ref $ctx->{files} eq 'ARRAY'
        && @{ $ctx->{files} } )
    {
        my $ceiling = $h->{attach_max_kb};
        $ceiling = 1024 unless defined $ceiling && $ceiling =~ /\A\d+\z/;
        my $total = 0;
        $total += length( $_->{data} // '' ) for @{ $ctx->{files} };
        my $kb = int( $total / 1024 + 0.5 );
        return { ok => 0,
            why => "the uploaded files are ${kb}KB, over this handler's "
                . "${ceiling}KB ceiling - raise attach_max_kb on the handler, or "
                . 'ask for a smaller file. Nothing was sent' }
            if $total > $ceiling * 1024;

        require MIME::Base64;
        $payload{files} = [ map {
                { filename => $_->{filename}, type => $_->{type},
                    size => length( $_->{data}                      // '' ),
                    data => MIME::Base64::encode_base64( $_->{data} // '' ) }
        } @{ $ctx->{files} } ];
    }

    my $r = Lazysite::Manager::Connectors::call( $h->{connector} // '', \%payload,
        mode    => ( ( $ctx->{origin} // '' ) eq 'timer' ? 'scheduled' : 'public' ),
        actor   => $ctx->{actor} // '',
        trigger => $ctx->{source} );
    return { ok => 1, call_id => $r->{call_id} } if $r->{ok};
    return { ok => 0, why => 'the connector did not deliver: ' . ( $r->{error} // $r->{state} // 'failed' ) };
}

# SM1019: A NOTIFY HANDLER QUEUES THE EVENT AND RETURNS. The daemon sends.
#
# A QUARANTINED SUBMISSION NOTIFIES NOBODY - asked of the CONTEXT, which is where
# the form handler puts the flag (SM1017 is what asking the fields cost). It is
# an ok delivery with a note, not a failure: nothing is wrong with the rule, and
# the note reaches the delivery's audit row.
sub _to_notify {
    my ( $h, $fields, $ctx ) = @_;
    return { ok => 1, note => 'the submission is held in quarantine, so this rule notified nobody' }
        if $ctx->{quarantined} || $fields->{_quarantined};
    require Lazysite::Outbox;
    my $r = Lazysite::Outbox::enqueue( $DOCROOT, $h, { _visible($fields) }, $ctx );
    return { ok => 0, why    => $r->{why} } unless $r->{ok};
    return { ok => 1, queued => $r->{queued} };
}

# --- the timer's half --------------------------------------------------------

# Which entries are due, given each one's last run. $runs is { entry => {last_run} }.
sub due_entries {
    my ( $schedule, $runs, $now ) = @_;
    my @due;
    for my $e (@$schedule) {
        next unless enabled($e)                        && !$e->{invalid};
        next unless ( $e->{every} // '' ) =~ /\A\d+\z/ && $e->{every} >= $SCHEDULE_FLOOR;
        my $last = ( ref $runs->{ $e->{id} } eq 'HASH' ? $runs->{ $e->{id} }{last_run} : 0 ) // 0;
        $last = 0 if $last !~ /\A\d+(?:\.\d+)?\z/ || $last > $now;
        push @due, $e if $now - $last >= $e->{every};
    }
    return \@due;
}

# --- the conversion (SM842, run once on upgrade) -----------------------------
#
# Brings a site written for the old shapes to the one shape, and says what it
# did. Idempotent: a second run finds nothing to change and says so.
#
#   1. `type: db` handlers become `type: table` with keep_copy: false.
#   2. `type: webhook` / `type: api` handlers become connectors (public mode, no
#      rate cap - the webhook had none - and the same JSON or Slack body), and
#      the handler becomes a connector handler naming it. A plain http:// URL to
#      another host cannot be a connector, which sends over https only: that
#      handler is left as it is and reported, and delivers nothing until it is
#      changed.
#   3. A form whose targets are INLINE (no `- handler:` at all) gets a named
#      handler per inline target - reusing an existing handler that delivers to
#      the same place - and its targets become references. Inline targets in a
#      form that ALSO names handlers never delivered (the old reader ignored
#      them), so they are dropped rather than woken up, and reported.
#   4. A connector with schedule_every becomes a schedule entry calling a
#      connector handler for it, and the connector loses the two keys.
#
# Returns { ok, changed => [sentences], left => [sentences] }.
sub convert {
    my (%o) = @_;
    my ( @changed, @left );
    my $handlers = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was converted' }
        unless defined $handlers;
    my $schedule = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was converted' }
        unless defined $schedule;
    my $names = form_names();
    return { ok => 0, error => 'the forms directory could not be read; nothing was converted' }
        unless defined $names;

    require Lazysite::Manager::Connectors;
    no warnings 'once';
    local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
    my $conns = Lazysite::Manager::Connectors::connectors();
    return { ok => 0, error => 'the connector store could not be read; nothing was converted' }
        unless defined $conns;
    my ( $h_dirty, $c_dirty, $s_dirty ) = ( 0, 0, 0 );
    my %form_text;

    my $new_connector = sub {
        my ( $want, $url, $format, $from ) = @_;
        return ( undef, "$from: a connector sends over https (or http to this host) only, and "
                . "'$url' is neither - change it to https:// and convert again" )
            unless $url =~ m{\Ahttps://[^\s/]+} || $url =~ m{\Ahttp://(?:127\.0\.0\.1|localhost)(?::\d+)?(?:/|\z)};
        for my $cid ( sort keys %$conns ) {    # the same destination already exists
            my $c = $conns->{$cid};
            return ( $cid, '' )
                if ( $c->{url} // '' ) eq $url && ( $c->{format} // 'json' ) eq $format
                && ( $c->{modes} || {} )->{public};
        }
        ( my $base = lc $want ) =~ s/[^a-z0-9_-]+/-/g;
        $base =~ s/\A[^a-z0-9]+//;
        $base = 'webhook' unless length $base;
        $base = substr( $base, 0, 56 );
        my ( $cid, $n ) = ( $base, 1 );
        $cid = $base . '-' . ++$n while exists $conns->{$cid};
        my ( $c, $err ) = Lazysite::Manager::Connectors::normalise( {
                name          => "$want (converted from a webhook)",
                url           => $url,
                format        => $format,
                modes         => { public => 1, authenticated => 0, scheduled => 0 },
                rate_per_hour => 0,
        } );
        return ( undef, "$from: $err" ) unless $c;
        $conns->{$cid} = $c;
        $c_dirty = 1;
        return ( $cid, '' );
    };
    my $handler_for = sub {
        my ( $want_id, %rec ) = @_;
        for my $h (@$handlers) {    # reuse one that already delivers there
            next unless ( $h->{type} // '' ) eq $rec{type};
            next if grep { ( $h->{$_} // '' ) ne ( $rec{$_} // '' ) } grep { $_ ne 'name' } keys %rec;
            return $h->{id};
        }
        ( my $base = $want_id ) =~ s/[^A-Za-z0-9_-]+/-/g;
        my ( $id, $n ) = ( $base, 1 );
        $id = $base . '-' . ++$n while find_handler( $handlers, $id );
        push @$handlers, { id => $id, enabled => 'true', %rec };
        $h_dirty = 1;
        return $id;
    };

    # 1 and 2: the handlers themselves.
    for my $h (@$handlers) {
        my $t = $h->{type} // '';
        if ( $t eq 'db' ) {
            $h->{type}      = 'table';
            $h->{keep_copy} = 'false';
            $h_dirty        = 1;
            push @changed, "handler '$h->{id}': db -> table (keep_copy: false)";
        }
        elsif ( $t eq 'webhook' || $t eq 'api' ) {
            my $fmt = ( $h->{format} // 'json' ) eq 'slack' ? 'slack' : 'json';
            my ( $cid, $why ) = $new_connector->( $h->{id}, $h->{url} // '', $fmt, "handler '$h->{id}'" );
            unless ($cid) { push @left, $why; next }
            delete @$h{qw(url format method)};
            $h->{type}      = 'connector';
            $h->{connector} = $cid;
            $h_dirty        = 1;
            push @changed, "handler '$h->{id}': $t -> connector '$cid' (public, no rate cap, $fmt body)";
        }
    }

    # 3: inline form targets.
    for my $f (@$names) {
        my $text = _slurp( form_file($f), "forms/$f.conf" );
        return { ok => 0, error => _unreadable("$f.conf") . '; nothing was converted' } unless defined $text;
        my ( $ids, $inline, $other ) = parse_form_conf($text);
        next unless @$inline;
        my @new = @$ids;
        if (@$ids) {
            push @changed, "form '$f': dropped " . scalar(@$inline) . ' inline target(s) that never delivered '
                . '(the form names handlers, and the old reader ignored inline targets beside them)';
        }
        else {
            for my $t (@$inline) {
                my $type = lc( $t->{type} // '' );
                if ( $type eq 'file' ) {
                    my $p   = $t->{path} // 'lazysite/forms/submissions';
                    my $why = _check_path($p);
                    if ( length $why ) { push @left, "form '$f': inline file target: $why"; next }
                    my $id = $handler_for->( "$f-file", type => 'file', name => "$f submissions", path => $p );
                    push @new,     $id;
                    push @changed, "form '$f': inline file target -> handler '$id'";
                }
                elsif ( $type eq 'webhook' || $type eq 'api' ) {
                    my $fmt = ( $t->{format} // 'json' ) eq 'slack' ? 'slack' : 'json';
                    my ( $cid, $why ) = $new_connector->( "$f-$type", $t->{url} // '', $fmt, "form '$f'" );
                    unless ($cid) { push @left, $why; next }
                    my $id = $handler_for->( "$f-$type", type => 'connector', name => "$f to $cid", connector => $cid );
                    push @new, $id;
                    push @changed, "form '$f': inline $type target -> connector '$cid' and handler '$id'";
                }
                else {
                    push @changed, "form '$f': dropped an inline '$type' target, which could not deliver "
                        . '(an inline target carried no configuration beyond url, format and path)';
                }
            }
        }
        $form_text{$f} = render_form_conf( \@new, $other );
    }

    # 4: connector schedules.
    for my $cid ( sort keys %$conns ) {
        my $c = $conns->{$cid};
        next unless exists $c->{schedule_every} || exists $c->{schedule_payload};
        my $every   = delete $c->{schedule_every}   // 0;
        my $payload = delete $c->{schedule_payload} // {};
        $c_dirty = 1;
        next unless $every;
        my $hid = $handler_for->( $cid, type => 'connector', name => "$cid on a timer", connector => $cid );
        my $eid = $cid;
        my $n   = 1;
        $eid = $cid . '-' . ++$n while grep { $_->{id} eq $eid } @$schedule;
        push @$schedule, { id => $eid, handler => $hid, every => $every < $SCHEDULE_FLOOR ? $SCHEDULE_FLOOR : $every,
            enabled => ( ( $c->{modes} || {} )->{scheduled} ? 'true'   : 'false' ),
            payload => ( ref $payload eq 'HASH'             ? $payload : {} ) };
        $s_dirty = 1;
        push @changed, "connector '$cid': schedule_every $every -> schedule entry '$eid' calling handler '$hid'";
    }

    return { ok => 1, changed => \@changed, left => \@left, dry_run => 1 } if $o{dry_run};

    # Connectors first, then handlers, then forms, then the schedule: each
    # write leaves the site consistent if a later one fails, because nothing
    # names a connector or handler before it exists.
    if ($c_dirty) {
        my ( $ok, $err ) = Lazysite::Manager::Connectors::write_store($conns);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    if ($h_dirty) {
        my ( $ok, $err ) = write_handlers($handlers);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    for my $f ( sort keys %form_text ) {
        my ( $ok, $err ) = _write_text( form_file($f), $form_text{$f} );
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    if ($s_dirty) {
        my ( $ok, $err ) = write_schedule($schedule);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    log_event( 'INFO', 'handlers', 'converted to the handler contract (SM842)',
        changed => scalar @changed, left => scalar @left ) if @changed || @left;
    return { ok => 1, changed => \@changed, left => \@left };
}

1;
