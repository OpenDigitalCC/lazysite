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
    # SM1071: named by the microsecond, so the job takes two events of the same
    # second in the order they came - a fold carries them in that order.
    require Time::HiRes;
    my ( $s, $us ) = Time::HiRes::gettimeofday();
    my $path = "$dir/" . sprintf( '%d%06d', $s, $us ) . "-$id.json";
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
our $UNSUBSCRIBED   = "unsubscribed: the recipient stopped this rule's messages (SM1073)";

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
    my $c = _compose( $docroot, $h, $entry, $recipient, $channel, $base );
    return { text => $c->{text} } if $channel eq 'bell';
    return _with_footer( $c->{subject}, $c->{text}, $c );
}

# SM1071 (SM1010 R1, Q7): ONE MESSAGE FOR EVERY EVENT HELD BACK BY THE CAP.
# Each held event is composed as it would have been sent alone, in the order it
# happened, and the parts are joined: a template written for one event needs no
# change to be folded, and nothing a held event said is dropped. The Subject is
# the first event's with "(and N more)"; the unsubscribe line is added once.
sub render_folded {
    my ( $docroot, $h, $events, $recipient, $channel, $base ) = @_;
    my @parts = map { _compose( $docroot, $h, $_, $recipient, $channel, $base ) } @$events;
    my $more  = @parts - 1;
    if ( $channel eq 'bell' ) {
        my $text = join ' / ', map { $_->{text} } @parts;
        $text = ( @parts > 1 ? scalar(@parts) . ' updates: ' : '' ) . $text;
        return { text => substr( $text, 0, 400 ) };
    }
    my $subject = $parts[0]{subject} . ( $more > 0 ? " (and $more more)" : '' );
    $subject = substr( $subject, 0, 200 );
    my $text = join "\n\n----\n\n", map { $_->{text} } @parts;
    return _with_footer( $subject, $text, $parts[0] );
}

# THE ENGINE ADDS THE UNSUBSCRIBE LINE, not the template, so a template cannot
# leave it out while the rule says it is on (ruled: per rule, default on).
sub _with_footer {
    my ( $subject, $text, $c ) = @_;
    my ( $unsub, $manage ) = ( $c->{unsubscribe} // '', $c->{manage} // '' );
    $text .= "\n\n-- "                              if length $unsub || length $manage;
    $text .= "\nTo stop these messages: $unsub"     if length $unsub;
    $text .= "\nManage your subscriptions: $manage" if length $manage;
    return { subject => $subject, text => "$text\n", unsubscribe => $unsub,
        ( defined $c->{unsub_error} ? ( unsub_error => $c->{unsub_error} ) : () ) };
}

# One event as the channel shows it, before the footer: { subject, text,
# unsubscribe } for email, { text } for the bell.
sub _compose {
    my ( $docroot, $h, $entry, $recipient, $channel, $base ) = @_;
    my %fields = map { $_ => _clean_value( $entry->{fields}{$_} ) } keys %{ $entry->{fields} || {} };
    # SM1073 (SM1010 R4): the unsubscribe link is the ENGINE'S one-click link,
    # for this rule and this recipient (Lazysite::Unsubscribe); the rule's own
    # unsubscribe_path, where it names one, is offered beside it as the page
    # where a recipient manages their subscriptions.
    my ( $unsub, $manage, $unsub_error ) = ( '', '', undef );
    if ( ( $h->{unsubscribe} // 'true' ) ne 'false' && $channel eq 'email' ) {
        require Lazysite::Unsubscribe;
        my ( $t, $why ) = Lazysite::Unsubscribe::token( $docroot, $h->{id}, _hash( $recipient->{key} ) );
        if ( defined $t ) { $unsub = ( $base // '' ) . "/cgi-bin/lazysite-auth.pl?action=unsubscribe&t=$t" }
        else              { $unsub_error = "no unsubscribe link could be made: $why" }
        $manage = ( $base // '' ) . $h->{unsubscribe_path} if length( $h->{unsubscribe_path} // '' );
    }
    my %vars = (
        rule            => $h->{name} // $h->{id},
        fields          => \%fields,
        actor           => $entry->{actor}       // '',
        recipient       => $recipient->{account} // '',
        site            => $base                 // '',
        unsubscribe_url => $unsub,
        manage_url      => $manage,
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
    return { subject => $subject, text => $text, unsubscribe => $unsub, manage => $manage,
        ( defined $unsub_error ? ( unsub_error => $unsub_error ) : () ) };
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
    # SM1073: RFC 8058 one-click - the link takes a POST, so the header pair
    # says so, and a mail client may unsubscribe without opening a page.
    my %headers = length( $msg->{unsubscribe} // '' )
        ? ( 'List-Unsubscribe' => "<$msg->{unsubscribe}>", 'List-Unsubscribe-Post' => 'List-Unsubscribe=One-Click' )
        : ();
    my $r = Lazysite::Handlers::run_smtp_script( $script, {
            config => { to => $msg->{to}, ( length( $msg->{from} // '' ) ? ( from => $msg->{from} ) : () ) },
            form => {},
            message => { subject => $msg->{subject}, text => $msg->{text}, headers => \%headers },
    } );
    die( ( $r->{error} // 'no answer from the Form SMTP extension' ) . "\n" ) unless $r->{ok};
    return 1;
}

# --- one entry ---------------------------------------------------------------------

# $ok is 1 (ok), 0 (failed) or 'held' (SM1071: folded into a later message -
# neither sent nor refused, and said as neither).
#
# SM1072 (SM1010 R3): every outcome is also counted for the rule's row, so the
# Handlers page can say what the rule last did without reading the audit trail.
our %TALLY;

sub _audit {
    my ( $docroot, $actor, $rule, $channel, $ok, $who, $why ) = @_;
    my $t = $TALLY{ $rule // '' } ||= { sent => 0, held => 0, failed => 0 };
    $t->{ $ok eq 'held' ? 'held' : $ok ? 'sent' : 'failed' }++;
    $t->{problem} = $who . ( length( $why // '' ) ? " - $why" : '' ) if !$ok;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = _lz_of($docroot);
        Lazysite::Audit::audit_log( $actor, 'notify', "notify:$rule -> $channel", '',
            ( $ok eq 'held' ? 'held' : $ok ? 'ok' : 'failed' ), 'daemon',
            $who . ( length( $why // '' ) ? " - $why" : '' ) );
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

    $list = _without_actor( $h, $entry, $accounts, $list );

    my @channels = grep { length } split /\s*,\s*/, ( $h->{channels} // 'email' );
    my $cap      = _cap($h);
    my $now      = $ctx->{now};
    my %done     = map { ( $_->{k} // '' ) => 1 } @$ledger;
    my $used     = _used( $ledger, $now );

    my $unsub_on = ( $h->{unsubscribe} // 'true' ) ne 'false';
    return ( 'failed', 'unsubscribe is on and this site has no absolute address for the link - '
            . 'set the Site URL on the Config page ("Use this address"), or turn unsubscribe off' )
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
                _mark_ledger( $docroot, $ledger, { k => $k, r => $h->{id}, c => $ch, p => $p, s => $state, t => $now, e => $entry->{id} } );
            };

            # SM1073 (SM1010 R4): A RECIPIENT WHO STOPPED THIS RULE IS NOT
            # WRITTEN TO BY IT, on any channel - and is told nothing more.
            if ( ( $ctx->{suppressed} || {} )->{"$h->{id}\0$p"} ) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), $UNSUBSCRIBED );
                $mark->('refused');
                next;
            }

            # SM1071 (SM1010 R1, Q7): OVER THE CAP, THE EVENT IS HELD, NOT
            # REFUSED - and so is every later one while something is held, so
            # the recipient gets them in order, in one message, when the cap
            # next allows. A cap of 0 sends nothing, so nothing is held for it.
            my $fold = _fold_path( $docroot, $h->{id}, $ch, $r->{key} );
            my $over = ( $used->{ $h->{id} . "\0$ch\0$p" } // 0 ) >= $cap;
            if ( $cap > 0 && ( $over || -e $fold ) ) {
                my ( $state, $why ) = _fold_add( $fold, $h, $ch, $r, $entry, $now );
                if ( $state eq 'held' ) {
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 'held', _who($r),
                        $over
                        ? "held: the per-recipient cap ($cap an hour, per_recipient_hour) is reached, "
                            . 'so this is folded into the next message'
                        : 'held: folded into the next message, after those already held' );
                    $mark->('folded');
                }
                elsif ( $state eq 'full' ) {
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), $why );
                    $mark->('refused');
                }
                else {
                    $transient ||= $why;
                    _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), "will retry: $why" );
                }
                next;
            }
            if ($over) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r),
                    "the per-recipient cap ($cap an hour, per_recipient_hour) is reached" );
                $mark->('refused');
                next;
            }
            my $out = render( $docroot, $h, $entry, $r, $ch, $base );
            my ( $state, $why ) = _send_one( $docroot, $h, $r, $ch, $out, $accounts );
            if ( $state eq 'sent' ) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 1, _who($r) );
                $used->{ $h->{id} . "\0$ch\0$p" }++;
                $mark->('sent');
            }
            elsif ( $state eq 'refused' ) {
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r), $why );
                $mark->('refused');
            }
            else {
                $transient ||= $why;
                _audit( $docroot, $ctx->{actor}, $h->{id}, $ch, 0, _who($r),
                    ( $ch eq 'bell' ? $why : "will retry: $why" ) );
            }
        }
    }
    return length $transient ? ( 'retry', $transient ) : ( 'done', '' );
}

# NOTHING TO THE ACCOUNT THAT CAUSED THE EVENT, unless the rule asks: the
# account itself, and its own address where an address source holds it.
sub _without_actor {
    my ( $h, $entry, $accounts, $list ) = @_;
    my $actor = $entry->{actor} // '';
    return $list unless length $actor && ( $h->{notify_actor} // 'false' ) ne 'true';
    my $mine = lc( ( ref $accounts->{$actor} eq 'HASH' ? $accounts->{$actor}{email} : '' ) // '' );
    return [ grep {
            !( defined $_->{account} && $_->{account} eq $actor )
            && !( defined $_->{address} && length $mine && lc( $_->{address} ) eq $mine )
    } @$list ];
}

sub _cap {
    my ($h) = @_;
    my $cap = $h->{per_recipient_hour};
    return ( defined $cap && $cap =~ /\A\d+\z/ ) ? $cap : 3;
}

# Messages sent in the last hour, per rule / channel / recipient hash.
sub _used {
    my ( $ledger, $now ) = @_;
    my %used;
    for my $l (@$ledger) {
        next unless ( $l->{s} // '' ) eq 'sent' && ( $l->{t} // 0 ) >= $now - 3600;
        $used{ ( $l->{r} // '' ) . "\0" . ( $l->{c} // '' ) . "\0" . ( $l->{p} // '' ) }++;
    }
    return \%used;
}

sub _mark_ledger {
    my ( $docroot, $ledger, $rec ) = @_;
    push @$ledger, $rec;
    _append_ledger( $docroot, $rec )
        or log_event( 'WARN', 'notify', 'could not write the notification ledger; a retry may resend',
        rule => $rec->{r} );
    return;
}

# Send one composed message to one recipient on one channel:
# ( 'sent' ), ( 'refused', $why ) - final - or ( 'retry', $why ).
sub _send_one {
    my ( $docroot, $h, $r, $ch, $out, $accounts ) = @_;
    # SM1073: a message the rule says carries an unsubscribe link is not sent
    # without one.
    return ( 'retry', $out->{unsub_error} ) if defined $out->{unsub_error};
    if ( $ch eq 'bell' ) {
        require Lazysite::Notify;
        my $ok = Lazysite::Notify::bell_for( $docroot, $r->{account},
            { type => 'rule', message => $out->{text}, target => $h->{id} } );
        return $ok ? ('sent') : ( 'retry', 'the bell store could not be written' );
    }
    my $addr = $r->{address};
    if ( defined $r->{account} ) {
        my $a = $accounts->{ $r->{account} };
        $addr = ref $a eq 'HASH' ? $a->{email} : undef;
        return ( 'refused', ( ref $a eq 'HASH' ? 'the account has no address' : 'there is no such account' ) )
            if !defined $addr || !length $addr;
    }
    require Lazysite::Mail;
    my ( $one, $bad ) = Lazysite::Mail::one_address($addr);
    return ( 'refused', "refused: $bad" ) unless defined $one;
    my $sent = eval {
        $MAIL_SENDER->( $docroot, { %$out, to => $one, from => $h->{from} } );
        1;
    };
    return ('sent') if $sent;
    ( my $err = $@ || 'the transport gave no reason' ) =~ s/\s+\z//;
    # A refusal of the ADDRESS is final; anything else may pass on a retry.
    return ( $err =~ /is refused:/ ? 'refused' : 'retry', $err );
}

# --- folding (SM1071, SM1010 R1) -------------------------------------------------
#
# Q7, as ruled: per event, one message per recipient per hour per rule, and the
# events past the cap folded into the next message. A fold is one file per rule,
# channel and recipient under notify/folds/, named by a hash of the three; it
# holds the events in the order they came and, for an address recipient, the
# address - as an outbox entry holds its fields - only until it is sent. The
# job sends it when the recipient's cap next allows, as ONE message, counted
# against the cap like any other.

our $MAX_FOLDED = 50;    # events one fold holds; past it, an event is refused and audited

sub folds_dir { return _lz_of( $_[0] ) . '/notify/folds' }

sub _fold_path {
    my ( $docroot, $rule, $ch, $key ) = @_;
    return folds_dir($docroot) . '/' . _hash( 'fold', $rule, $ch, $key ) . '.json';
}

# ( 'held' ), ( 'full', $why ) or ( 'error', $why ).
sub _fold_add {
    my ( $path, $h, $ch, $r, $entry, $now ) = @_;
    my $f = _read_entry($path);
    return ( 'error', 'a held message could not be read' ) unless defined $f;
    $f = undef if !ref $f || $f->{_torn};
    my %who = ( key => $r->{key}, map { defined $r->{$_} ? ( $_ => $r->{$_} ) : () } qw(account address) );
    $f //= {
        rule      => $h->{id},
        channel   => $ch,
        recipient => \%who,
        created   => $now,
        attempts  => 0,
        next_at   => 0,
        events    => [],
    };
    return ('held') if grep { ( $_->{id} // '' ) eq $entry->{id} } @{ $f->{events} };
    return ( 'full', "the held message already folds $MAX_FOLDED events; this one is not sent" )
        if @{ $f->{events} } >= $MAX_FOLDED;
    push @{ $f->{events} }, { map { ( $_ => $entry->{$_} ) } qw(id created actor fields) };
    eval { make_path( dirname($path) ) unless -d dirname($path); 1 }
        or return ( 'error', 'cannot create the folds directory' );
    return _write_entry( $path, $f ) ? ('held') : ( 'error', 'a held message could not be written' );
}

sub _fold_files {
    my ($docroot) = @_;
    my $dir = folds_dir($docroot);
    opendir my $dh, $dir or return $!{ENOENT} ? [] : cannot_read( 'the held notifications', $dir );
    my @f = sort grep { /\A[0-9a-f]{24}\.json\z/ } readdir $dh;
    closedir $dh;
    return [ map { "$dir/$_" } @f ];
}

# Send every fold whose recipient's cap now allows it. Returns
# { sent => n, waiting => n, retry => [...], failed => [...] }.
sub _flush_folds {
    my ( $docroot, $files, $handlers, $ctx, $ledger, $accounts, $base ) = @_;
    my $now  = $ctx->{now};
    my $used = _used( $ledger, $now );
    my %out  = ( sent => 0, waiting => 0, retry => [], failed => [] );
    for my $path (@$files) {
        my $f = _read_entry($path);
        next if defined $f && !ref $f;    # gone since the listing
        unless ( defined $f ) { push @{ $out{retry} }, "$path: unreadable"; next }
        if ( $f->{_torn} || ref $f->{events} ne 'ARRAY' || ref $f->{recipient} ne 'HASH' ) {
            _fail_entry( $docroot, $path, ( $f->{_torn} ? {} : $f ), 'a held message is not readable JSON' );
            push @{ $out{failed} }, 'torn fold';
            next;
        }
        next if ( $f->{next_at} // 0 ) > $now;
        my $r    = $f->{recipient};
        my $ch   = $f->{channel} // 'email';
        my $rule = $f->{rule}    // '';
        my $h    = Lazysite::Handlers::find_handler( $handlers, $rule );
        my $why
            = !$h                              ? "no rule '$rule'"
            : ( $h->{type} // '' ) ne 'notify' ? "handler '$rule' is not a notify rule"
            : !Lazysite::Handlers::enabled($h) ? "rule '$rule' is switched off"
            :                                    '';
        if ( length $why ) {
            _audit( $docroot, $ctx->{actor}, $rule, $ch, 0, _who($r), "a held message is not sent: $why" );
            _fail_entry( $docroot, $path, $f, $why );
            push @{ $out{failed} }, "fold: $why";
            next;
        }
        my $p = _hash( $r->{key} );
        # SM1073: stopped since it was held - the held message is not sent.
        if ( ( $ctx->{suppressed} || {} )->{"$rule\0$p"} ) {
            _audit( $docroot, $ctx->{actor}, $rule, $ch, 0, _who($r), "a held message is not sent: $UNSUBSCRIBED" );
            unlink $path;
            next;
        }
        if ( ( $used->{ $rule . "\0$ch\0$p" } // 0 ) >= _cap($h) ) { $out{waiting}++; next }

        my $msg = render_folded( $docroot, $h, $f->{events}, $r, $ch, $base );
        my ( $state, $err ) = _send_one( $docroot, $h, $r, $ch, $msg, $accounts );
        my $n = scalar @{ $f->{events} };
        if ( $state eq 'sent' || $state eq 'refused' ) {
            my $k = _hash( $rule, 'fold', join( ',', map { $_->{id} // '' } @{ $f->{events} } ), $ch, $r->{key} );
            _mark_ledger( $docroot, $ledger,
                { k => $k, r => $rule, c => $ch, p => $p, s => $state, t => $now } );
            if ( $state eq 'sent' ) {
                _audit( $docroot, $ctx->{actor}, $rule, $ch, 1, _who($r),
                    "the held message, folding $n event" . ( $n == 1 ? '' : 's' ) );
                $used->{ $rule . "\0$ch\0$p" }++;
                $out{sent}++;
            }
            else {
                _audit( $docroot, $ctx->{actor}, $rule, $ch, 0, _who($r), $err );
                push @{ $out{failed} }, "fold: $err";
            }
            unlink $path;
            next;
        }
        $f->{attempts}   = ( $f->{attempts} // 0 ) + 1;
        $f->{last_error} = $err;
        _audit( $docroot, $ctx->{actor}, $rule, $ch, 0, _who($r), "will retry the held message: $err" );
        if ( $f->{attempts} >= $MAX_ATTEMPTS ) {
            _fail_entry( $docroot, $path, $f, "gave up after $f->{attempts} attempts: $err" );
            push @{ $out{failed} }, "fold: $err";
            next;
        }
        $f->{next_at} = $now + 60 * ( 2**$f->{attempts} );
        _write_entry( $path, $f );
        push @{ $out{retry} }, "fold: $err";
    }
    return \%out;
}

# --- the job -------------------------------------------------------------------------

sub _entry_files {
    my ($docroot) = @_;
    my $dir = outbox_dir($docroot);
    opendir my $dh, $dir or return $!{ENOENT} ? [] : cannot_read( 'the notification outbox', $dir );
    my @f = grep { /\A\d+-[0-9a-f]{16}\.json\z/ } readdir $dh;
    closedir $dh;
    # Oldest first. An entry queued before SM1071 is named by the second, a
    # later one by the microsecond; both are read as microseconds.
    my %at = map { my ($n) = /\A(\d+)/; ( $_ => ( length $n > 10 ? $n : $n * 1_000_000 ) ) } @f;
    return [ map { "$dir/$_" } sort { $at{$a} <=> $at{$b} || $a cmp $b } @f ];
}

# SM1093 (0.15.5 test plan T4): what a rule left unsent - its outbox entries
# (queued, or retrying) and its held messages (folds). Returns the paths of
# those whose rule satisfies $match, or undef when either directory will not
# read (cannot_read has logged it): "could not tell" is not "none".
sub _unsent_of {
    my ( $docroot, $match ) = @_;
    my $files = _entry_files($docroot);
    my $folds = _fold_files($docroot);
    return unless defined $files && defined $folds;
    my @hit;
    for my $p ( @$files, @$folds ) {
        my $e = _read_entry($p);
        next unless ref $e && !$e->{_torn}; # gone since the listing, or torn: the job fails a torn one
        push @hit, $p if $match->( $e->{rule} // '' );
    }
    return \@hit;
}

# The rule is being deleted: its unsent entries go with it, because a delete
# that left them listed in the outbox (field report, SM1093: three for each of
# two rules) left events nobody could send and nobody could clear. Sent history
# (the ledger) and the failed record are not touched. Returns the count
# removed, or undef when the outbox could not be read.
sub purge_rule {
    my ( $docroot, $rule ) = @_;
    my $hit = _unsent_of( $docroot, sub { $_[0] eq $rule } ) // return;
    my $n   = 0;
    for my $p (@$hit) { $n++ if unlink $p }
    return $n;
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
    local %TALLY = ();

    my $files = _entry_files($docroot);
    return { ok => 0, error => 'the notification outbox could not be read; see the log' }
        unless defined $files;
    my $folds = _fold_files($docroot);
    return { ok => 0, error => 'the held notifications could not be read; see the log' }
        unless defined $folds;
    return { ok => 1, detail => { queued => 0 } } unless @$files || @$folds;

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

    # SM1073: who said stop. Read once, before anything is sent; a store that
    # exists and will not open stops the run, as the ledger does - "could not
    # tell who unsubscribed" is not "nobody did".
    require Lazysite::Unsubscribe;
    $ctx{suppressed} = Lazysite::Unsubscribe::suppressed($docroot);
    return { ok => 0, error => 'the unsubscribe store exists and could not be read, so nothing '
            . 'was sent - sending without it could write to someone who said stop; see the log' }
        unless defined $ctx{suppressed};

    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;
    # SM1093: entries and held messages whose rule is no longer in handlers.conf
    # (deleted before the delete took them along) are not sent - there is no
    # rule to say how. The loops below already give such an entry up (audited,
    # kept with the failed ones, SM1071), but only when they reach it: not past
    # the per-tick cap, not before its retry time. So they are given up here,
    # first and together, with one log line naming the count. Only a rule that
    # is gone: one switched off or retyped keeps its queue and is failed below,
    # with the reason.
    my $orphans = _unsent_of( $docroot, sub { !Lazysite::Handlers::find_handler( $handlers, $_[0] ) } ) // [];
    my %gone    = map { $_ => 1 } @$orphans;
    my $cleared = 0;
    for my $p (@$orphans) {
        my $e = _read_entry($p);
        next unless ref $e && !$e->{_torn};
        my $why = "no rule '" . ( $e->{rule} // '' ) . "'";
        if ( ref $e->{events} eq 'ARRAY' ) {    # a held message
            _audit( $docroot, $ctx{actor}, $e->{rule} // '', $e->{channel} // 'email', 0,
                _who( $e->{recipient} || {} ), "a held message is not sent: $why" );
        }
        else { _audit( $docroot, $ctx{actor}, $e->{rule} // '', 'outbox', 0, "event $e->{id}", $why ) }
        _fail_entry( $docroot, $p, $e, $why );
        $cleared++;
    }
    log_event( 'INFO', 'notify', "cleared $cleared notification(s) queued for rules that no longer exist" )
        if $cleared;
    $files = [ grep { !$gone{$_} } @$files ];

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
        if ( $state eq 'done' ) {
            # SM1105: the ledger already says it went, so an entry that stays
            # cannot go twice - but it must not stay unsaid.
            unlink $path
                or log_event( 'WARN', 'notify', 'could not remove a sent notification from the outbox',
                rule => $e->{rule} // '', id => $e->{id} // '', why => "$!" );
            push @done, $e->{id};
            next;
        }
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

    # SM1071: then what the cap held back, now that the hour may have moved on -
    # listed again, because the entries above may have started a fold.
    my $held = { sent => 0, waiting => 0, retry => [], failed => [] };
    if ( my $now_folds = _fold_files($docroot) ) {
        $held = _flush_folds( $docroot, $now_folds, $handlers, \%ctx, $ledger, $accounts, $base ) if @$now_folds;
    }
    else { push @retry, 'the held notifications could not be read' }
    push @retry,  @{ $held->{retry} };
    push @failed, @{ $held->{failed} };
    _write_status( $docroot, \%TALLY, $ctx{now} ) if %TALLY;
    close $lk;
    return { ok => 1, detail => { done => scalar @done, retry => \@retry, failed => \@failed,
            held_sent => $held->{sent}, held_waiting => $held->{waiting}, orphans_cleared => $cleared } };
}


# --- what the manager is shown (SM1072, SM1010 R3) -------------------------------
#
# Q5 as ruled: delivery is queued only, and a site whose daemon is not running
# shows "waiting for the scheduler" on the rule's row rather than sending inline.
# R3 found the row showed nothing - no waiting, no last outcome - and the outbox
# and notify/failed/ were visible only on the filesystem.
#
# notify/status.json: per rule, what its last run did - counts of sent, held and
# failed rows, and the last failure with its time, kept until a later one
# replaces it. Written by the job, under its lock, and read here; a convenience
# beside the audit trail, which stays the record.

sub status_file { return _lz_of( $_[0] ) . '/notify/status.json' }

# { rule => {...} }, {} when there is none, or undef when it will not open.
sub _read_status {
    my ($docroot) = @_;
    my $f = status_file($docroot);
    open my $fh, '<:raw', $f or return $!{ENOENT} ? {} : cannot_read( 'the notification status', $f );
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $s = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $s eq 'HASH' ? $s : {};
}

sub _write_status {
    my ( $docroot, $tally, $now ) = @_;
    my $s = _read_status($docroot);
    return unless defined $s;    # SM785: what could not be read is not overwritten
    for my $rule ( keys %$tally ) {
        next unless length $rule;
        my $t    = $tally->{$rule};
        my $prev = ref $s->{$rule} eq 'HASH' ? $s->{$rule} : {};
        $s->{$rule} = {
            last_run => $now,
            sent     => $t->{sent}   // 0,
            held     => $t->{held}   // 0,
            failed   => $t->{failed} // 0,
            ( defined $t->{problem}
                ? ( problem => $t->{problem}, problem_at => $now )
                : map { defined $prev->{$_} ? ( $_ => $prev->{$_} ) : () } qw(problem problem_at) ),
        };
    }
    _write_entry( status_file($docroot), $s )
        or log_event( 'WARN', 'notify', 'could not write the notification status', file => status_file($docroot) );
    return;
}

# SM1105 (0.15.6 R2): what the ledger says went, per event: { id => 'sent' |
# 'handled' } ('handled': refused, or folded into a held message - decided, not
# sent). The ledger is what stops an event going twice, so it knows an entry the
# job sent and could not remove (the unlink failed), which the list showed as
# queued beside a rule row that said it had sent 3. An entry never retried was
# handled whole in one pass, so a ledger row for it means it is not waiting.
# Rows from before the event id was recorded say nothing here.
sub _ledger_events {
    my ($docroot) = @_;
    my %by_event;
    for my $l ( @{ _read_ledger($docroot) // [] } ) {
        next unless defined $l->{e};
        $by_event{ $l->{e} } = 'sent' if ( $l->{s} // '' ) eq 'sent';
        $by_event{ $l->{e} } //= 'handled';
    }
    return \%by_event;
}

our $WAIT_AFTER = 180;    # three ticks of the job: past this, a queued event is waiting

# Everything the outbox holds, read once: { ok => 1, entries => [...], held =>
# [...], job => {...} } or { ok => 0, error }. An entry carries its rule, so a
# caller decides what it may show (outbox_list) - this reads, it does not filter.
sub _outbox_read {
    my ($docroot) = @_;
    my $files = _entry_files($docroot);
    return { ok => 0, error => 'the notification outbox could not be read; see the log' } unless defined $files;
    my $folds = _fold_files($docroot);
    return { ok => 0, error => 'the held notifications could not be read; see the log' } unless defined $folds;
    my $fdir = failed_dir($docroot);
    my @failed;
    if ( opendir my $dh, $fdir ) {
        @failed = map { "$fdir/$_" } sort grep { /\.json\z/ } readdir $dh;
        closedir $dh;
    }
    elsif ( !$!{ENOENT} ) {
        cannot_read( 'the failed notifications', $fdir );
        return { ok => 0, error => 'the failed notifications could not be read; see the log' };
    }
    my %by_event = %{ _ledger_events($docroot) };
    my ( @entries, @held );
    for my $p (@$files) {
        my $e = _read_entry($p);
        next unless ref $e && !$e->{_torn};
        my $state = ( $e->{attempts} // 0 ) > 0 ? 'retrying' : 'queued';
        $state = $by_event{ $e->{id} // '' } if $state eq 'queued' && $by_event{ $e->{id} // '' };
        push @entries, { %$e, state => $state };
    }
    for my $p (@$folds) {
        my $f = _read_entry($p);
        next unless ref $f && !$f->{_torn} && ref $f->{events} eq 'ARRAY';
        push @held, { %$f, state => 'held' };
    }
    for my $p (@failed) {
        my $e = _read_entry($p);
        next unless ref $e && !$e->{_torn};
        if   ( ref $e->{events} eq 'ARRAY' ) { push @held,    { %$e, state => 'failed' } }
        else                                 { push @entries, { %$e, state => 'failed' } }
    }
    my $job = {};
    eval {
        require Lazysite::Daemon::Service::Scheduler;
        my $runs = Lazysite::Daemon::Service::Scheduler::run_record($docroot);
        $job = $runs->{'notify-outbox'} if ref $runs eq 'HASH' && ref $runs->{'notify-outbox'} eq 'HASH';
        1;
    };
    return { ok => 1, entries => \@entries, held => \@held, job => $job };
}

# Why a queued event has not gone, or '' when nothing says it is stuck: the
# scheduler refuses the job, has never run it, or last ran it too long ago.
sub _waiting {
    my ( $job, $oldest_due, $now ) = @_;
    return '' unless defined $oldest_due && $now - $oldest_due > $WAIT_AFTER;
    if ( ( $job->{outcome} // '' ) eq 'refused' ) {
        return 'waiting for the scheduler: it refuses the notify-outbox job - '
            . ( $job->{refusal_reason} // 'no reason recorded' );
    }
    my $last = $job->{last_run};
    return 'waiting for the scheduler: the notify-outbox job has never run - is the daemon running?'
        unless $last;
    return '' unless $now - $last > $WAIT_AFTER;
    return 'waiting for the scheduler: the notify-outbox job last ran '
        . int( ( $now - $last ) / 60 ) . ' minutes ago - is the daemon running?';
}

# Per rule, for the Handlers page's row: { rule => { queued, retrying, failed,
# held, waiting, last } }, or undef when the outbox cannot be read.
sub rule_states {
    my ( $docroot, $now ) = @_;
    $now //= time;
    my $o = _outbox_read($docroot);
    return undef unless $o->{ok};
    my $status = _read_status($docroot) // {};
    my %s;
    my $row = sub { $s{ $_[0] } ||= { queued => 0, retrying => 0, failed => 0, held => 0 } };
    my %oldest;
    for my $e ( @{ $o->{entries} } ) {
        my $r = $row->( $e->{rule} // '' );
        next if $e->{state} eq 'sent' || $e->{state} eq 'handled'; # SM1105: it went; the job could not remove it
        $r->{ $e->{state} eq 'failed' ? 'failed' : 'queued' }++;
        $r->{retrying}++ if $e->{state} eq 'retrying';
        next             if $e->{state} eq 'failed';
        my $due = ( $e->{next_at} // 0 ) > ( $e->{created} // 0 ) ? $e->{next_at} : $e->{created};
        $oldest{ $e->{rule} // '' } = $due
            if defined $due && ( !defined $oldest{ $e->{rule} // '' } || $due < $oldest{ $e->{rule} // '' } );
    }
    for my $f ( @{ $o->{held} } ) {
        my $r = $row->( $f->{rule} // '' );
        $r->{ $f->{state} eq 'failed' ? 'failed' : 'held' }++;
    }
    for my $rule ( keys %$status ) { $row->($rule)->{last} = $status->{$rule} if ref $status->{$rule} eq 'HASH' }
    for my $rule ( keys %s ) {
        my $w = _waiting( $o->{job}, $oldest{$rule}, $now );
        $s{$rule}{waiting} = $w if length $w;
    }
    return \%s;
}

# The outbox, for the manager and an agent holding manage_notifications:
#   outbox_list( docroot => ..., may_see => sub { $handler_or_undef } -> bool,
#                rule => <only this rule>, id => <one event, with its recipients> )
#
# IT SHOWS RECIPIENTS - the accounts and addresses an event resolves to, and the
# fields it carries - so it is behind manage_notifications on both doors, and
# may_see is the caller's domain rule: a confined caller sees only the rules of
# its own domains (Manager::Common::handler_reach_refusal).
our $MAX_LISTED = 200;

sub outbox_list {
    my (%a)     = @_;
    my $docroot = $a{docroot};
    my $now     = $a{now} // time;
    my $may     = ref $a{may_see} eq 'CODE' ? $a{may_see} : sub { 1 };
    return { ok => 0, kind => 'invalid', field => 'rule', error => 'rule must be a handler id' }
        if defined $a{rule} && length $a{rule} && $a{rule} !~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id must be an event id (16 hex characters)' }
        if defined $a{id} && length $a{id} && $a{id} !~ /\A[0-9a-f]{16}\z/;
    my $o = _outbox_read($docroot);
    return $o unless $o->{ok};
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;
    my %seen_rule;
    my $visible = sub {
        my ($rule) = @_;
        $rule //= '';
        return 0 if defined $a{rule} && length $a{rule} && $rule ne $a{rule};
        $seen_rule{$rule} //= $may->( Lazysite::Handlers::find_handler( $handlers, $rule ) ) ? 1 : 0;
        return $seen_rule{$rule};
    };

    if ( defined $a{id} && length $a{id} ) {
        my ($e) = grep { ( $_->{id} // '' ) eq $a{id} && $visible->( $_->{rule} ) } @{ $o->{entries} };
        return { ok => 0, kind => 'not-found', error => "no event '$a{id}' in the outbox you can see" } unless $e;
        return { ok => 1, entry => _entry_view($e), recipients => _recipients_view( $docroot, $handlers, $e ) };
    }

    my @entries = map { _entry_view($_) } grep { $visible->( $_->{rule} ) } @{ $o->{entries} };
    my @held = map { _held_view($_) } grep { $visible->( $_->{rule} ) } @{ $o->{held} };
    my $more = @entries > $MAX_LISTED ? @entries - $MAX_LISTED : 0;
    splice @entries, $MAX_LISTED if $more;
    my $oldest;
    for ( grep { $_->{state} ne 'failed' && $_->{state} ne 'sent' && $_->{state} ne 'handled' } @entries ) { $oldest = $_->{due} if !defined $oldest || $_->{due} < $oldest }
    my $w = _waiting( $o->{job}, $oldest, $now );
    return { ok => 1, entries => \@entries, held => \@held, ( $more ? ( not_listed => $more ) : () ),
        job => { map { defined $o->{job}{$_} ? ( $_ => $o->{job}{$_} ) : () } qw(last_run outcome reason refusal_reason refused_at) },
        ( length $w ? ( waiting => $w ) : () ) };
}

# Retry now (SM1107, 0.15.6 test plan U8): "After a transport fix, entries sit in
# backoff for minutes ... A 'retry now' for the operator would make a mail fix
# testable without posting fresh events."
#   outbox_retry( docroot => ..., id => <one event> | rule => <every waiting event of it>,
#                 may_see => sub { $handler_or_undef } -> bool, now => ... )
# makes the waiting (retrying) entries due now, and nothing else: the job still
# sends them, on its next tick, under every rule it always applies - so the
# per-recipient cap and a held fold are not bypassed (a held message is left
# and counted), an entry the ledger says went is not made due again, and a
# given-up one (failed) stays given up. The attempts are kept: an entry that
# fails again is given up when it reaches the limit, as it would have been.
# Returns { ok => 1, retried, already_due, sent, held, failed, ids } or
# { ok => 0, kind, error }. It writes entries, so it takes the job's own lock;
# while the job runs it answers busy rather than race it.
sub outbox_retry {
    my (%a)      = @_;
    my $docroot  = $a{docroot};
    my $now      = $a{now} // time;
    my $may      = ref $a{may_see} eq 'CODE' ? $a{may_see} : sub { 1 };
    my $has_rule = defined $a{rule} && length $a{rule};
    my $has_id   = defined $a{id}   && length $a{id};
    return { ok => 0, kind => 'invalid', field => 'rule', error => 'give a rule, or an event id' }
        unless $has_rule || $has_id;
    return { ok => 0, kind => 'invalid', field => 'rule', error => 'rule must be a handler id' }
        if $has_rule && $a{rule} !~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id must be an event id (16 hex characters)' }
        if $has_id && $a{id} !~ /\A[0-9a-f]{16}\z/;

    my $files = _entry_files($docroot);
    return { ok => 0, error => 'the notification outbox could not be read; see the log' } unless defined $files;
    my $folds = _fold_files($docroot);
    return { ok => 0, error => 'the held notifications could not be read; see the log' } unless defined $folds;

    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;
    my %seen;
    my $visible = sub {
        my ($rule) = @_;
        $rule //= '';
        return 0 if $has_rule && $rule ne $a{rule};
        $seen{$rule} //= $may->( Lazysite::Handlers::find_handler( $handlers, $rule ) ) ? 1 : 0;
        return $seen{$rule};
    };

    my $dir = _lz_of($docroot) . '/notify';
    eval { make_path($dir) unless -d $dir; 1 } or return { ok => 0, error => "cannot create the notify directory: $!" };
    open my $lk, '>>', "$dir/.run.lock" or return { ok => 0, error => "cannot open the outbox lock: $!" };
    return { ok => 0, kind => 'busy', error => 'the notification job is running; try again in a moment' }
        unless flock $lk, LOCK_EX | LOCK_NB;

    my $went = _ledger_events($docroot);
    my %n    = ( retried => 0, already_due => 0, sent => 0, held => 0, failed => 0 );
    my ( @ids, $found );
    for my $p (@$files) {
        my $e = _read_entry($p);
        next unless ref $e && !$e->{_torn};
        next if $has_id && ( $e->{id} // '' ) ne $a{id};
        next unless $visible->( $e->{rule} );
        $found++;
        if ( ( $e->{attempts} // 0 ) == 0 && $went->{ $e->{id} // '' } ) { $n{sent}++; next }
        if ( ( $e->{next_at} // 0 ) <= $now ) { $n{already_due}++; next }
        $e->{next_at} = 0;
        if ( _write_entry( $p, $e ) ) { $n{retried}++; push @ids, $e->{id} }
        else { close $lk; return { ok => 0, error => "could not update the outbox entry '$e->{id}'; see the log" } }
    }
    unless ($has_id) {
        for my $p (@$folds) {
            my $f = _read_entry($p);
            next unless ref $f && !$f->{_torn} && $visible->( $f->{rule} );
            $n{held}++;
        }
    }
    my $failed = failed_dir($docroot);
    if ( opendir my $dh, $failed ) {
        for my $leaf ( grep { /\.json\z/ } readdir $dh ) {
            my $e = _read_entry("$failed/$leaf");
            next unless ref $e && !$e->{_torn} && ref $e->{events} ne 'ARRAY';
            next if $has_id && ( $e->{id} // '' ) ne $a{id};
            if ( $visible->( $e->{rule} ) ) { $n{failed}++; $found++ }
        }
        closedir $dh;
    }
    close $lk;
    return { ok => 0, kind => 'not-found', error => "no event '$a{id}' in the outbox you can see" }
        if $has_id && !$found;
    return { ok => 1, %n, ids => \@ids };
}

sub _entry_view {
    my ($e) = @_;
    my $due = ( $e->{next_at} // 0 ) > ( $e->{created} // 0 ) ? $e->{next_at} : ( $e->{created} // 0 );
    return {
        id       => $e->{id}   // '',
        rule     => $e->{rule} // '',
        state    => $e->{state},
        created  => $e->{created} // 0,
        due      => $due,
        attempts => $e->{attempts} // 0,
        actor    => $e->{actor}    // '',
        origin   => $e->{origin}   // '',
        source   => $e->{source}   // '',
        fields   => ( ref $e->{fields} eq 'HASH' ? $e->{fields} : {} ),
        ( defined $e->{last_error} ? ( last_error => $e->{last_error} ) : () ),
        ( defined $e->{failed}     ? ( reason     => $e->{failed} )     : () ),
    };
}

sub _held_view {
    my ($f) = @_;
    my $r = ref $f->{recipient} eq 'HASH' ? $f->{recipient} : {};
    return {
        rule    => $f->{rule} // '',
        state   => $f->{state},
        channel => $f->{channel} // '',
        recipient => ( defined $r->{account} ? "account $r->{account}" : 'address ' . ( $r->{address} // '?' ) ),
        events => scalar @{ $f->{events} || [] },
        since  => $f->{created} // 0,
        ( defined $f->{last_error} ? ( last_error => $f->{last_error} ) : () ),
        ( defined $f->{failed}     ? ( reason     => $f->{failed} )     : () ),
    };
}

# Who an event resolves to NOW, under the rule as it stands, and what the ledger
# says was decided for each on each channel: sent, refused, held, or pending.
sub _recipients_view {
    my ( $docroot, $handlers, $e ) = @_;
    my $h = Lazysite::Handlers::find_handler( $handlers, $e->{rule} // '' );
    return { error => "no rule '" . ( $e->{rule} // '' ) . "'" } unless $h && ( $h->{type} // '' ) eq 'notify';
    my ($sources) = parse_recipients( $h->{recipients} );
    return { error => 'the rule has no usable recipient list' } unless $sources;
    my $accounts = _accounts($docroot);
    return { error => 'the account store could not be read' } unless defined $accounts;
    my ( $list, $why ) = resolve( $docroot, $sources, $e, $accounts );
    return { error => $why } unless $list;
    $list = _without_actor( $h, $e, $accounts, $list );
    my $ledger = _read_ledger($docroot) // [];
    my %state  = map { ( $_->{k} // '' ) => ( $_->{s} // '' ) } @$ledger;
    require Lazysite::Unsubscribe;
    my $stopped = Lazysite::Unsubscribe::suppressed($docroot) // {};
    my @ch      = grep { length } split /\s*,\s*/, ( $h->{channels} // 'email' );
    my @out;
    for my $r (@$list) {
        my %by;
        for my $c (@ch) {
            next if $c eq 'bell' && !defined $r->{account};
            my $s = $state{ _hash( $h->{id}, $e->{id}, $c, $r->{key} ) } // 'pending';
            $s = 'unsubscribed' if $s eq 'pending' && $stopped->{ "$h->{id}\0" . _hash( $r->{key} ) };
            $by{$c} = $s eq 'folded' ? 'held' : $s;
        }
        push @out, { who => _who($r), channels => \%by };
    }
    return { list => \@out };
}

1;
