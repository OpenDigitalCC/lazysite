package Odoo::Ops::Mailing::Common;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);
use Time::Local qw(timegm);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Match;
use Odoo::Ops::Mailing::Plaintext;
use Odoo::Ops::Rows;
use Odoo::Ops::Source;

=head1 NAME

Odoo::Ops::Mailing::Common - what the mailing operations share

=head1 DESCRIPTION

Not an operation: plain functions the C<mailing.*> operations call, so
that the series gate, the address rule and the row reading are written
once.

=head2 ready($op)

The mailing profile for this server, or a refusal. The pack has a profile
for Odoo 16 and one for 18. A series with no profile of its own is refused
by name (C<series>): the registry's fallback to the nearest lower profile is
right for a pack whose model has not changed, but nothing here was probed on
any series but 16 and 18, so loading the 18 file for a 19 server would be a
guess. The profile is then checked against the live C<fields_get>
(C<profile> when a mapped model or field is missing).

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    my $p      = $op->profile;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'series',
        message => $op->op_name . " is not probed on Odoo $series: the mailing pack has profiles for series 16 and 18 only, "
            . 'and a later series is a profile and a probe away (docs/OPS.md)',
    ) if $p->series != $series;
    my $v = $p->validate( $op->client );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'profile',
        message => 'the mailing profile does not match this server: ' . join( '; ', @{ $v->{missing} } ),
    ) if !$v->{ok};
    return $p;
}

=head2 email($text)

The address as the pack matches it: trimmed and lower-cased, or undef
when the text is not an address. This is Odoo's C<email_normalized>
for every address a person would type; Odoo itself would also take a
display name around it, which a list import does not carry.

=cut

sub email ($text) {
    my ($e) = Odoo::Ops::Match::norm_email($text);
    return $e;
}

=head2 id_of($value)

The id in a many2one read (C<[id, name]>), or the number itself.

=cut

sub id_of ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? 0 + $v : undef ) }

=head2 text($value)

A read value as text: Odoo reads an empty char as C<false>, which is
an empty string here.

=cut

sub text ($v) { defined $v && !ref $v ? "$v" : '' }

=head2 epoch($datetime)

Seconds since the epoch of an Odoo datetime (C<YYYY-MM-DD HH:MM:SS>,
UTC) or an ISO time (C<...T...Z>); undef for an empty value.

=cut

sub epoch ($s) {
    return undef if !defined $s || ref $s || $s !~ /\S/;
    my @p = $s =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)/
        or Odoo::Error->throw( kind => 'fault', message => "not a datetime: $s" );
    return timegm( $p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0] );
}

=head2 odoo_time($epoch)

An epoch as an Odoo datetime string, UTC.

=cut

sub odoo_time ($t) {
    my @g = gmtime $t;
    return sprintf '%04d-%02d-%02d %02d:%02d:%02d', $g[5] + 1900, $g[4] + 1, @g[ 3, 2, 1, 0 ];
}

=head2 datetime($text)

A datetime a person typed (C<YYYY-MM-DD HH:MM:SS>, a C<T> for the space,
or a date alone) as Odoo's string, or a usage refusal naming it.

=cut

sub datetime ($who, $name, $v) {
    return "$1 $2" if $v =~ /^\s*(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)Z?\s*\z/;
    return "$1 00:00:00" if $v =~ /^\s*(\d{4}-\d\d-\d\d)\s*\z/;
    Odoo::Error->throw( kind => 'usage', message => "$who: parameter '$name' must be a UTC datetime (YYYY-MM-DD HH:MM:SS), not '$v'" );
}

=head2 rows($op)

The input rows of an operation that takes C<rows> (a C<.csv>, C<.json>
or C<.jsonl> file), C<records> (a list, for a program) or C<mapping> (a
L<Odoo::Ops::Source> mapping whose target is the C<contact> model): the
C<< { key, values, held?, error? } >> envelopes core.import takes.
Exactly one is required; with C<< email => 1 >> the operation's
C<email> parameter (a list of addresses) is a fourth way in, each
address a row with no name, or, with C<< names => 1 >> and the operation's
C<names> parameter, the name at the same position (a list of the same
length, else usage).

=cut

sub rows ($op, %o) {
    my @ways = $o{email} ? qw(rows records mapping email) : qw(rows records mapping);
    my @in = grep { defined $op->param($_) } @ways;
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': names goes with email', fix => 'pass email= as well, or put a name column in rows' )
        if $o{names} && defined $op->param('names') && !defined $op->param('email');
    Odoo::Error->throw(
        kind    => 'usage',
        message => $op->op_name . ': give exactly one of ' . join( ', ', @ways ) . ' (got ' . ( @in ? "@in" : 'none' ) . ')',
    ) if @in != 1;
    if ( $in[0] eq 'email' ) {
        my @addr  = @{ $op->param('email') };
        my @names = $o{names} && defined $op->param('names') ? @{ $op->param('names') } : ();
        Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': names has ' . @names . ' name(s) for ' . @addr . ' address(es); give one name per address, in the order of email',
            fix => 'pass names= with exactly as many names as email= has addresses, or leave names out' )
            if @names && @names != @addr;
        my $rows = Odoo::Ops::Rows->load( $op->op_name,
            records => [ map { +{ email => $addr[$_], ( @names && length $names[$_] ? ( name => $names[$_] ) : () ) } } 0 .. $#addr ] );
        # marked so an operation can tell an address given on its own from a file row with no name
        $_->{from_email} = 1 for @$rows;
        return $rows;
    }
    return Odoo::Ops::Rows->load( $op->op_name, records => $op->param('records') ) if $in[0] eq 'records';
    return Odoo::Ops::Rows->load( $op->op_name, rows => $op->param('rows') )       if $in[0] eq 'rows';
    my $src = Odoo::Ops::Source->load( $op->param('mapping') );
    Odoo::Error->throw(
        kind    => 'usage',
        message => $op->op_name . ': mapping target ' . $src->target . ' is not contact',
        fix     => 'use a mapping whose target is contact',
    ) if $src->target ne 'contact';
    return $src->rows;
}

=head2 rows_params

The parameter spec for the three ways in, to merge into an operation's.

=cut

sub rows_params () {
    return (
        rows    => { type => 'path', help => 'contacts file: .csv (header name,email,company,tags), .json or .jsonl' },
        records => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
        mapping => { type => 'path', help => 'a Source mapping (mapping.yaml) whose target is contact' },
    );
}

=head2 lists_by($op, $ref, %o)

The list rows a name or id names. A name matches exactly,
case-insensitively; archived lists are included only with
C<< archived => 1 >>. Returns the rows in the order found (several when
a name is not unique - the caller holds that).

=cut

sub lists_by ($op, $ref, %o) {
    my $p    = $op->profile;
    my $name = $p->field( list => 'name' );
    my @dom  = $ref =~ /^\d+\z/ ? ( [ 'id', '=', 0 + $ref ] ) : ( [ $name, '=ilike', $ref ] );
    push @dom, [ $p->field( list => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] if $o{archived};
    my $rows = $op->model('list')->search_read( \@dom, [ 'id', $name, $p->field( list => 'active' ) ] );
    # =ilike reads _ and % as wildcards; a list named by a person is matched as written
    return $ref =~ /^\d+\z/ ? $rows : [ grep { lc( $_->{$name} // '' ) eq lc $ref } @$rows ];
}

=head2 text_part_links($op, $profile, $mailing_id)

The C<text_links> verdicts of the plain-text part Odoo will make from the
stored body of the mailing: the body is read, local links are made absolute
with the mailing's base URL (as C<mail.render.mixin._replace_local_links>
does), and C<html2plaintext> is applied. Undef when the body or the base URL
cannot be read by this user or the body cannot be parsed, so the caller says
nothing instead of guessing.

=cut

sub text_part_links ($op, $p, $id) {
    my $fb = $p->field( mailing => 'body_html' );
    my ($row) = denied( sub { $op->model('mailing')->read( [$id], [$fb] )->[0] }, 'the mailing body' );
    return undef if !$row;
    my $body = text( $row->{$fb} );
    my ($base) = denied( sub { $op->model('mailing')->call( $p->action('base_url'), [ [$id] ] ) }, 'the base URL' );
    return undef if !defined $base || ref $base;
    $base =~ s{/+\z}{};
    $body =~ s{\b(href|src)=(["'])/(?!/)}{$1=$2$base/}gi if length $base;
    my ( undef, $urls ) = eval { Odoo::Ops::Mailing::Plaintext::html2plaintext($body) };
    return undef if !$urls;
    return Odoo::Ops::Mailing::Plaintext::text_links( $urls, base_url => $base, series => $op->client->server_series );
}

=head2 has_unsubscribe($html, $href)

True when the body carries an anchor whose C<href> is the path Odoo
rewrites into the recipient's own unsubscribe link at send time.

=cut

sub has_unsubscribe ($html, $href) {
    return 0 if !defined $html;
    my $h = quotemeta $href;
    return $html =~ /<a\b[^>]*\bhref\s*=\s*(["'])$h\1/is ? 1 : 0;
}

=head2 scope($op, $phase, $scope)

C<scope_for> for the operations that call Odoo methods whose names a
profile owns: an entry written C<&name> in a declared scope is replaced
by the physical method C<< $profile->action('name') >>; an entry the profile
does not name is left out (the operation says why it cannot run). So an operation
declares C<< mailing => ['read', '&send_mail'] >> and a later series
renames the method in its profile, not in the code.

=cut

sub scope ($op, $phase, $scope) {
    my $p = $op->profile;
    return { map { my $m = $_; $m => [ sort map { /^&(.+)\z/ ? ( $p->has_action($1) ? $p->action($1) : () ) : $_ } @{ $scope->{$m} } ] } keys %$scope };
}

=head2 xmlid_id($op, $xmlid)

The record id behind an external id (C<module.name>), read from
C<ir.model.data>; undef when it does not exist.

=cut

sub xmlid_id ($op, $xmlid) {
    my ( $module, $name ) = split /\./, $xmlid, 2;
    my $row = $op->client->model('ir.model.data')->search_read(
        [ [ 'module', '=', $module ], [ 'name', '=', $name ] ], ['res_id'], limit => 1 )->[0];
    return $row ? 0 + $row->{res_id} : undef;
}

=head2 denied($code, $what, $tail)

Runs a convenience read - one a mailing operator may not be allowed to
make, and whose answer the operation can do without (the queue's cron
through C<ir.model.data> and C<ir.cron>, the outgoing servers and the
sender parameters, the C<mail.mail> rows of the queue) - and returns C<< ( $value, undef ) >>. When Odoo
refuses it for want of rights (an access fault, whichever model it names)
it returns C<< ( undef, $note ) >>, the note saying what is not
readable, which model needs which groups (as Odoo's own refusal text names
them), and C<$tail> (what is still true). Any other failure is the caller's: a fault that is not an access
refusal, a transport error, a refusal of the pack, is thrown again.

=cut


sub denied ($code, $what, $tail = '') {
    my @v = eval { $code->() };
    return @v if !$@;
    my $err = $@;
    die $err if !( blessed($err) && $err->isa('Odoo::Error') && $err->is_access_denied );
    my ( $model, $group ) = _needs($err);
    return ( undef, "$what not readable by this user ($model needs $group)" . ( length $tail ? "; $tail" : '' ) );
}

=head2 search_read_named($op, $model, \@domain, \@fields, %o)

=head2 read_named($op, $model, \@ids, \@fields, %o)

A multi-field read that survives a field this user may not compute.
Returns C<< ( $rows, $info ) >>. When the read is refused with Odoo's
access text (a computed field whose compute reaches a model the user may
not read: C<total> over C<account.move> for a mailing on partners filtered
by invoices) the helper, once per call:

=over

=item 1.

finds the ids (for a search, the same domain, order and limit asking for
C<id> only);

=item 2.

reads those ids one computed (non-stored) field at a time and notes the
fields that are refused;

=item 3.

reads the rows again without them. A refused field is null on every row.

=back

C<$info> is C<< { refused => [fields refused], unreadable => {
id => { field => reason } } } >>, the reason set on every row for every
refused field; C<reason> is C<its compute reads account.move (needs
Accounting/Billing or ...)> from Odoo's text, composed with
C<unreadable_note>. A fault that is not an access refusal, a refusal with no
computed field behind it (the domain, a model the pack needs) and a refusal
of a field named in C<< required => [...] >> (or C<id>) is thrown again
as it was, with the fix line of an access fault. The audit record of the
first, refused read carries C<refused_fields> (see L<Odoo::Ops::Guard>).

=cut

sub search_read_named ($op, $lm, $domain, $fields, %o) {
    my $m  = $op->model($lm);
    my %kw = map { defined $o{$_} ? ( $_ => $o{$_} ) : () } qw(order limit offset);
    return _tolerant( $op, $m, $fields, $o{required},
        sub { $m->search_read( $domain, $fields, %kw ) },
        sub { [ map { $_->{id} } @{ $m->search_read( $domain, ['id'], %kw ) } ] } );
}

sub read_named ($op, $lm, $ids, $fields, %o) {
    my $m = $op->model($lm);
    return ( [], { refused => [], unreadable => {} } ) if !@$ids;
    return _tolerant( $op, $m, $fields, $o{required}, sub { $m->read( $ids, $fields ) }, sub { [@$ids] } );
}

sub _is_access ($err) { blessed($err) && $err->isa('Odoo::Error') && $err->is_access_denied }

sub _tolerant ($op, $m, $fields, $required, $first, $ids_of) {
    my $guard = $op->ctx->guard;
    $guard->hold_access_fault;
    my $rows = eval { $first->() };
    my $err  = $@;
    if ( !$err ) {
        $guard->release_access_fault;
        return ( $rows, { refused => [], unreadable => {} } );
    }
    my ( $got, $die );
    if ( _is_access($err) ) {
        $got = eval { _diagnose( $m, $fields, $required, $ids_of ) };
        $die = $@ if !$got;
    }
    $guard->release_access_fault( $got ? ( refused_fields => $got->[1]{refused} ) : () );
    die( $die || $err ) if !$got;    # nothing to separate: the first fault stands
    return @$got;
}

sub _diagnose ($m, $fields, $required, $ids_of) {
    my $ids = $ids_of->();
    return undef if !@$ids;
    my $meta = $m->fields;
    my %must = map { $_ => 1 } 'id', @{ $required // [] };
    my ( @refused, %why );
    for my $f ( grep { $_ ne 'id' && !( $meta->{$_} && $meta->{$_}{store} ) } @$fields ) {
        eval { $m->read( $ids, [$f] ); 1 } and next;
        my $e = $@;
        die $e if !_is_access($e);
        return undef if $must{$f};
        push @refused, $f;
        $why{$f} = access_reason($e);
    }
    return undef if !@refused;
    my %gone = map { $_ => 1 } @refused;
    my @ok   = grep { !$gone{$_} } @$fields;
    my $base = eval { $m->read( $ids, [ 'id', grep { $_ ne 'id' } @ok ] ) };
    if ( !$base ) {
        # something else in the list is refused too (a stored field cannot be, on its compute): the first fault stands
        my $e = $@;
        die $e if !_is_access($e);
        return undef;
    }
    my %unreadable;
    for my $row (@$base) {
        $row->{$_} = undef, $unreadable{ $row->{id} }{$_} = $why{$_} for @refused;
    }
    return [ $base, { refused => [@refused], unreadable => \%unreadable, reasons => \%why } ];
}

=head2 access_reason($error)

C<its compute reads account.move (needs Accounting/Billing or ...)> from
Odoo's access text: the model it names and the groups it lists.

=cut

sub access_reason ($err) {
    my ( $model, $group ) = _needs($err);
    return "its compute reads $model (needs $group)";
}

=head2 unreadable_note($label, $reason)

C<< "$label not readable by this user: $reason" >>, the note a row carries
for a field it could not read.

=cut

sub unreadable_note ($label, $reason) { "$label not readable by this user: $reason" }

sub _needs ($err) {
    my $model = $err->access_model // 'a model it reads';
    my @g     = $err->access_groups;
    my $group = @g ? join( ' or ', @g[ 0 .. ( $#g < 2 ? $#g : 2 ) ] ) . ( @g > 3 ? ' or others' : '' ) : 'a group with the right to read it';
    return ( $model, $group );
}

=head2 list_domain($op, \@list_ids)

Odoo 16's default C<mailing_domain> for a mailing to these lists, as the
text Odoo stores: C<[('list_ids', 'in', [1, 2])]>. Odoo adds no term for
the blacklist (read on demo16, C<t/85>): a blacklisted contact is in the
domain and is cancelled at send as a trace.

=head2 country_domain($op, \@list_ids, $mode, \@country_ids)

The domain of a list mailing to one region of its lists: the default for
the lists and the clause on the contact's own country, as Odoo stores a
domain. C<$mode> C<in> is C<('country_id', 'in', [...])>; C<not_in> is
C<'|', ('country_id', '=', False), ('country_id', 'not in', [...])>, so a
contact with no country is in it. Ids are sorted, so the same filter is
the same text.

=head2 slice_domain($domain_text, $from_id, $before_id)

A domain text with a contact id range added: C<('id', '>=', FROM)> and
C<('id', '<', BEFORE)>, either left out when undef. Odoo's domains have no
modulo, so a slice of a part is an id range; a range with no upper bound
takes every contact made after it was planned. The terms follow whatever the
domain holds (the lists and a country clause), so a slice is a part of a
part.

=head2 slice_words($from_id, $before_id)

The range in words: C<contacts with id 1 or more and below 4,812>.

=head2 commas($n)

A count with thousands commas (C<4,812>).

=head2 same_domain($a, $b)

True when two domain texts are the same but for white space.

=head2 parse_domain($text)

A domain text (Python literal as Odoo stores it, or JSON) read into the
list the client sends: terms as C<[field, op, value]>, C<'|'>, C<'&'> and
C<'!'> as strings, C<True>/C<False>/C<None> as booleans and null. Undef
when the text is not a domain this reads (it is then not guessed at).

=cut

sub list_domain ($op, $list_ids) {
    my $lf = $op->profile->field( contact => 'lists' );
    return "[('$lf', 'in', [" . join( ', ', sort { $a <=> $b } @$list_ids ) . '])]';
}

sub country_domain ($op, $list_ids, $mode, $country_ids) {
    my $p  = $op->profile;
    my $cf = $p->field( contact => 'country' );
    my $ids = join ', ', sort { $a <=> $b } @$country_ids;
    ( my $base = list_domain( $op, $list_ids ) ) =~ s/\]\z//;
    return $mode eq 'in'
        ? "$base, ('$cf', 'in', [$ids])]"
        : "$base, '|', ('$cf', '=', False), ('$cf', 'not in', [$ids])]";
}

sub slice_domain ($text, $from, $before) {
    ( my $base = $text ) =~ s/\]\s*\z//;
    my @terms = ( ( defined $from ? "('id', '>=', $from)" : () ), ( defined $before ? "('id', '<', $before)" : () ) );
    # an empty domain takes the terms alone; any other gets them after its own, which Odoo ANDs
    return $base . ( $base =~ /\[\s*\z/ ? '' : ', ' ) . join( ', ', @terms ) . ']';
}

sub commas ($n) { scalar reverse( join ',', unpack '(A3)*', reverse $n ) }

sub slice_words ($from, $before) {
    return 'contacts with id ' . commas($from) . ' or more and below ' . commas($before) if defined $from && defined $before;
    return 'contacts with id ' . commas($from) . ' or more (no upper bound)' if defined $from;
    return 'contacts with id below ' . commas($before) . ' (no lower bound)';
}

sub same_domain ($x, $y) {
    return 0 if !defined $x || !defined $y;
    my ( $a, $b ) = map { s/\s+//gr } ( $x, $y );
    return $a eq $b ? 1 : 0;
}

sub parse_domain ($text) {
    return undef if !defined $text || ref $text || $text !~ /\S/;
    my ( $pos, $s ) = ( 0, $text );
    my $ws = sub { $s =~ /\G\s*/gc; $pos = pos($s) // $pos };
    my $value;
    $value = sub {
        pos($s) = $pos;
        $s =~ /\G\s*/gc;
        if ( $s =~ /\G([\[(])/gc ) {
            my $close = $1 eq '[' ? ']' : ')';
            my @items;
            while (1) {
                $s =~ /\G\s*/gc;
                last if $s =~ /\G\Q$close\E/gc;
                $pos = pos($s);
                my $v = $value->();
                return undef if !$v;
                push @items, $v->[0];
                pos($s) = $pos;
                $s =~ /\G\s*/gc;
                next if $s =~ /\G,/gc;
                last if $s =~ /\G\Q$close\E/gc;
                return undef;
            }
            $pos = pos($s);
            return [ \@items ];
        }
        if ( $s =~ /\G(["'])((?:\\.|(?!\1).)*)\1/gcs ) {
            ( my $str = $2 ) =~ s/\\(.)/$1/g;
            $pos = pos($s);
            return [$str];
        }
        if ( $s =~ /\G(-?\d+(?:\.\d+)?)/gc ) { $pos = pos($s); return [ $1 + 0 ] }
        if ( $s =~ /\G(True|true)\b/gc )  { $pos = pos($s); return [JSON::PP::true] }
        if ( $s =~ /\G(False|false)\b/gc ) { $pos = pos($s); return [JSON::PP::false] }
        if ( $s =~ /\G(None|null)\b/gc )  { $pos = pos($s); return [undef] }
        return undef;
    };
    $pos = 0;
    my $v = $value->();
    return undef if !$v || ref $v->[0] ne 'ARRAY';
    pos($s) = $pos;
    $s =~ /\G\s*/gc;
    return undef if ( pos($s) // $pos ) != length $s;
    my $dom = $v->[0];
    for my $term (@$dom) {
        next if !ref $term && defined $term && $term =~ /\A[|&!]\z/;
        return undef if ref $term ne 'ARRAY' || @$term != 3;
    }
    return $dom;
}

=head2 remaining($op, $mailing_id, $domain_text)

Who Odoo's own C<_get_remaining_recipients> would send to now, worked out the way
it does (it is private, so it cannot be called): the contacts the mailing's
domain gives, less those that already have a trace of this mailing. Returns
C<< { ids => [ ... ], candidates => N, traced => M } >>, the ids in contact id
order, C<traced> being the candidates that have a trace; or undef when the domain
is one OOM cannot read (it is then not guessed at). An empty domain gives no
recipient, as Odoo's does (its C<_parse_mailing_domain> falls back to no record
when the text is not a domain).

=cut

sub remaining ($op, $mailing_id, $domain_text) {
    my $p = $op->profile;
    my $dom = !defined $domain_text || $domain_text !~ /\S/ ? [ [ 'id', 'in', [] ] ] : parse_domain($domain_text);
    return undef if !$dom;
    my $contacts = $op->model('contact')->all( $dom, ['id'] );
    my @ids = map { $_->{id} } @$contacts;
    my ( $tm, $tmail, $tres, $tmodel ) = ( $op->model('trace'), map { $p->field( trace => $_ ) } qw(mailing res_id model) );
    my %traced;
    for ( my $i = 0 ; $i < @ids ; $i += 1000 ) {
        my @slice = @ids[ $i .. ( $i + 999 < $#ids ? $i + 999 : $#ids ) ];
        $traced{ $_->{$tres} } = 1 for @{ $tm->all( [ [ $tmail, '=', $mailing_id ], [ $tmodel, '=', $p->model_name('contact') ], [ $tres, 'in', \@slice ] ], [$tres] ) };
    }
    return { ids => [ grep { !$traced{$_} } @ids ], candidates => scalar @ids, traced => scalar( grep { $traced{$_} } @ids ) };
}

=head2 countries($op, \@codes)

The C<res.country> rows (C<id>, C<code>, C<name>) for ISO codes, upper-cased
and each once, in the order given. A code Odoo has no country for is a
C<usage> refusal naming it.

=cut

sub countries ($op, $codes) {
    my $p = $op->profile;
    my ( $cc, $cn ) = map { $p->field( country => $_ ) } qw(code name);
    my @want;
    my %seen;
    for my $c (@$codes) {
        my $u = uc( $c =~ s/^\s+|\s+\z//gr );
        next if !length $u || $seen{$u}++;
        push @want, $u;
    }
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': a country filter needs at least one country code',
        fix => 'give ISO 3166 alpha-2 codes, comma-separated (AU,JP)' ) if !@want;
    my $rows = $op->model('country')->search_read( [ [ $cc, 'in', \@want ] ], [ $cc, $cn ] );
    my %by = map { uc( $_->{$cc} ) => { id => $_->{id}, code => uc( $_->{$cc} ), name => $_->{$cn} } } @$rows;
    my @unknown = grep { !$by{$_} } @want;
    Odoo::Error->throw( kind => 'usage',
        message => $op->op_name . ': unknown country code' . ( @unknown > 1 ? 's' : '' ) . ' ' . join( ', ', map { "'$_'" } @unknown ) . ' (res.country has no such code)',
        fix => 'ISO 3166 alpha-2 codes as res.country holds them (AU, GB, US); oom-ops run core.select --set model=res.country lists them' ) if @unknown;
    return [ map { $by{$_} } @want ];
}

=head2 country_words($mode, \@countries)

The filter in words: C<country in Australia (AU), Japan (JP)>, or
C<country not in ..., or no country>.

=cut

sub country_words ($mode, $countries) {
    my $list = join ', ', map { "$_->{name} ($_->{code})" } @$countries;
    return $mode eq 'in' ? "contact's own country is one of $list" : "contact's own country is not one of $list, or the contact has no country";
}

=head2 audience($op, \@list_ids, domain => \@domain)

Who a mailing to these lists reaches, worked out the way Odoo's own
send does it, from the subscriptions: an address is mailed once (two
contacts with one address are one recipient), not when it is on the
blacklist, and not when every subscription it has among these lists is
opted out. Returns C<< { subscriptions, contacts, reachable, opted_out,
blacklisted, no_email } >> (addresses for the last four but the last).

With C<domain> (a parsed C<mailing_domain>, see L</parse_domain($text)>) only the contacts that domain gives are counted: the audience of one region of the lists.

C<reachable> is what a send will mail; Odoo's own C<total> counts the
contacts of the lists (the 16 domain has no blacklist term for lists),
opted-out and blacklisted ones included, and its C<expected> stays 0 until a send has made traces, so
neither can answer "how many will receive this".

=cut

sub audience ($op, $list_ids, %o) {
    my $p = $op->profile;
    my ( $sc, $sl, $so ) = map { $p->field( subscription => $_ ) } qw(contact list opt_out);
    my ( $ce, $cb ) = map { $p->field( contact => $_ ) } qw(email_normalized blacklisted);
    return { subscriptions => 0, contacts => 0, reachable => 0, opted_out => 0, blacklisted => 0, no_email => 0 } if !@$list_ids;
    my $subs = $op->model('subscription')->all( [ [ $sl, 'in', $list_ids ] ], [ $sc, $sl, $so ] );
    # a mailing with its own domain (a region of its lists) reaches the contacts that domain gives, as Odoo's total counts them
    if ( $o{domain} ) {
        my %in = map { $_->{id} => 1 } @{ $op->model('contact')->all( $o{domain}, ['id'] ) };
        @$subs = grep { $in{ id_of( $_->{$sc} ) // 0 } } @$subs;
    }
    my %cid  = map { id_of( $_->{$sc} ) => 1 } @$subs;
    my $rows = %cid ? $op->model('contact')->all( [ [ 'id', 'in', [ sort { $a <=> $b } keys %cid ] ] ], [ $ce, $cb ] ) : [];
    my %contact = map { $_->{id} => $_ } @$rows;
    my ( %in, %out, %black, $no_email );
    my %counted;
    for my $s (@$subs) {
        my $c = $contact{ id_of( $s->{$sc} ) } or next;
        my $e = text( $c->{$ce} );
        if ( !length $e ) { $no_email++ if !$counted{ $c->{id} }++; next }
        if ( $c->{$cb} ) { $black{$e} = 1; next }
        $s->{$so} ? ( $out{$e} = 1 ) : ( $in{$e} = 1 );
    }
    return {
        subscriptions => scalar @$subs,
        contacts      => scalar keys %contact,
        reachable     => scalar keys %in,
        opted_out     => scalar( grep { !$in{$_} } keys %out ),
        blacklisted   => scalar keys %black,
        no_email      => $no_email // 0,
    };
}

1;
