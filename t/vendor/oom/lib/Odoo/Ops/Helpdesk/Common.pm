package Odoo::Ops::Helpdesk::Common;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops::Discuss::Common ();
use Odoo::Ops::Profile;

use Exporter "import";
our @EXPORT_OK = qw(ready profile_for id_of name_of flag text fields_block fields_list spec_list look ticket_row to_logical members_of_team is_empty
    stage_wants stage_missing applicable_stages pick_stage stage_change_row rows_of user_row partner_row reason_text html_body post_change files_for apply_post move_tickets stages_for_team first_stage_for add_ticket apply_ticket_change undo_ticket);

=head1 NAME

Odoo::Ops::Helpdesk::Common - what the helpdesk operations share

=head1 DESCRIPTION

Not an operation: plain functions the C<helpdesk.*> operations call, so that the
series gate, the lookups of tickets, stages, users and partners, the stage rule of
C<helpdesk_mgmt_stage_validation> and the posting of a message are written once.

The pack serves the OCA C<helpdesk_mgmt> tickets (with C<helpdesk_mgmt_sla> and
C<helpdesk_mgmt_stage_validation>) on Odoo 16 and 18. Every other series is refused
C<refused/not-applicable>, naming the series.

=head2 ready($op)

The helpdesk profile for this server, or a refusal: C<not-applicable> on a series
other than 16 and 18, C<profile> when a mapped model or field is missing from the
server. The profile is checked against the live C<fields_get> once for the operation.

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'not-applicable',
        message => $op->op_name . " is not applicable here: the helpdesk pack is probed on Odoo 16 and 18, and this server is Odoo $series",
        fix     => 'run it against a 16 or 18 server; core.read and core.action reach the models of another series',
    ) if $series != 16 && $series != 18;
    my $p = $op->profile;
    $op->{helpdesk_valid} //= do {
        my $v = $p->validate( $op->client );
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'profile',
            message => 'the helpdesk profile does not match this server: ' . join( '; ', @{ $v->{missing} } ),
            fix     => 'oom-ops run core.check --set pack=helpdesk names what differs',
        ) if !$v->{ok};
        1;
    };
    return $p;
}

=head2 profile_for($client, $op_name)

The profile at apply time, where an operation has the client and no context.

=cut

sub profile_for ( $client, $op_name ) {
    my $series = $client->server_series;
    Odoo::Error->throw( kind => 'refused', code => 'not-applicable',
        message => "$op_name is not applicable here: the helpdesk pack is probed on Odoo 16 and 18, and this server is Odoo $series" )
        if $series != 16 && $series != 18;
    return Odoo::Ops::Profile->load( pack => 'helpdesk', series => $series );
}

=head2 id_of($v), name_of($v), flag($v)

The id and the name in a many2one read, and a boolean as 1 or 0.

=cut

sub id_of ($v)   { Odoo::Ops::Discuss::Common::id_of($v) }
sub name_of ($v) { Odoo::Ops::Discuss::Common::name_of($v) }
sub flag ($v)    { $v ? 1 : 0 }

=head2 text($v)

A value Odoo may give as false for an empty text, as undef.

=cut

sub text ($v) { defined $v && !ref $v && length $v ? $v : undef }

=head2 fields_block(\@columns)

The C<fields> block of a read: C<< [ name, portable_type, meaning ] >> triples as descriptors.

=cut

sub fields_block ($cols) { return { map { $_->[0] => { portable_type => $_->[1], string => $_->[2] } } @$cols } }
sub fields_list  ($cols) { return [ map { { name => $_->[0], meaning => $_->[2] } } @$cols ] }

=head2 spec_list($value)

The words of a list parameter given as a list or as a comma separated string.

=cut

sub spec_list ($v) { return () if !defined $v; return ref $v eq 'ARRAY' ? @$v : grep { length } split /\s*,\s*/, $v }

=head2 look($op, $lm, $spec, %o)

One record of the profile model C<$lm> named by C<$spec>: an id (digits), else the
value of the profile field C<by> (default C<name>) compared with C<=ilike>. Returns
C<< ( $row ) >> for exactly one, C<< ( undef, 'none' ) >> or C<< ( undef, 'many', @rows ) >>.
C<fields> are read besides the id; C<domain> narrows the search. An id that is no
record, or that the login may not read, is C<none>.

=cut

sub look ( $op, $lm, $spec, %o ) {
    my $p = $op->profile;
    my $by = $o{by} // 'name';
    my @fields = map { $p->field( $lm => $_ ) } grep { defined $p->field( $lm => $_ ) } @{ $o{fields} // [] };
    my @extra = @{ $o{domain} // [] };
    my $m = $op->model($lm);
    my %ctx = $o{inactive} ? ( context => { active_test => JSON::PP::false } ) : ();
    my $rows;
    if ( $spec =~ /\A[1-9]\d*\z/ ) {
        $rows = $m->search_read( [ [ 'id', '=', 0 + $spec ], @extra ], \@fields, %ctx );
    }
    else {
        $rows = $m->search_read( [ [ $p->field( $lm => $by ), '=ilike', $spec ], @extra ], \@fields, %ctx );
        my @exact = grep { lc( $_->{ $p->field( $lm => $by ) } // '' ) eq lc $spec } @$rows;
        $rows = \@exact if @exact == 1;
    }
    return ( undef, 'none' ) if !@$rows;
    return ( undef, 'many', @$rows ) if @$rows > 1;
    return ( $rows->[0] );
}

=head2 ticket_row($op, $spec, @logical_fields)

The ticket named by an id or a number (C<HT00012>), with its fields as logical
names in C<< $row->{f} >> beside C<id>, or the reason it cannot be had:
C<< ( undef, 'none' ) >> or C<< ( undef, 'many' ) >>.

=cut

sub ticket_row ( $op, $spec, @lf ) {
    my $p = $op->profile;
    my @lf2 = grep { defined $p->field( ticket => $_ ) } @lf;
    my @phys = map { $p->field( ticket => $_ ) } @lf2;
    my $m = $op->model('ticket');
    my $rows = $spec =~ /\A[1-9]\d*\z/
        ? $m->search_read( [ [ 'id', '=', 0 + $spec ] ], \@phys )
        : $m->search_read( [ [ $p->field( ticket => 'number' ), '=ilike', $spec ] ], \@phys );
    return ( undef, 'none' ) if !@$rows;
    return ( undef, 'many' ) if @$rows > 1;
    return ( to_logical( $p, ticket => $rows->[0], \@lf2 ) );
}

=head2 to_logical($p, $lm, $row, \@lf)

A row read with physical names as C<< { id, f => { logical => value } } >>.

=cut

sub to_logical ( $p, $lm, $row, $lf ) {
    return { id => $row->{id}, f => { map { $_ => $row->{ $p->field( $lm => $_ ) } } @$lf } };
}

=head2 members_of_team($op, $team_id)

The user ids and names of the team's members, as C<< { id => name } >>.

=cut

sub members_of_team ( $op, $team_id ) {
    my $p = $op->profile;
    my $t = $op->model('team')->read_one( $team_id, [ $p->field( team => 'members' ), $p->field( team => 'name' ) ] ) or return {};
    my @ids = @{ $t->{ $p->field( team => 'members' ) } // [] };
    return {} if !@ids;
    my $nf = $p->field( user => 'name' );
    return { map { $_->{id} => $_->{$nf} } @{ $op->model('user')->search_read( [ [ 'id', 'in', \@ids ] ], [$nf], context => { active_test => JSON::PP::false } ) } };
}

=head2 is_empty($type, $value)

Whether a value counts as unset the way the stage validation of C<helpdesk_mgmt_stage_validation>
counts it (a falsy value in Python): false, zero, an empty text, no records.

=cut

sub is_empty ( $type, $v ) {
    return 1 if !defined $v;
    return @$v ? 0 : 1 if ref $v eq 'ARRAY' && ( $type // '' ) =~ /2many\z/;
    return ( !$v->[0] ? 1 : 0 ) if ref $v eq 'ARRAY';
    return $v ? 0 : 1 if ( $type // '' ) =~ /\A(?:boolean|integer|float|monetary|many2one)\z/;
    return length $v ? 0 : 1;
}

=head2 stage_wants($op, $stage_id)

The fields a stage holds a ticket to (C<helpdesk_mgmt_stage_validation>), as
C<< [ { name, label, type } ] >>; an empty list when the module is not installed or
the stage names none.

=cut

sub stage_wants ( $op, $stage_id ) {
    my $p = $op->profile;
    my $vf = $p->field( stage => 'validate' ) // return [];
    my $st = $op->model('stage')->read_one( $stage_id, [$vf] ) or return [];
    my @ids = @{ $st->{$vf} // [] } or return [];
    my $ff = $op->client->model('ir.model.fields')->search_read( [ [ 'id', 'in', \@ids ] ], [ 'name', 'ttype' ] );
    my $desc = $op->model('ticket')->fields;
    return [ map { { name => $_->{name}, type => $_->{ttype}, label => ( $desc->{ $_->{name} } && $desc->{ $_->{name} }{string} ) // $_->{name} } } sort { $a->{name} cmp $b->{name} } @$ff ];
}

=head2 stage_missing($op, $ticket_id, $stage_id, \%values)

The labels of the fields the ticket leaves empty that the stage requires, in the
order Odoo names them. C<%values> are values the ticket is to hold at the same time
(a write that sets them with the stage passes in Odoo, which checks the values
after the write).

=cut

sub stage_missing ( $op, $ticket_id, $stage_id, $values = {} ) {
    my $want = stage_wants( $op, $stage_id );
    return () if !@$want;
    my $row = $op->model('ticket')->read_one( $ticket_id, [ map { $_->{name} } @$want ] ) or return ();
    my @out;
    for my $w (@$want) {
        my $v = exists $values->{ $w->{name} } ? $values->{ $w->{name} } : $row->{ $w->{name} };
        push @out, $w->{label} if is_empty( $w->{type}, $v );
    }
    return @out;
}

=head2 applicable_stages($op, $team_id, %o)

The stages a team may use, in Odoo's order (sequence, id): those with no team and
those that name the team. C<closed> 1 keeps the closed ones, 0 the open ones.
C<< [ { id, name, closed, sequence, close_from_portal } ] >>.

=cut

sub applicable_stages ( $op, $team_id, %o ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( stage => $lf ) };
    my @dom;
    push @dom, [ $f->('closed'), '=', $o{closed} ? JSON::PP::true : JSON::PP::false ] if defined $o{closed};
    push @dom, [ $f->('close_from_portal'), '=', JSON::PP::true ] if $o{close_from_portal};
    my $rows = $op->model('stage')->search_read( \@dom,
        [ map { $f->($_) } qw(name closed sequence close_from_portal teams) ], order => 'sequence, id' );
    return [ map { { id => $_->{id}, name => $_->{ $f->('name') }, closed => flag( $_->{ $f->('closed') } ),
            sequence => $_->{ $f->('sequence') }, close_from_portal => flag( $_->{ $f->('close_from_portal') } ) } }
        grep { my @t = @{ $_->{ $f->('teams') } // [] }; !@t || ( $team_id && grep { $_ == $team_id } @t ) } @$rows ];
}

=head2 pick_stage($op, $spec, $team_id)

The stage named by an id or a name. A name that several stages carry is narrowed to
those the team may use; still several (or none) is the reason, as C<look>.

=cut

sub pick_stage ( $op, $spec, $team_id ) {
    my ( $row, $why, @many ) = look( $op, stage => $spec, fields => [qw(teams name)] );
    return ($row) if $row;
    return ( undef, $why ) if $why eq 'none';
    my $p = $op->profile;
    my $tf = $p->field( stage => 'teams' );
    my @fit = grep { my @t = @{ $_->{$tf} // [] }; !@t || ( $team_id && grep { $_ == $team_id } @t ) } @many;
    return ( $fit[0] ) if @fit == 1;
    return ( undef, 'many', @many );
}

=head2 stage_change_row($op, $plan, \%a)

Plans the move of a ticket to a stage, or holds it: C<< { ticket (a ticket_row), stage (id), stage_name,
key, values } >>. Holds C<missing-fields> naming the fields the stage requires and the ticket lacks,
and says which stage template Odoo will mail. Skips (C<unchanged>) a ticket already there. Returns the
bucket it used.

=cut

sub stage_change_row ( $op, $plan, $a ) {
    my $p = $op->profile;
    my $t = $a->{ticket};
    my $key = $a->{key};
    my $cur = id_of( $t->{f}{stage} );
    if ( defined $cur && $cur == $a->{stage} ) {
        $plan->add( bucket => 'unchanged', action => 'skip', id => $t->{id}, key => $key, reason => "ticket $t->{id} is already in stage $a->{stage_name}" );
        return 'unchanged';
    }
    my @miss = stage_missing( $op, $t->{id}, $a->{stage}, $a->{values} // {} );
    if (@miss) {
        my $title = $t->{f}{title} // $t->{id};
        $plan->add( bucket => 'missing-fields', action => 'hold', key => $key,
            reason => "ticket $title can't be moved to the stage $a->{stage_name} until the following fields are set: " . join( ', ', @miss ) . '. (helpdesk_mgmt_stage_validation refuses it; set the fields first)' );
        return 'missing-fields';
    }
    my $tpl = $op->model('stage')->read_one( $a->{stage}, [ $p->field( stage => 'template' ), $p->field( stage => 'closed' ) ] );
    my $mails = $tpl && id_of( $tpl->{ $p->field( stage => 'template' ) } ) ? name_of( $tpl->{ $p->field( stage => 'template' ) } ) : undef;
    $plan->add(
        bucket => $a->{bucket} // 'stage', action => 'write', model => $p->model_name('ticket'), id => $t->{id}, key => $key,
        vals   => { $p->field( ticket => 'stage' ) => $a->{stage} },
        before => { $p->field( ticket => 'stage' ) => $t->{f}{stage} },
        reason => ( $mails ? "Odoo mails the template '$mails' to the ticket's partner when it reaches $a->{stage_name}" : undef ),
    );
    return $a->{bucket} // 'stage';
}

=head2 rows_of($op, \%scalar_to_key, $name)

The rows an operation acts on: its C<rows> parameter, or one row made of its scalar
parameters (C<param name> => row key). Both together are C<usage>, as is neither.

=cut

sub rows_of ( $op, $map, $label = 'a ticket' ) {
    my $rows = $op->param('rows');
    my %given = map { $_ => $op->param($_) } grep { defined $op->param($_) } sort keys %$map;
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': give rows or the parameters of one ticket, not both',
        fix => 'oom-ops describe ' . $op->op_name . ' lists them' ) if $rows && %given;
    return $rows if $rows;
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": give $label (" . join( ', ', sort keys %$map ) . ') or rows',
        fix => 'oom-ops describe ' . $op->op_name . ' lists the parameters' ) if !%given;
    return [ { map { $map->{$_} => $given{$_} } keys %given } ];
}

=head2 user_row($op, $spec)

The active user named by an id, a login or a name, as C<look>.

=cut

sub user_row ( $op, $spec ) {
    my $p = $op->profile;
    return look( $op, 'user', $spec, fields => ['login'], by => 'login' ) if $spec =~ /\A[1-9]\d*\z/ || $spec =~ /\@/;
    my ( $r, $why, @many ) = look( $op, 'user', $spec, fields => ['login'], by => 'login' );
    return ( $r, $why, @many ) if $r || $why eq 'many';
    return look( $op, 'user', $spec, fields => ['login'], by => 'name' );
}

=head2 partner_row($op, $spec)

The partner named by an id, an email address or a name, as C<look>.

=cut

sub partner_row ( $op, $spec ) {
    return look( $op, 'partner', $spec, fields => [qw(name email)], by => 'email' ) if $spec =~ /\@/;
    return look( $op, 'partner', $spec, fields => [qw(name email)], by => 'name' );
}

=head2 reason_text($why, $thing, $spec, @rows)

A hold's reason for a lookup that found none or several.

=cut

sub reason_text ( $why, $thing, $spec, @rows ) {
    return "no $thing '$spec' that this login can read" if $why eq 'none';
    return "'$spec' names " . scalar(@rows) . " ${thing}s (ids " . join( ', ', map { $_->{id} } @rows ) . '); give the id';
}

=head2 html_body($op, $text, $html)

The HTML of a message or a description: C<$text> as given when C<$html> is on, else the
plain text escaped, its new lines as breaks, in one paragraph.

=cut

sub html_body ( $text, $html ) {
    return $html ? $text : Odoo::Ops::Discuss::Common::text_html($text);
}

=head2 post_change($op, $plan, \%a)

Adds the change that posts a message to a ticket (a reply or a note): files put on the
ticket, then Odoo's C<message_post>, read back. C<< { ticket (id), key, kind (reply|note), body (html),
partners ([ids]), files, author (partner id for a message posted for a person), handler (op name), bucket } >>.

=cut

sub post_change ( $op, $plan, $a ) {
    my $p = $op->profile;
    my @files = @{ $a->{files} // [] };
    my @calls = ( [ $p->model_name('ticket'), $p->action('post') ], [ $p->model_name('message'), 'read' ],
        ( @files ? ( [ $p->model_name('attachment'), 'create' ], [ $p->model_name('attachment'), 'unlink' ] ) : () ) );
    my $text = Odoo::Ops::Discuss::Common::html_text( $a->{body} );
    ( my $flat = $text ) =~ s{\s*\n\s*}{ }g;
    my $shown = length $flat > 200 ? substr( $flat, 0, 200 ) . '... (' . length($flat) . ' characters)' : $flat;
    $plan->add(
        bucket => $a->{bucket} // $a->{kind}, action => 'custom', handler => $a->{handler}, kind => 'post',
        model  => $p->model_name('ticket'), id => $a->{ticket} + 0, key => $a->{key}, calls => \@calls,
        vals   => {
            ticket => $a->{ticket} + 0, post_kind => $a->{kind}, body => $a->{body},
            ( @{ $a->{partners} // [] } ? ( partners => $a->{partners} ) : () ),
            ( defined $a->{author} ? ( author => $a->{author} + 0 ) : () ),
            ( @files ? ( files => $a->{files} ) : () ),
        },
        line   => ( $a->{kind} eq 'note' ? 'internal note' : 'reply' ) . " on ticket $a->{ticket}: \"$shown\""
            . ( @{ $a->{partners} // [] } ? '; mailed to partner ' . join( ', ', @{ $a->{partners} } ) : '' )
            . ( @files ? '; ' . scalar(@files) . ' file' . ( @files == 1 ? '' : 's' ) . ' (' . join( ', ', map { $_->{name} } @files ) . ')' : '' ),
        reason => 'a message cannot be unsent; Odoo has no way to take it back, so a revert holds it irreversible',
    );
    return;
}

=head2 files_for($op, $plan, $files)

The planned form of file values for C<post_change> and the attachments of a ticket: name, size,
checksum, mimetype and the bytes as a blob reference in the plan.

=cut

sub files_for ( $op, $plan, $given, %o ) {
    require Odoo::Ops::File;
    require Digest::SHA;
    my @out;
    for my $g ( @{ $given // [] } ) {
        my $size = length $g->{bytes};
        my $slim = Odoo::Ops::File->slim($g);
        push @out, {
            name => $g->{name}, size => $size + 0, checksum => Digest::SHA::sha1_hex( $g->{bytes} ), sha256 => $slim->{sha256},
            mimetype => $g->{mimetype}, datas => $plan->blob_value( Odoo::Ops::File->base64($g) ),
        };
    }
    return @out;
}

=head2 apply_post($handler_class, $client, \%change)

Called by the runner for a C<post> change: puts the files on the ticket, posts through
C<message_post> as a reply (the comment subtype, the partners in C<partner_ids>) or a note,
reads the message back and names it. A post that fails removes the files it made.

=cut

sub apply_post ( $class, $client, $c ) {
    require MIME::Base64;
    require Digest::SHA;
    Odoo::Error->throw( kind => 'usage', message => ( $c->{handler} // 'a helpdesk post' ) . " cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'post';
    my $p = profile_for( $client, $c->{handler} // 'helpdesk' );
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $v = $c->{vals};
    my $tid = $v->{ticket};
    my $att = $client->model( $p->model_name('attachment') );
    my @made;
    my $mid = eval {
        for my $file ( @{ $v->{files} // [] } ) {
            my $bytes = MIME::Base64::decode_base64( $file->{datas} );
            Odoo::Error->throw( kind => 'refused', code => 'blob', message => "the bytes of '$file->{name}' are not the file that was planned (checksum differs)",
                fix => 'plan again' ) if Digest::SHA::sha1_hex($bytes) ne $file->{checksum};
            push @made, $att->create( {
                $f->( attachment => 'name' ) => $file->{name}, $f->( attachment => 'res_model' ) => $p->model_name('ticket'),
                $f->( attachment => 'res_id' ) => $tid, $f->( attachment => 'datas' ) => MIME::Base64::encode_base64( $bytes, '' ),
                ( $file->{mimetype} ? ( $f->( attachment => 'mimetype' ) => $file->{mimetype} ) : () ),
            } );
        }
        my $html_flag = $p->action('post_html_flag');
        my $subtype = $p->action( $v->{post_kind} eq 'note' ? 'note_subtype' : 'comment_subtype' );
        my $made_id = $client->execute_kw( $p->model_name('ticket'), $p->action('post'), [ [$tid] ], {
            body => $v->{body}, ( length $html_flag ? ( $html_flag => JSON::PP::true ) : () ),
            message_type => 'comment', subtype_xmlid => $subtype,
            ( $v->{partners} ? ( partner_ids => $v->{partners} ) : () ),
            ( defined $v->{author} ? ( author_id => $v->{author} ) : () ),
            ( @made ? ( attachment_ids => \@made ) : () ),
        } );
        ref $made_id eq 'ARRAY' ? $made_id->[0] : $made_id;
    };
    if ( my $e = $@ ) {
        eval { $att->unlink( \@made ) } if @made;
        die $e;
    }
    my $msg = $client->model( $p->model_name('message') )->read_one( $mid,
        [ map { $f->( message => $_ ) } qw(model res_id author type subtype attachments partners body) ] );
    Odoo::Error->throw( kind => 'fault', message => "no message $mid on ticket $tid after posting" ) if !$msg;
    my %after = (
        id          => $mid,
        ticket      => $msg->{ $f->( message => 'res_id' ) },
        author      => id_of( $msg->{ $f->( message => 'author' ) } ),
        type        => $msg->{ $f->( message => 'type' ) },
        subtype     => name_of( $msg->{ $f->( message => 'subtype' ) } ),
        attachments => [ sort { $a <=> $b } @{ $msg->{ $f->( message => 'attachments' ) } // [] } ],
        partners    => [ sort { $a <=> $b } @{ $msg->{ $f->( message => 'partners' ) } // [] } ],
    );
    my $ok = ( $after{ticket} // 0 ) == $tid
        && ( $msg->{ $f->( message => 'model' ) } // '' ) eq $p->model_name('ticket')
        && join( ',', @{ $after{attachments} } ) eq join( ',', sort { $a <=> $b } @made )
        && !grep( { my $m = $_; !grep { $_ == $m } @{ $after{partners} } } @{ $v->{partners} // [] } )
        && ( !defined $v->{author} || ( $after{author} // 0 ) == $v->{author} )
        && length( $msg->{ $f->( message => 'body' ) } // '' ) + @made > 0;
    my $made = { model => $p->model_name('message'), id => $mid, name => "ticket $tid", state => $after{type} };
    return {
        id       => $tid,
        reported => 'write',
        returned => {
            method => $p->action('post'), message_id => $mid, attachments => \@made, created => [$made],
            says => "posted " . ( $v->{post_kind} eq 'note' ? 'an internal note' : 'a reply' ) . " $mid on ticket $tid",
        },
        created  => [$made],
        after    => $ok ? \%after : undef,
    };
}

=head2 move_tickets($op, $plan, $closing)

The plan of C<helpdesk.close> ($closing 1) and C<helpdesk.reopen> (0): for each ticket named in the C<ticket> list,
the stage to move it to (the C<stage> parameter, or the first stage its team may use that is closed, or open, in
Odoo's order), through the stage rule of C<stage_change_row>. A ticket already in a stage of that kind is
C<unchanged>.

=cut

sub move_tickets ( $op, $plan, $closing ) {
    my $p = $op->profile;
    my @specs = spec_list( $op->param('ticket') );
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': give the ticket id or number (several, comma separated)' ) if !@specs;
    my $want = $closing ? 'closed' : 'open';
    my $n = 0;
    my %seen;
    for my $spec (@specs) {
        $n++;
        my $key = "ticket:$spec";
        my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); 1 };
        my ( $t, $why ) = ticket_row( $op, $spec, qw(title stage team closed) );
        next if !$t && $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $spec ) );
        next if $seen{ $t->{id} }++ && $hold->( 'invalid', "ticket $t->{id} is named twice" );
        if ( ( $t->{f}{closed} ? 1 : 0 ) == ( $closing ? 1 : 0 ) ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $t->{id}, key => $key, reason => "ticket $t->{id} is already $want" );
            next;
        }
        my $team = id_of( $t->{f}{team} );
        my ( $stage, $name );
        if ( defined $op->param('stage') ) {
            my ( $row, $why2, @many ) = pick_stage( $op, $op->param('stage'), $team );
            next if !$row && $hold->( $why2 eq 'none' ? 'unknown-stage' : 'ambiguous-stage', reason_text( $why2, 'stage', $op->param('stage'), @many ) );
            my $sr = $op->model('stage')->read_one( $row->{id}, [ $p->field( stage => 'closed' ), $p->field( stage => 'name' ) ] );
            next if ( $sr->{ $p->field( stage => 'closed' ) } ? 1 : 0 ) != ( $closing ? 1 : 0 ) && $hold->( 'wrong-stage', "stage '" . $sr->{ $p->field( stage => 'name' ) } . "' is not a $want stage" );
            ( $stage, $name ) = ( $row->{id}, $sr->{ $p->field( stage => 'name' ) } );
        }
        else {
            my $first = applicable_stages( $op, $team, closed => $closing ? 1 : 0 )->[0];
            next if !$first && $hold->( 'no-stage', "no $want stage is open to the ticket's team" . ( $team ? '' : ' (the ticket has no team)' ) );
            ( $stage, $name ) = ( $first->{id}, $first->{name} );
        }
        stage_change_row( $op, $plan, { ticket => $t, stage => $stage, stage_name => $name, key => $key, bucket => $closing ? 'close' : 'reopen' } );
    }
    return scalar @specs;
}

=head2 stages_for_team($p, $stage_model, $team_id, $company_id, %o)

The stages Odoo's C<_get_applicable_stages> gives a team, in its order (sequence, id): the stages that name no
team or name this one, whose company is none or the team's company (a team with no company takes only the stages
of no company). C<closed> 1 keeps the closed ones, 0 the open ones. Each is C<< { id, name, closed, sequence, own,
template } >>, C<own> 1 where the stage names the team and C<template> the name of the stage's mail template, if
any. C<$stage_model> is the model object to read through, so a caller can read as the service login.

=cut

sub stages_for_team ( $p, $stage_model, $team_id, $company_id, %o ) {
    my $f = sub ($lf) { $p->field( stage => $lf ) };
    my @dom;
    push @dom, [ $f->('closed'), '=', $o{closed} ? JSON::PP::true : JSON::PP::false ] if defined $o{closed};
    my $rows = $stage_model->search_read( \@dom, [ map { $f->($_) } qw(name closed sequence teams company template) ], order => 'sequence, id' );
    my @out;
    for my $r (@$rows) {
        my @t  = @{ $r->{ $f->('teams') } // [] };
        my $co = id_of( $r->{ $f->('company') } );
        next if $co && ( !defined $company_id || $co != $company_id );
        my $own = $team_id && grep { $_ == $team_id } @t;
        next if @t && !$own;
        push @out, { id => $r->{id}, name => $r->{ $f->('name') }, closed => flag( $r->{ $f->('closed') } ), sequence => $r->{ $f->('sequence') },
            own => $own ? 1 : 0, template => name_of( $r->{ $f->('template') } ) };
    }
    return \@out;
}

=head2 first_stage_for($op, $client, $team_id, $category_id)

The stage a new ticket is made in, as the module's portal form sets it at create (so Odoo mails that stage's template):
the first stage C<stages_for_team> gives the team. The team is C<$team_id>, else the default team of C<$category_id>
(profile field C<default_team> of the category, where the series has one). C<$client> is the login that reads. Answers
C<< ( $stage_id, $text ) >>: the stage and the plan line saying which template Odoo mails (or that the stage has none), or
an empty list when no team or no stage is known. Used by C<helpdesk.raise> and C<helpdesk.create>.

=cut

sub first_stage_for ( $op, $client, $team_id, $category_id ) {
    my $p = $op->profile;
    if ( !$team_id && defined $p->field( category => 'default_team' ) && $category_id ) {
        my $dt = $client->model( $p->model_name('category') )->read_one( $category_id, [ $p->field( category => 'default_team' ) ] );
        $team_id = id_of( $dt->{ $p->field( category => 'default_team' ) } ) if $dt;
    }
    return () if !$team_id;
    my $team = $client->model( $p->model_name('team') )->read_one( $team_id, [ $p->field( team => 'company' ) ] );
    my ($first) = @{ stages_for_team( $p, $client->model( $p->model_name('stage') ), $team_id, id_of( $team ? $team->{ $p->field( team => 'company' ) } : undef ) ) };
    return () if !$first;
    return ( $first->{id}, $first->{template}
        ? "Odoo mails the template '$first->{template}' to the customer (the portal's acknowledgement) when the ticket is made in stage $first->{name}"
        : "the ticket is made in stage $first->{name}, which has no mail template: Odoo mails the customer nothing" );
}

=head2 add_ticket($op, $plan, %change)

Plans a ticket that an operation makes (C<helpdesk.create>, C<helpdesk.raise>) as a C<custom> change of the
operation (C<kind> C<ticket>, carried out by C<apply_ticket_change>), not as a plain create. The helpdesk service
login holds "User: Team tickets", which Odoo does not let delete a ticket, so the undo of the change is a move to a
closed stage (C<undo_ticket>), never a delete. C<%change> carries C<bucket>, C<key>, C<ref>, C<vals>, C<readback>
and C<reason>.

=cut

sub add_ticket ( $op, $plan, %c ) {
    my $p = $op->profile;
    my $tm = $p->model_name('ticket');
    $plan->add( action => 'custom', kind => 'ticket', handler => $op->op_name, model => $tm, calls => [ [ $tm, 'create' ], [ $tm, 'read' ] ], %c );
    return;
}

=head2 apply_ticket_change($handler_class, $client, \%change)

What C<add_ticket>'s change does when applied: Odoo's C<create> of the ticket and a read of the fields in
C<readback>. Answers C<< { id, after, reported =E<gt> 'create', returned } >>, so the result lists the ticket among the
records made and the journal holds the read-back (the number Odoo gave it, its team, stage, user and partner) as C<returned>. The cancel of such a ticket by a revert is C<kind> C<close-ticket>, carried out here too.

=cut

sub apply_ticket_change ( $class, $client, $c ) {
    return apply_close_ticket( $class, $client, $c ) if ( $c->{kind} // '' ) eq 'close-ticket';
    Odoo::Error->throw( kind => 'usage', message => ( $c->{handler} // 'a helpdesk operation' ) . " cannot apply a change of kind '" . ( $c->{kind} // '' ) . "'" )
        if ( $c->{kind} // '' ) ne 'ticket';
    my $m  = $client->model( $c->{model} );
    my $id = $m->create( $c->{vals} );
    my @f  = @{ $c->{readback} // [] };
    my $row = $m->read_one( $id, @f ? \@f : ['id'] )
        // Odoo::Error->throw( kind => 'fault', message => "read-back found no record $id on $c->{model}" );
    # the journal of a custom change holds what the apply returned, so the read-back (the number, the team, the stage) goes there
    my $number = $row->{number};
    return { id => $id, after => $row, reported => 'create',
        returned => { method => 'create', says => 'made ticket ' . ( defined $number && length $number ? "$number (id $id)" : $id ), %$row } };
}

=head2 undo_ticket($journal_entry)

The revert of a ticket an operation made, as C<undo_custom> returns it: the change that moves the ticket to a
closed stage (the team's own closed stage, else the first closed stage the team may use). The ticket is not
deleted: the service login cannot, and the line says so. The ticket's own stage rule applies (a closed stage that
requires fields the ticket lacks is Odoo's refusal at apply), and Odoo mails the closed stage's template to the
ticket's partner if it has one.

=cut

sub undo_ticket ( $class, $e ) {
    return ( undef, "cannot undo kind '" . ( $e->{kind} // '' ) . "'" ) if ( $e->{kind} // '' ) ne 'ticket' || !$e->{id};
    my $tm = $e->{model} // 'helpdesk.ticket';
    return {
        action => 'custom', handler => $e->{handler}, kind => 'close-ticket', bucket => 'undo-ticket',
        model  => $tm, id => $e->{id}, key => "undo:$tm $e->{id}", vals => { ticket => $e->{id} },
        calls  => [ [ $tm, 'read' ], [ $tm, 'write' ], [ 'helpdesk.ticket.team', 'read' ], [ 'helpdesk.ticket.stage', 'search_read' ] ],
        line   => "close ticket $e->{id} (the team's closed stage, else the first closed stage); a ticket is closed, never deleted",
        reason => "ticket $e->{id} is moved to a closed stage, not deleted: the helpdesk service login holds User: Team tickets, which Odoo does not allow to delete a ticket. "
            . "The ticket stays in Odoo, closed; Odoo mails the closed stage's template to the ticket's partner if the stage has one",
    };
}

# The move to a closed stage that undoes a ticket made: the team's own closed stage, else the first closed stage the
# team may use. A ticket already closed is left as it is.
sub apply_close_ticket ( $class, $client, $c ) {
    my $p  = profile_for( $client, $c->{handler} // 'helpdesk' );
    my $f  = sub ($lf) { $p->field( ticket => $lf ) };
    my $tm = $client->model( $c->{model} );
    my $id = $c->{id};
    my $t  = $tm->read_one( $id, [ map { $f->($_) } qw(team stage closed) ] )
        // Odoo::Error->throw( kind => 'fault', message => "ticket $id is gone or not readable by this login", fix => 'close the ticket in Odoo' );
    if ( $t->{ $f->('closed') } ) {
        return { id => $id, after => { stage_id => id_of( $t->{ $f->('stage') } ), closed => 1 },
            returned => { ticket => $id, closed => 1, says => "ticket $id was already in a closed stage" } };
    }
    my $team = id_of( $t->{ $f->('team') } );
    my $co;
    $co = id_of( $client->model( $p->model_name('team') )->read_one( $team, [ $p->field( team => 'company' ) ] )->{ $p->field( team => 'company' ) } ) if $team;
    my $closed = stages_for_team( $p, $client->model( $p->model_name('stage') ), $team, $co, closed => 1 );
    my ($stage) = ( ( grep { $_->{own} } @$closed ), @$closed );
    Odoo::Error->throw( kind => 'fault', message => "no closed stage is open to the team of ticket $id" . ( $team ? '' : ' (the ticket has no team)' ),
        fix => 'close the ticket in Odoo, or add a closed stage' ) if !$stage;
    $tm->write( $id, { $f->('stage') => $stage->{id} } );
    my $now = $tm->read_one( $id, [ map { $f->($_) } qw(stage closed) ] );
    Odoo::Error->throw( kind => 'fault', message => "ticket $id is in stage " . ( name_of( $now->{ $f->('stage') } ) // '?' ) . " after the move to $stage->{name}, not closed",
        fix => 'close the ticket in Odoo' ) if !$now || !$now->{ $f->('closed') } || ( id_of( $now->{ $f->('stage') } ) // 0 ) != $stage->{id};
    return { id => $id, after => { stage_id => $stage->{id}, closed => 1 },
        returned => { ticket => $id, stage => $stage->{name}, closed => 1, says => "closed ticket $id in stage $stage->{name}" . ( $stage->{template} ? "; Odoo mails '$stage->{template}' to the ticket's partner" : '' ) } };
}


1;
