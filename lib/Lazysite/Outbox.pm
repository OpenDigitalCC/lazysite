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
    my $ok = print {$fh} JSON::PP->new->canonical->encode( \%entry );
    unless ( close($fh) && $ok ) { unlink $tmp; return { ok => 0, why => "the outbox write did not complete: $!" } }
    unless ( rename $tmp, $path ) { unlink $tmp; return { ok => 0, why => "cannot place the outbox entry: $!" } }
    return { ok => 1, queued => $id };
}

1;
