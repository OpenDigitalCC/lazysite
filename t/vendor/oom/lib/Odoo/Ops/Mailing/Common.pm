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
use Odoo::Ops::Rows;
use Odoo::Ops::Source;

=head1 NAME

Odoo::Ops::Mailing::Common - what the mailing operations share

=head1 DESCRIPTION

Not an operation: plain functions the C<mailing.*> operations call, so
that the series gate, the address rule and the row reading are written
once.

=head2 ready($op)

The mailing profile for this server, or a refusal. A series with no
profile of its own is refused by name (C<series>): the registry's
fallback to the nearest lower profile is right for a pack whose model
has not changed, but nothing here was probed on any series but 16, so
loading the 16 file for a 17 server would be a guess. The profile is
then checked against the live C<fields_get> (C<profile> when a mapped
model or field is missing).

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    my $p      = $op->profile;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'series',
        message => $op->op_name . " is not probed on Odoo $series: the mailing pack has a profile for series "
            . $p->series . ' only, and a later series is a profile and a probe away (docs/OPS.md)',
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
by the physical method C<< $profile->action('name') >>. So an operation
declares C<< mailing => ['read', '&send_mail'] >> and a later series
renames the method in its profile, not in the code.

=cut

sub scope ($op, $phase, $scope) {
    my $p = $op->profile;
    return { map { my $m = $_; $m => [ sort map { /^&(.+)\z/ ? $p->action($1) : $_ } @{ $scope->{$m} } ] } keys %$scope };
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

=head2 audience($op, \@list_ids)

Who a mailing to these lists reaches, worked out the way Odoo's own
send does it, from the subscriptions: an address is mailed once (two
contacts with one address are one recipient), not when it is on the
blacklist, and not when every subscription it has among these lists is
opted out. Returns C<< { subscriptions, contacts, reachable, opted_out,
blacklisted, no_email } >> (addresses for the last four but the last).

C<reachable> is what a send will mail; Odoo's own C<total> counts the
contacts of the lists (the 16 domain has no blacklist term for lists),
opted-out and blacklisted ones included, and its C<expected> stays 0 until a send has made traces, so
neither can answer "how many will receive this".

=cut

sub audience ($op, $list_ids) {
    my $p = $op->profile;
    my ( $sc, $sl, $so ) = map { $p->field( subscription => $_ ) } qw(contact list opt_out);
    my ( $ce, $cb ) = map { $p->field( contact => $_ ) } qw(email_normalized blacklisted);
    return { subscriptions => 0, contacts => 0, reachable => 0, opted_out => 0, blacklisted => 0, no_email => 0 } if !@$list_ids;
    my $subs = $op->model('subscription')->all( [ [ $sl, 'in', $list_ids ] ], [ $sc, $sl, $so ] );
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
