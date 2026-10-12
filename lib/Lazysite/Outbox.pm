package Lazysite::Outbox;

# SM1019/SM1020 (SM1010 phase 1): THE NOTIFY HANDLER'S OUTBOX - a notification is
# a rule over an engine event, queued, and sent once each by the daemon.
#
# A `notify` handler is bound like any other: a form's second target, or a
# schedule entry. Delivering one does NOT send anything. It writes one outbox
# entry for the event - the rule, the event's visible fields, who caused it - and
# returns, so a visitor posting a comment never waits on mail to every follower
# (P4's 43-second request was that shape). The `notify-outbox` engine job then
# resolves the recipients, renders the templates and sends, as the daemon's job
# account.
#
# THE RULINGS THIS IS BUILT TO (the release manager, 2026-10-12, SM1010 "Ruled"):
#
#   * "Yes, engine = mechanism". Recipients may be addresses stored in a table,
#     the owners of rows, named accounts, fixed addresses, or the submitter. The
#     engine guards TECHNICAL SAFETY only - one address per recipient, refused on
#     anything a header parser reads as structure; queued and sent once each; a
#     per-recipient cap the operator sets; one audit row per recipient. Whether a
#     recipient may be written to is the operator's judgement and their
#     responsibility, so there is no engine opt-in here: an account's own
#     `notify_email` belongs to the bell-notice path (Notify.pm), not to rules.
#   * "New 'manage_notifications' cap": authoring a notify handler needs it.
#   * "Per rule, default on": every message carries an unsubscribe link and a
#     List-Unsubscribe header unless the rule turns it off.
#
# THE RECIPIENT GRAMMAR is a JSON list on one line of handlers.conf (the
# schedule's payload precedent - the file is flat key: value), each item one
# source:
#
#   {"accounts": ["ann", "bob"]}
#   {"owners_of": {"table": "subscriptions", "where": {"post": "post"}}}
#   {"addresses_from": {"table": "members", "column": "email",
#                       "where": {"list": "list"}}}
#   {"fixed": ["office@example.org"]}
#   {"submitter": "account"}               the verified actor (SM1018)
#   {"submitter": {"field": "email"}}      an address the event's field holds
#
# A `where` maps a COLUMN to an event FIELD, compared for equality. A field the
# event does not carry (or carries empty) makes that source resolve to NOBODY -
# never to "every row", which is what dropping the condition would mean.
use strict;
use warnings;
use JSON::PP        ();
use File::Path      qw(make_path);
use File::Basename  qw(dirname);
use Fcntl           qw(:flock);
use Lazysite::Util  qw(log_event cannot_read);
use Lazysite::Paths ();

our $VERSION = '1.0';

# How long a stored field value may be. The STORED event keeps a generous
# bound so a template can choose; what a template is GIVEN is capped at the 400
# characters a form notice already uses (form-handler.pl $MAX_NOTICE_FIELD_CHARS).
our $MAX_STORED_FIELD = 4000;
our $MAX_FIELD_CHARS  = 400;

my $NAME_RE    = qr/\A[a-z][a-z0-9_]{0,63}\z/;                 # a table or column
my $FIELD_RE   = qr/\A[A-Za-z][A-Za-z0-9_.~-]{0,127}\z/;       # an event field
my $ACCOUNT_RE = qr/\A[A-Za-z0-9][A-Za-z0-9_.\@-]{0,63}\z/;    # an account name

sub outbox_dir {
    my ($docroot) = @_;
    my $lz = Lazysite::Paths::lazysite_dir($docroot);
    return ( defined $lz && length $lz ) ? "$lz/notify/outbox" : undef;
}

# --- the recipient grammar ----------------------------------------------------

# ( \@sources, '' ) or ( undef, $why ). Each source comes back as a hash with
# one key, normalised: lists are lists, `where` is a hash (possibly empty).
sub parse_recipients {
    my ($text) = @_;
    return ( undef, 'recipients is required - a JSON list of sources' )
        unless defined $text && length $text;
    my $list = eval { JSON::PP->new->relaxed(0)->decode($text) };
    return ( undef, 'recipients must be a JSON list, e.g. '
            . '[{"owners_of":{"table":"subscriptions","where":{"post":"post"}}}]' )
        unless ref $list eq 'ARRAY';
    return ( undef, 'recipients names no source' ) unless @$list;
    return ( undef, 'recipients names more than 20 sources' ) if @$list > 20;
    my @out;
    my $i = 0;
    for my $s (@$list) {
        $i++;
        return ( undef, "recipients item $i must be an object with one key" )
            unless ref $s eq 'HASH' && keys %$s == 1;
        my ($k) = keys %$s;
        my $v = $s->{$k};
        my ( $norm, $why ) = _source( $k, $v );
        return ( undef, "recipients item $i ($k): $why" ) unless $norm;
        push @out, $norm;
    }
    return ( \@out, '' );
}

sub _where {
    my ($w) = @_;
    return ( {},    '' )                                         unless defined $w;
    return ( undef, 'where must be an object of column: field' ) unless ref $w eq 'HASH';
    return ( undef, 'where names more than 8 columns' ) if keys %$w > 8;
    for my $c ( sort keys %$w ) {
        return ( undef, "where: '$c' is not a column name" ) unless $c =~ $NAME_RE;
        my $f = $w->{$c};
        return ( undef, "where: $c must name an event field" )
            unless defined $f && !ref $f && $f =~ $FIELD_RE;
    }
    return ( {%$w}, '' );
}

sub _source {
    my ( $k, $v ) = @_;
    if ( $k eq 'accounts' ) {
        return ( undef, 'a list of account names' ) unless ref $v eq 'ARRAY' && @$v;
        return ( undef, 'at most 200 accounts' ) if @$v > 200;
        for my $a (@$v) {
            return ( undef, 'an account name is letters, digits, . _ @ or -' )
                unless defined $a && !ref $a && $a =~ $ACCOUNT_RE;
        }
        return ( { accounts => [@$v] }, '' );
    }
    if ( $k eq 'fixed' ) {
        return ( undef, 'a list of addresses' ) unless ref $v eq 'ARRAY' && @$v;
        return ( undef, 'at most 50 addresses' ) if @$v > 50;
        require Lazysite::Mail;
        for my $a (@$v) {
            my ( $one, $why ) = Lazysite::Mail::one_address($a);
            return ( undef, "an address is refused - $why" ) unless defined $one;
        }
        return ( { fixed => [@$v] }, '' );
    }
    if ( $k eq 'owners_of' || $k eq 'addresses_from' ) {
        return ( undef, 'an object with table' . ( $k eq 'addresses_from' ? ', column' : '' )
                . ' and where' )
            unless ref $v eq 'HASH';
        my %allowed = map { $_ => 1 } ( 'table', 'where', ( $k eq 'addresses_from' ? 'column' : () ) );
        my @extra = sort grep { !$allowed{$_} } keys %$v;
        return ( undef, 'does not take: ' . join( ', ', @extra ) ) if @extra;
        return ( undef, 'table must be a table name' )
            unless defined $v->{table} && !ref $v->{table} && $v->{table} =~ $NAME_RE;
        my ( $w, $why ) = _where( $v->{where} );
        return ( undef, $why ) unless $w;
        my %n = ( table => $v->{table}, where => $w );
        if ( $k eq 'addresses_from' ) {
            return ( undef, 'column must be a column name' )
                unless defined $v->{column} && !ref $v->{column} && $v->{column} =~ $NAME_RE;
            $n{column} = $v->{column};
        }
        return ( { $k => \%n }, '' );
    }
    if ( $k eq 'submitter' ) {
        return ( { submitter => 'account' }, '' ) if defined $v && !ref $v && $v eq 'account';
        if ( ref $v eq 'HASH' && keys %$v == 1 && defined $v->{field} ) {
            return ( undef, 'field must name an event field' )
                unless !ref $v->{field} && $v->{field} =~ $FIELD_RE;
            return ( { submitter => { field => $v->{field} } }, '' );
        }
        return ( undef, '"account" (the signed-in submitter) or {"field": "<name>"}' );
    }
    return ( undef, 'not a source - the sources are accounts, owners_of, addresses_from, '
            . 'fixed and submitter' );
}

# The tables a recipient list reads, for the save-time check that they exist.
sub tables_named {
    my ($sources) = @_;
    my @t;
    for my $s ( @{ $sources || [] } ) {
        for my $k (qw(owners_of addresses_from)) {
            push @t, [ $k, $s->{$k} ] if ref $s->{$k} eq 'HASH';
        }
    }
    return \@t;
}

# --- enqueue: the handler's half ---------------------------------------------

# A stable id for one event. A submission has no id of its own until a file
# handler stores it, and a rule may be the only target, so the event is named
# here from what it is and when, plus a random part: two identical posts in the
# same second are two events, and each is sent for once.
sub event_id {
    my ( $source, $fields ) = @_;
    require Digest::SHA;
    my $seed = join "\0", ( $source // '' ), time, $$, rand(),
        JSON::PP->new->canonical->encode( $fields || {} );
    utf8::encode($seed) if utf8::is_utf8($seed);
    return substr( Digest::SHA::sha256_hex($seed), 0, 16 );
}

# Write one outbox entry. Returns { ok => 1, queued => $id } or { ok => 0, why }.
#
# THE FIELDS ARE THE VISIBLE ONES, each bounded, and never the uploaded files:
# a notification says that something happened, and the files stay where the
# submission put them.
sub enqueue {
    my ( $docroot, $h, $fields, $ctx ) = @_;
    my $dir = outbox_dir($docroot) // return { ok => 0, why => 'no docroot: nowhere to queue' };
    my %f;
    for my $k ( sort keys %{ $fields || {} } ) {
        next if $k =~ /\A_/;
        my $v = $fields->{$k};
        next if ref $v;
        $v     = '' unless defined $v;
        $v     = substr( $v, 0, $MAX_STORED_FIELD ) if length $v > $MAX_STORED_FIELD;
        $f{$k} = $v;
    }
    my $id    = event_id( $ctx->{source}, \%f );
    my %entry = (
        id       => $id,
        rule     => $h->{id},
        created  => time,
        origin   => $ctx->{origin} // '',
        source   => $ctx->{source} // '',
        actor    => $ctx->{actor}  // '',
        fields   => \%f,
        attempts => 0,
        next_at  => 0,
    );
    eval { make_path($dir) unless -d $dir; 1 }
        or return { ok => 0, why => "cannot create the notification outbox: $@" };
    my $path = "$dir/" . time . "-$id.json";
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return { ok => 0, why => "cannot write the notification outbox: $!" };
    my $ok = print {$fh} JSON::PP->new->utf8->canonical->encode( \%entry );
    unless ( close($fh) && $ok ) { unlink $tmp; return { ok => 0, why => "the outbox write did not complete: $!" } }
    unless ( rename $tmp, $path ) { unlink $tmp; return { ok => 0, why => "cannot place the outbox entry: $!" } }
    return { ok => 1, queued => $id };
}


# --- run: the daemon's half (SM1020) ------------------------------------------
#
# The notify-outbox engine job calls this every tick. Each entry is one event
# for one rule: resolve the recipients, leave out whoever caused it (unless the
# rule says notify_actor), apply the per-recipient cap, render, send on each
# channel, and write one audit row per recipient per channel.
#
# SENT ONCE EACH. The ledger (notify/ledger.jsonl) holds one line per decided
# send, keyed by a hash of rule / event / channel / recipient, so a retry - a
# transport that was down, a daemon restarted mid-entry - skips everyone already
# sent to and reaches only the rest. The key is a HASH, never an address, for
# SM877's reason: a file of every address a site has written to is a mailing
# list.
#
# A LEDGER THAT WILL NOT OPEN STOPS THE RUN. "Could not tell what was sent" is
# not "nothing was", and reading it as nothing is how a retry sends twice.

our $MAX_RECIPIENTS = 5000;    # per event; over it, the entry fails and NOTHING is sent
our $MAX_PER_TICK   = 50;      # entries handled per run
our $MAX_ATTEMPTS   = 5;       # then the entry moves to notify/failed
our $LEDGER_DAYS    = 8;       # a line older than this is pruned
our $MAIL_SENDER    = \&_mail_send;   # tests may swap the transport; default is form-smtp

sub _lz_of      { return Lazysite::Paths::lazysite_dir( $_[0] ) }
sub ledger_file { return _lz_of( $_[0] ) . '/notify/ledger.jsonl' }
sub failed_dir  { return _lz_of( $_[0] ) . '/notify/failed' }

# ( \@lines ) or undef when the ledger exists and will not open.
sub _read_ledger {
    my ($docroot) = @_;
    my $f = ledger_file($docroot);
    open my $fh, '<:raw', $f or return $!{ENOENT} ? [] : cannot_read( 'the notification ledger', $f );
    my @l;
    while ( my $line = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($line) } or next;
        push @l, $r if ref $r eq 'HASH';
    }
    close $fh;
    return \@l;
}

sub _append_ledger {
    my ( $docroot, $rec ) = @_;
    my $f = ledger_file($docroot);
    eval { make_path( dirname($f) ) unless -d dirname($f); 1 } or return 0;
    open my $fh, '>>:raw', $f or return 0;
    flock $fh, LOCK_EX;
    my $ok = print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh or return 0;
    return $ok ? 1 : 0;
}

sub _prune_ledger {
    my ( $docroot, $lines, $now ) = @_;
    my $cut = $now - $LEDGER_DAYS * 86400;
    return unless grep { ( $_->{t} // 0 ) < $cut } @$lines;
    my $f   = ledger_file($docroot);
    my $tmp = "$f.tmp.$$";
    open my $fh, '>:raw', $tmp or return;
    print {$fh} JSON::PP->new->utf8->canonical->encode($_) . "\n" for grep { ( $_->{t} // 0 ) >= $cut } @$lines;
    close $fh or do { unlink $tmp; return };
    rename $tmp, $f or unlink $tmp;
    return;
}

sub _hash {
    require Digest::SHA;
    my $s = join "\0", map { $_ // '' } @_;
    utf8::encode($s) if utf8::is_utf8($s);
    return substr( Digest::SHA::sha256_hex($s), 0, 24 );
}

# The account store, read once per run: { login => { email => ... } }, or undef
# when it exists and cannot be read (the four states, SM778).
sub _accounts {
    my ($docroot) = @_;
    my $s = eval {
        require Lazysite::Auth::Settings;
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = _lz_of($docroot) . '/auth';
        return undef unless Lazysite::Auth::Settings::settings_readable();
        my $set   = Lazysite::Auth::Settings::read_settings();
        my $names = Lazysite::Auth::Settings::account_names();
        return undef if $Lazysite::Auth::Settings::USERS_UNREADABLE;
        # An account with no settings row is still an account - it simply has
        # no address. Every real account gets an entry; a settings row with no
        # account behind it (a deleted user) is not one.
        my %all = map { $_ => ( ref $set->{$_} eq 'HASH' ? $set->{$_} : {} ) } keys %{ $names || {} };
        \%all;
    };
    return ref $s eq 'HASH' ? $s : undef;
}

# The rows a where clause selects, paged up to the per-event bound. A where
# field the event does not carry, or carries empty, selects NOTHING.
# ( \@rows, '' ) or ( undef, $why ).
sub _rows {
    my ( $docroot, $table, $where, $fields ) = @_;
    my %w;
    for my $c ( sort keys %{ $where || {} } ) {
        my $v = $fields->{ $where->{$c} };
        return ( [], '' ) unless defined $v && !ref $v && length $v;
        $w{$c} = $v;
    }
    require Lazysite::Data::Tables;
    my ( @rows, $offset );
    $offset = 0;
    while (1) {
        my $r = eval {
            Lazysite::Data::Tables::read_rows( $docroot, $table, as => 'operator', where => \%w,
                limit => 500, offset => $offset, want_total => 0 );
        };
        return ( undef, "table '$table' could not be read: " . ( $@ || $r->{error} // 'unknown' ) )
            unless ref $r eq 'HASH' && $r->{ok};
        push @rows, @{ $r->{rows} || [] };
        last if @{ $r->{rows} || [] } < 500 || @rows > $MAX_RECIPIENTS;
        $offset += 500;
    }
    return ( \@rows, '' );
}

# Every recipient the rule names for this event, deduplicated:
# [ { key, account, address } ] - an account recipient has `account` (its
# address is looked up per channel), an address recipient has `address`.
# ( \@list, '' ) or ( undef, $why ) for a failure worth retrying.
sub resolve {
    my ( $docroot, $sources, $entry, $accounts ) = @_;
    my $fields = $entry->{fields} || {};
    my ( @out, %seen );
    my $add = sub {
        my (%r) = @_;
        my $key = defined $r{account} ? 'a:' . $r{account} : 'm:' . lc $r{address};
        push @out, { %r, key => $key } unless $seen{$key}++;
    };
    for my $s (@$sources) {
        if    ( $s->{accounts} ) { $add->( account => $_ ) for @{ $s->{accounts} } }
        elsif ( $s->{fixed} )    { $add->( address => $_ ) for @{ $s->{fixed} } }
        elsif ( my $o = $s->{owners_of} ) {
            my ( $rows, $why ) = _rows( $docroot, $o->{table}, $o->{where}, $fields );
            return ( undef, $why ) unless $rows;
            $add->( account => $_ ) for grep { defined && length } map { $_->{created_by} } @$rows;
        }
        elsif ( my $a = $s->{addresses_from} ) {
            my ( $rows, $why ) = _rows( $docroot, $a->{table}, $a->{where}, $fields );
            return ( undef, $why ) unless $rows;
            for my $row (@$rows) {
                my $v = $row->{ $a->{column} };
                next unless defined $v && length $v;
                $v =~ s/\A\s+|\s+\z//g;
                $add->( address => $v );
            }
        }
        elsif ( defined $s->{submitter} ) {
            if ( !ref $s->{submitter} ) {
                $add->( account => $entry->{actor} ) if length( $entry->{actor} // '' );
            }
            else {
                my $v = $fields->{ $s->{submitter}{field} };
                $add->( address => $v ) if defined $v && !ref $v && length $v;
            }
        }
        return ( undef, "more than $MAX_RECIPIENTS recipients - nothing was sent" )
            if @out > $MAX_RECIPIENTS;
    }
    return ( \@out, '' );
}

# --- rendering -----------------------------------------------------------------

# A value as a template is given it: at most $MAX_FIELD_CHARS characters, with
# control characters other than a newline or a tab removed. The template sees
# data, never template source (Notify's rule, :377-390).
sub _clean_value {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;
    $v = substr( $v, 0, $MAX_FIELD_CHARS ) . ' [...]' if length $v > $MAX_FIELD_CHARS;
    return $v;
}

sub _template_file {
    my ( $docroot, $name, $channel ) = @_;
    return undef unless defined $name && $name =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    my $p = _lz_of($docroot) . "/notify-templates/$name.$channel.tt";
    open my $fh, '<:utf8', $p or return undef; # not a store - a template, with a built-in fallback
    local $/;
    my $t = <$fh>;
    close $fh;
    return ( defined $t && length $t ) ? $t : undef;
}

sub _tt {
    my ( $docroot, $body, $vars ) = @_;
    my $out = eval {
        require Template;
        my $t = Template->new( {
                ABSOLUTE     => 0,
                RELATIVE     => 0,
                EVAL_PERL    => 0,
                INCLUDE_PATH => _lz_of($docroot) . '/notify-templates',
        } );
        my $o = '';
        $t->process( \$body, $vars, \$o ) or die $t->error() . "\n";
        $o;
    };
    return $out if defined $out;
    log_event( 'WARN', 'notify', 'a notification template failed; the built-in message is used',
        error => "$@" );
    return undef;
}

# { subject, text } for the email channel; { text } for the bell.
sub render {
    my ( $docroot, $h, $entry, $recipient, $channel, $base ) = @_;
    my %fields = map { $_ => _clean_value( $entry->{fields}{$_} ) } keys %{ $entry->{fields} || {} };
    my $unsub = '';
    if ( ( $h->{unsubscribe} // 'true' ) ne 'false' && length( $h->{unsubscribe_path} // '' ) ) {
        $unsub = ( $base // '' ) . $h->{unsubscribe_path};
    }
    my %vars = (
        rule            => $h->{name} // $h->{id},
        fields          => \%fields,
        actor           => $entry->{actor}       // '',
        recipient       => $recipient->{account} // '',
        site            => $base                 // '',
        unsubscribe_url => $unsub,
        event           => $entry->{id},
    );
    my $default_text = join "\n", ( $vars{rule}, '', map { "$_: $fields{$_}" } sort keys %fields );
    my $src  = _template_file( $docroot, $h->{template}, $channel );
    my $text = defined $src ? _tt( $docroot, $src, \%vars ) : undef;
    $text = $default_text unless defined $text && $text =~ /\S/;

    if ( $channel eq 'bell' ) {
        $text =~ s/\s+/ /g;
        $text =~ s/\A\s+|\s+\z//g;
        $text = substr( $text, 0, 400 );
        return { text => $text };
    }
    my $subject = $vars{rule};
    if ( $text =~ s/\A[ \t]*Subject:[ \t]*([^\n]*)\n(?:[ \t]*\n)?// ) { $subject = $1 }
    $subject =~ s/[\r\n]+/ /g;
    $subject =~ s/[\x00-\x1f\x7f]//g;
    $subject = substr( $subject, 0, 200 );
    $text =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;
    $text =~ s/\s+\z//;
    # THE ENGINE ADDS THE UNSUBSCRIBE LINE, not the template, so a template
    # cannot leave it out while the rule says it is on (ruled: per rule, default on).
    $text .= "\n\n-- \nTo stop these messages: $unsub" if length $unsub;
    return { subject => $subject, text => "$text\n", unsubscribe => $unsub };
}

# --- the transport ---------------------------------------------------------------

# Hand one message to the Form SMTP extension's --pipe in its message mode: a
# plain-text body this module composed, the Subject it rendered (the extension
# encodes it, RFC 2047, when it is not ASCII) and the List-Unsubscribe header.
# The extension owns the transport and refuses a To or From that is not exactly
# one address (SM1017). Dies with the reason.
sub _mail_send {
    my ( $docroot, $msg ) = @_;
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $script = Lazysite::Handlers::find_script('form-smtp.pl')
        or die "the Form SMTP extension's script was not found\n";
    my %headers = length( $msg->{unsubscribe} // '' ) ? ( 'List-Unsubscribe' => "<$msg->{unsubscribe}>" ) : ();
    my $r = Lazysite::Handlers::run_smtp_script( $script, {
            config => { to => $msg->{to}, ( length( $msg->{from} // '' ) ? ( from => $msg->{from} ) : () ) },
            form => {},
            message => { subject => $msg->{subject}, text => $msg->{text}, headers => \%headers },
    } );
    die( ( $r->{error} // 'no answer from the Form SMTP extension' ) . "\n" ) unless $r->{ok};
    return 1;
}

# --- one entry ---------------------------------------------------------------------

sub _audit {
    my ( $docroot, $actor, $rule, $channel, $ok, $who, $why ) = @_;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = _lz_of($docroot);
        Lazysite::Audit::audit_log( $actor, 'notify', "notify:$rule -> $channel", '',
            ( $ok ? 'ok' : 'failed' ), 'daemon', $who . ( length( $why // '' ) ? " - $why" : '' ) );
        1;
    };
    return;
}

# Who the recipient is, as the audit row names them: the account, or the address.
sub _who { my ($r) = @_; return defined $r->{account} ? "account $r->{account}" : "address $r->{address}" }

# Process one entry. Returns 'done', 'retry' (a transient failure: keep it and
# try later) or 'failed' with a reason.
sub _process {
    my ( $docroot, $entry, $h, $ctx, $ledger, $accounts, $base ) = @_;
    my ($sources) = parse_recipients( $h->{recipients} );
    return ( 'failed', "rule '$h->{id}' no longer has a usable recipient list" ) unless $sources;
    my ( $list, $why ) = resolve( $docroot, $sources, $entry, $accounts );
    return ( 'retry', $why ) unless $list;

    # NOTHING TO THE ACCOUNT THAT CAUSED THE EVENT, unless the rule asks: the
    # account itself, and its own address where an address source holds it.
    my $actor = $entry->{actor} // '';
    if ( length $actor && ( $h->{notify_actor} // 'false' ) ne 'true' ) {
        my $mine = lc( ( ref $accounts->{$actor} eq 'HASH' ? $accounts->{$actor}{email} : '' ) // '' );
        $list = [ grep {
                !( defined $_->{account} && $_->{account} eq $actor )
                && !( defined $_->{address} && length $mine && lc( $_->{address} ) eq $mine )
        } @$list ];
    }

    my @channels = grep { length } split /\s*,\s*/, ( $h->{channels} // 'email' );
    my $cap      = $h->{per_recipient_hour};
    $cap = 3 unless defined $cap && $cap =~ /\A\d+\z/;
    my $now  = $ctx->{now};
    my %done = map { ( $_->{k} // '' ) => 1 } @$ledger;
    my %used;
    for my $l (@$ledger) {
        next unless ( $l->{s} // '' ) eq 'sent' && ( $l->{t} // 0 ) >= $now - 3600;
        $used{ ( $l->{r} // '' ) . "\0" . ( $l->{c} // '' ) . "\0" . ( $l->{p} // '' ) }++;
    }

    my $unsub_on = ( $h->{unsubscribe} // 'true' ) ne 'false';
    return ( 'failed', 'unsubscribe is on and this site has no absolute address for the link - '
            . 'set base_url in lazysite/notify.conf (or site_url), or turn unsubscribe off' )
        if $unsub_on && ( grep { $_ eq 'email' } @channels )
        && ( $base // '' ) !~ m{\Ahttps?://[^/\s]+};

    my $transient = '';
    for my $r (@$list) {
        my $p = _hash( $r->{key} );
        for my $ch (@channels) {
            my $k = _hash( $h->{id}, $entry->{id}, $ch, $r->{key} );
            next if $done{$k};    # sent, or decided, on an earlier attempt
            next if $ch eq 'bell' && !defined $r->{account};    # the bell is for accounts
            my $mark = sub {
                my ($state) = @_;
                $done{$k} = 1;
                my $rec = { k => $k, r => $h->{id}, c => $ch, p => $p, s => $state, t => $now };
                push @$ledger, $rec;
                _append_ledger( $docroot, $rec )
                    or log_event( 'WARN', 'notify', 'could not write the notification ledger; a retry may resend',
                    rule => $h->{id} );
            };
            if ( ( $used{ $h->{id} . "\0$ch\0$p" } // 0 ) >= $cap ) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r),
                    "the per-recipient cap ($cap an hour, per_recipient_hour) is reached" );
                $mark->('refused');
                next;
            }
            my $out = render( $docroot, $h, $entry, $r, $ch, $base );
            if ( $ch eq 'bell' ) {
                require Lazysite::Notify;
                my $ok = Lazysite::Notify::bell_for( $docroot, $r->{account},
                    { type => 'rule', message => $out->{text}, target => $h->{id} } );
                if ($ok) {
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 1, _who($r) );
                    $used{ $h->{id} . "\0$ch\0$p" }++;
                    $mark->('sent');
                }
                else {
                    $transient ||= 'the bell store could not be written';
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), $transient );
                }
                next;
            }
            # email
            my $addr = $r->{address};
            if ( defined $r->{account} ) {
                my $a = $accounts->{ $r->{account} };
                $addr = ref $a eq 'HASH' ? $a->{email} : undef;
                if ( !defined $addr || !length $addr ) {
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r),
                        ( ref $a eq 'HASH' ? 'the account has no address' : 'there is no such account' ) );
                    $mark->('refused');
                    next;
                }
            }
            require Lazysite::Mail;
            my ( $one, $bad ) = Lazysite::Mail::one_address($addr);
            if ( !defined $one ) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), "refused: $bad" );
                $mark->('refused');
                next;
            }
            my $sent = eval {
                $MAIL_SENDER->( $docroot, { %$out, to => $one, from => $h->{from} } );
                1;
            };
            if ($sent) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 1, _who($r) );
                $used{ $h->{id} . "\0$ch\0$p" }++;
                $mark->('sent');
            }
            else {
                ( my $err = $@ || 'the transport gave no reason' ) =~ s/\s+\z//;
                # A refusal of the ADDRESS is final; anything else may pass on a retry.
                if ( $err =~ /is refused:/ ) {
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), $err );
                    $mark->('refused');
                }
                else {
                    $transient ||= $err;
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), "will retry: $err" );
                }
            }
        }
    }
    return length $transient ? ( 'retry', $transient ) : ( 'done', '' );
}

# --- the job -------------------------------------------------------------------------

sub _entry_files {
    my ($docroot) = @_;
    my $dir = outbox_dir($docroot);
    opendir my $dh, $dir or return $!{ENOENT} ? [] : cannot_read( 'the notification outbox', $dir );
    my @f = sort grep { /\A\d+-[0-9a-f]{16}\.json\z/ } readdir $dh;
    closedir $dh;
    return [ map { "$dir/$_" } @f ];
}

sub _read_entry {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return $!{ENOENT} ? 0 : cannot_read( 'a notification outbox entry', $path );
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $e = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $e eq 'HASH' ? $e : { _torn => 1 };
}

sub _write_entry {
    my ( $path, $e ) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    my $ok = print {$fh} JSON::PP->new->utf8->canonical->encode($e);
    unless ( close($fh) && $ok )  { unlink $tmp; return 0 }
    unless ( rename $tmp, $path ) { unlink $tmp; return 0 }
    return 1;
}

sub _fail_entry {
    my ( $docroot, $path, $e, $why ) = @_;
    my $dir = failed_dir($docroot);
    eval { make_path($dir) unless -d $dir; 1 };
    $e->{failed} = $why;
    ( my $leaf = $path ) =~ s{.*/}{};
    _write_entry( "$dir/$leaf", $e ) and unlink $path;
    log_event( 'WARN', 'notify', 'a notification was given up', rule => $e->{rule} // '', why => $why );
    return;
}

# run( docroot => ..., actor => <job account>, now => ... ). The notify-outbox
# job's body: { ok => 1, detail => {...} } or { ok => 0, error => ... }.
sub run {
    my (%ctx) = @_;
    my $docroot = $ctx{docroot};
    $ctx{now} //= time;

    my $files = _entry_files($docroot);
    return { ok => 0, error => 'the notification outbox could not be read; see the log' }
        unless defined $files;
    return { ok => 1, detail => { queued => 0 } } unless @$files;

    # One run at a time: two overlapping runs would each read the ledger before
    # the other wrote it.
    my $lock = _lz_of($docroot) . '/notify/.run.lock';
    open my $lk, '>>', $lock or return { ok => 0, error => "cannot open the outbox lock: $!" };
    return { ok => 1, detail => { busy => 1 } } unless flock $lk, LOCK_EX | LOCK_NB;

    my $ledger = _read_ledger($docroot);
    return { ok => 0, error => 'the notification ledger exists and could not be read, so nothing '
            . 'was sent - sending without it could send twice; see the log' }
        unless defined $ledger;
    _prune_ledger( $docroot, $ledger, $ctx{now} );

    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;
    my $accounts = _accounts($docroot);
    return { ok => 0, error => 'the account store could not be read, so no recipient could be '
            . 'resolved; see the log' }
        unless defined $accounts;
    require Lazysite::Notify;
    my $base = Lazysite::Notify::site_base($docroot);

    my ( @done, @retry, @failed );
    my $n = 0;
    for my $path (@$files) {
        last if $n++ >= $MAX_PER_TICK;
        my $e = _read_entry($path);
        next if defined $e && !ref $e;    # gone since the listing
        unless ( defined $e ) { push @retry, "$path: unreadable"; next }
        if ( $e->{_torn} ) { _fail_entry( $docroot, $path, {}, 'the entry is not JSON' ); push @failed, 'torn'; next }
        next if ( $e->{next_at} // 0 ) > $ctx{now};
        my $h = Lazysite::Handlers::find_handler( $handlers, $e->{rule} // '' );
        my $why
            = !$h                              ? "no rule '" . ( $e->{rule} // '' ) . "'"
            : ( $h->{type} // '' ) ne 'notify' ? "handler '$h->{id}' is not a notify rule"
            : !Lazysite::Handlers::enabled($h) ? "rule '$h->{id}' is switched off"
            :                                    '';
        if ( length $why ) {
            _audit( $docroot, $ctx{actor}, $e->{rule} // '', 'outbox', 0, "event $e->{id}", $why );
            _fail_entry( $docroot, $path, $e, $why );
            push @failed, "$e->{id}: $why";
            next;
        }
        my ( $state, $reason ) = _process( $docroot, $e, $h, \%ctx, $ledger, $accounts, $base );
        if ( $state eq 'done' ) { unlink $path; push @done, $e->{id}; next }
        if ( $state eq 'failed' ) {
            _audit( $docroot, $ctx{actor}, $h->{id}, 'outbox', 0, "event $e->{id}", $reason );
            _fail_entry( $docroot, $path, $e, $reason );
            push @failed, "$e->{id}: $reason";
            next;
        }
        $e->{attempts}   = ( $e->{attempts} // 0 ) + 1;
        $e->{last_error} = $reason;
        if ( $e->{attempts} >= $MAX_ATTEMPTS ) {
            _fail_entry( $docroot, $path, $e, "gave up after $e->{attempts} attempts: $reason" );
            push @failed, "$e->{id}: $reason";
            next;
        }
        $e->{next_at} = $ctx{now} + 60 * ( 2**$e->{attempts} );
        _write_entry( $path, $e );
        push @retry, "$e->{id}: $reason";
    }
    close $lk;
    return { ok => 1, detail => { done => scalar @done, retry => \@retry, failed => \@failed } };
}

1;
