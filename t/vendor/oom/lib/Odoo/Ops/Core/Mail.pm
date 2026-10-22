package Odoo::Ops::Core::Mail;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(sha256_hex);
use Encode ();
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Rows;
use Odoo::Ops::Pack;
use Odoo::Ops::Core::ActionCommon;
use Odoo::Ops::Mailing::Plaintext;

use parent 'Odoo::Ops::Operation';

my $AC = 'Odoo::Ops::Core::ActionCommon';

=head1 NAME

Odoo::Ops::Core::Mail - send a mail template on any record, through Odoo's composer

=head1 SYNOPSIS

    oom-ops run core.mail --conf ops.conf --set model=account.move --set record=name=INV/2026/00006 \
        --set template=account.email_template_edi_invoice
    oom-ops run core.mail --conf ops.conf --set model=account.move --set records=12,13 \
        --set template=account.email_template_edi_invoice --set reports=account.account_invoices --set partners=44
    oom-ops run core.mail --conf ops.conf --set rows=mails.jsonl

=head1 DESCRIPTION

C<core.mail> sends one C<mail.template> (an xml id such as C<account.email_template_edi_invoice>, or an id)
on one record of any model: Odoo's own mail composer (C<mail.compose.message>, comment mode) renders the
template for the record and posts it, as the config's login, on the record's history, and mails the recipients
the template names. It is the generic form of what C<comms.send> does for leads. Mail goes where the instance's
outgoing mail server sends it (on the development cluster, the mail catcher).

C<model> and C<record> (an id, or C<field=value> such as C<name=INV/2026/00006>) or C<records> (ids) name the
records; C<template> the template. C<reports> adds attachments Odoo renders: each entry is a report's xml id or
C<report_name> (rendered for the same record) or C<report:ID> (rendered for that record of the report's own model, such
as a statement report of a partner sent with an invoice). The report is rendered when the plan is made
(L<core.report|Odoo::Ops::Core::Report> inline; C<report_source> says render, attachment or auto, default auto) and the
plan carries it, so what is sent is what was approved; rendering needs a web session unless the report has a stored
copy. C<partners> are extra recipients (C<res.partner> ids) added to the ones the template names. C<documents> attaches files the
caller holds, a list of C<< { name, mimetype, content_base64 } >> (a statement rendered with the C<options> of
L<core.report|Odoo::Ops::Core::Report>, a file read from disk); a row may carry its own.

C<rows> (a C<.jsonl>, C<.json> or C<.csv> file) or C<items> (a list, in-process) gives one mail per row instead,
each C<< { model, record, template, reports?, partners? } >> with the parameters above as defaults for a row that leaves
one out.

B<The plan is the dry run.> C<oom-ops run core.mail> renders the template for each record and shows the subject,
the body as text, the recipients (name and address) and the attachments; nothing is sent until the plan is applied.
Odoo renders the template's own report (16) when it renders the template, and a report stored on the record may be
stored by that render, as for any print.

Apply renders the template again, refuses C<stale> when the subject or body is not what the plan showed, creates the
composer, adds the extra recipients and the report attachments, sends, and reads back the C<mail.message> it posted
(id, subject, recipients, attachments) and, for each recipient, the notification Odoo made (C<sent>, C<exception>,
C<ready>): a mail that Odoo could not send is reported as the state Odoo gives it, with its reason. There is no
revert: a sent mail cannot be taken back (C<oom-ops revert> says so).

A record that is not found is held C<unknown-record>; a template that is not found C<unknown-template>; a template
made for another model C<template-model>; a report C<unknown-report>; a partner C<unknown-partner>; a mail with no
recipient at all C<no-recipient>.

Series 16 and 18. The composer differs: on 16 the template is rendered by C<generate_email_for_composer> and the
composer is given the result; on 18 the composer computes subject, body and recipients from the template itself and
the plan reads the same by Odoo's C<onchange>. Any other series is refused by name (C<series>).

A write operation: plans only; C<apply> carries it out.

=cut

sub op_name ($class) { 'core.mail' }
sub summary ($class) { 'Plan sending a mail template on records of any model through Odoo\'s composer; the plan shows the rendered mail' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model         => { type => 'str',  help => 'physical model of the records, e.g. account.move (not with rows or items)' },
        record        => { type => 'str',  help => 'one record: an id, or field=value such as name=INV/2026/00006' },
        records       => { type => 'list', help => 'comma-separated record ids (instead of record)' },
        template      => { type => 'str',  help => 'the mail template: an xml id (module.name) or an id' },
        reports       => { type => 'list', help => 'reports to attach, rendered by Odoo: report_name or xml id, or report:ID for another record of the report\'s model' },
        report_source => { type => 'str',  default => 'auto', help => 'where a report\'s bytes come from: render (needs a web session), attachment (the stored copy) or auto' },
        partners      => { type => 'list', help => 'extra recipients: res.partner ids' },
        documents     => { type => 'json', help => 'documents to attach that the caller holds: a list of { name, mimetype, content_base64 } (a statement rendered with core.report options, a file)' },
        rows          => { type => 'path', help => 'rows file: .jsonl, .json (a list) or .csv with model, record, template, reports, partners' },
        items         => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
    };
}
sub buckets ($class) {
    [ { name => 'mail', meaning => 'the template is rendered for the record and sent through Odoo\'s composer; the plan shows the rendered mail' } ];
}
sub holds ($class) {
    [
        { name => 'unknown-record', meaning => 'no record has that id, or matches that field=value' },
        { name => 'unknown-template', meaning => 'no mail template has that id or xml id' },
        { name => 'template-model', meaning => 'the template is made for another model than the record\'s' },
        { name => 'unknown-report', meaning => 'no report has that name or xml id' },
        { name => 'unknown-partner', meaning => 'no res.partner has that id' },
        { name => 'no-recipient', meaning => 'the template names no recipient for the record and no partner was given' },
        { name => 'invalid', meaning => 'the row is malformed' },
    ];
}
sub read_scope ($class) {
    {   'mail.template' => [qw(read search_read generate_email)], 'mail.compose.message' => ['onchange'], 'ir.model.data' => ['search_read'],
        'ir.actions.report' => ['search_read'], 'ir.attachment' => [qw(search_read read)], 'res.partner' => [qw(read search_read)],
    };
}
sub write_scope ($class) {
    { 'mail.compose.message' => [qw(create read write action_send_mail generate_email_for_composer)], 'ir.attachment' => ['create'],
        'mail.message' => [qw(read search_read)], 'mail.mail' => ['search_read'], 'mail.notification' => ['search_read'] };
}

# the model of each record is known only once the parameters are read
sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    my %models;
    $models{ $self->param('model') } = 1 if defined $self->param('model');
    # the models a rows file or items name are known once they are read
    if ( defined $self->param('rows') || defined $self->param('items') ) {
        $self->{jobs} //= [ $self->_jobs ];
        $models{$_} = 1 for map { $_->{model} } grep { ref $_ eq 'HASH' && defined $_->{model} } @{ $self->{jobs} };
    }
    for my $m ( keys %models ) {
        my %have = map { $_ => 1 } @{ $s->{$m} // [] };
        $have{$_} = 1 for qw(read search_read);
        $s->{$m} = [ sort keys %have ];
    }
    return $s;
}

my %FIELDS16 = map { $_ => 1 } qw(subject body_html email_from email_to email_cc partner_to reply_to);

sub _usage ($why) { Odoo::Error->throw( kind => 'usage', message => "core.mail: $why", fix => 'oom-ops describe core.mail lists the parameters' ) }

sub _jobs ($self) {
    my %p = ( map { $_ => $self->param($_) } qw(model record records template reports report_source partners documents) );
    my $rows = $self->param('rows');
    my $items = $self->param('items');
    _usage('give rows or items, or model with record or records, not both') if ( defined $rows || defined $items ) && ( defined $p{record} || @{ $p{records} // [] } );
    _usage('give rows or items, not both') if defined $rows && defined $items;
    my $source = $p{report_source};
    _usage("report_source must be render, attachment or auto, not '$source'") if $source !~ /\A(?:render|attachment|auto)\z/;
    my @jobs;
    if ( defined $rows || defined $items ) {
        my $env = defined $items ? Odoo::Ops::Rows->load( 'core.mail', records => $items ) : Odoo::Ops::Rows->load( 'core.mail', rows => $rows );
        for my $e (@$env) {
            my %v = %{ $e->{values} };
            my %j = ( key => $e->{key}, map { $_ => ( $v{$_} // $p{$_} ) } qw(model record template report_source) );
            $j{record}   = $v{records} if !defined $v{record} && defined $v{records};
            $j{reports}  = _list( $v{reports} // $p{reports} );
            $j{partners} = _list( $v{partners} // $p{partners} );
            $j{documents} = $v{documents} // $p{documents};
            $j{report_source} //= $source;
            $j{error} = $e->{error} if defined $e->{error};
            push @jobs, \%j;
        }
        return @jobs;
    }
    _usage('give model, with record or records, and template, or rows') if !defined $p{model} || !defined $p{template};
    return ( { key => 'mail', model => $p{model}, record => $p{record}, ids => $p{records}, template => $p{template}, reports => $p{reports} // [], partners => $p{partners} // [], documents => $p{documents}, report_source => $source } );
}

sub _list ($v) { return [] if !defined $v; return $v if ref $v eq 'ARRAY'; return [ grep { length } map { s/^\s+|\s+\z//gr } split /,/, $v ] }

sub plan ($self) {
    my $series = $self->client->server_series;
    Odoo::Error->throw( kind => 'refused', code => 'series', message => "core.mail is not probed on Odoo $series: the composer is met on 16 and 18" ) if $series != 16 && $series != 18;
    my @jobs = @{ $self->{jobs} //= [ $self->_jobs ] };
    my $plan = $self->new_plan( input_count => 0 );
    my %tpl_cache;
    my $n = 0;
    $n += $self->_plan_job( $plan, $_, \%tpl_cache, $series ) for @jobs;
    $plan->set_input_count($n);
    return $plan;
}

sub _template ($self, $ref, $cache) {
    return $cache->{$ref} if exists $cache->{$ref};
    my $tpl = $self->client;
    my @f = ( 'id', 'name', 'model', 'subject', 'attachment_ids', ( $self->client->server_series == 16 ? ('report_template') : ('report_template_ids') ) );
    my $t;
    if ( $ref =~ /\A\d+\z/ ) {
        ($t) = @{ $self->client->model('mail.template')->search_read( [ [ 'id', '=', 0 + $ref ] ], \@f ) };
    }
    elsif ( $ref =~ /\A([\w]+)\.([\w.]+)\z/ ) {
        my $d = $self->client->model('ir.model.data')->search_read( [ [ 'module', '=', $1 ], [ 'name', '=', $2 ], [ 'model', '=', 'mail.template' ] ], ['res_id'] );
        ($t) = @{ $self->client->model('mail.template')->search_read( [ [ 'id', '=', $d->[0]{res_id} ] ], \@f ) } if @$d;
    }
    else { _usage("template '$ref' is neither an id nor an xml id such as account.email_template_edi_invoice") }
    return $cache->{$ref} = $t;
}

sub _plan_job ($self, $plan, $j, $tcache, $series) {
    my $me = $self->op_name;
    if ( defined $j->{error} ) {
        $plan->add( bucket => 'invalid', action => 'hold', key => $j->{key}, reason => "$me: $j->{error}" );
        return 1;
    }
    for my $k (qw(model template)) { if ( !defined $j->{$k} ) { $plan->add( bucket => 'invalid', action => 'hold', key => $j->{key}, reason => "$me: the row names no $k" ); return 1 } }
    _usage("model must be a model name such as account.move, got '$j->{model}'") if !$self->is_model_name( $j->{model} );
    my $model = $j->{model};
    my $m = $self->client->model($model);
    my $fields = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, $me, $model, $@ );
    my ( $want, $by_id ) = $AC->resolve_records( $self->client, $me, $model, $fields, $j->{record}, $j->{ids}, [ 'id', 'display_name' ] );
    my $t = $self->_template( $j->{template}, $tcache );
    my @partners = map { 0 + $_ } grep { /\A\d+\z/ } @{ $j->{partners} };
    _usage("partners must be res.partner ids, got '" . join( ', ', grep { !/\A\d+\z/ } @{ $j->{partners} } ) . "'") if @partners != @{ $j->{partners} };
    my %pfound = @partners ? map { $_->{id} => $_ } @{ $self->client->model('res.partner')->search_read( [ [ 'id', 'in', \@partners ] ], [ 'id', 'name', 'email' ], context => { active_test => JSON::PP::false } ) } : ();
    my $count = 0;
    for my $w (@$want) {
        $count++;
        my ( $id, $label ) = @$w;
        my $key = "$model:" . ( $id // $label );
        my $row = defined $id ? $by_id->{$id} : undef;
        if ( !$row ) {
            $plan->add( bucket => 'unknown-record', action => 'hold', key => $key, reason => "$me: no $model " . ( defined $id ? "has id $id" : "matches $label" ) );
            next;
        }
        if ( !$t ) {
            $plan->add( bucket => 'unknown-template', action => 'hold', key => $key, reason => "$me: no mail template '$j->{template}'" );
            next;
        }
        if ( $t->{model} ne $model ) {
            $plan->add( bucket => 'template-model', action => 'hold', key => $key, reason => "$me: template '$t->{name}' ($j->{template}) is made for $t->{model}, not $model" );
            next;
        }
        if ( my @missing = grep { !$pfound{$_} } @partners ) {
            $plan->add( bucket => 'unknown-partner', action => 'hold', key => $key, reason => "$me: no res.partner has id " . join( ', ', @missing ) );
            next;
        }
        my $what = "$model $id" . ( length( $row->{display_name} // '' ) ? " ($row->{display_name})" : '' );
        my ( $attachments, $why ) = $self->_reports( $j, $model, $id );
        if ($why) {
            $plan->add( bucket => 'unknown-report', action => 'hold', key => $key, reason => "$me: $what: $why" );
            next;
        }
        my ( $docs, $bad ) = _documents( $j->{documents} );
        if ($bad) {
            $plan->add( bucket => 'invalid', action => 'hold', key => $key, reason => "$me: $what: $bad" );
            next;
        }
        push @$attachments, @$docs;
        my $r = $self->_render( $series, $t, $model, $id );
        my @rcpt = $self->_recipients( $r->{partner_ids}, \@partners, \%pfound );
        if ( !@rcpt && !length( $r->{email_to} // '' ) && !length( $r->{email_cc} // '' ) ) {
            $plan->add( bucket => 'no-recipient', action => 'hold', key => $key, reason => "$me: $what: the template renders no recipient and no partner was given" );
            next;
        }
        my @names = ( @{ $r->{attachment_names} }, map { $_->{name} } @$attachments );
        my $text = Odoo::Ops::Mailing::Plaintext::html2plaintext( $r->{body} // '' );
        $text =~ s/\s+\z//;
        my $short = length $text > 300 ? substr( $text, 0, 300 ) . ' ...' : $text;
        $plan->note("$what: subject: $r->{subject}");
        $plan->note("  to: " . join( ', ', map { "$_->{name}" . ( length( $_->{email} // '' ) ? " <$_->{email}>" : '' ) } @rcpt ) . ( length( $r->{email_to} // '' ) ? "; also $r->{email_to}" : '' ) );
        $plan->note( "  attachments: " . ( @names ? join( ', ', @names ) : 'none' ) );
        $plan->note("  body: $short");
        $plan->add(
            bucket => 'mail', action => 'custom', handler => $me, kind => 'mail', key => $key, id => $id, model => $model,
            calls => $self->_calls($series),
            vals => {
                series => $series, template => $t->{id}, template_name => $t->{name}, subject => $r->{subject}, body_sha256 => sha256_hex( Encode::encode_utf8( $r->{body} // '' ) ),
                partners => \@partners, attachments => $attachments, name => ( $row->{display_name} // '' ), recipients => [ map { $_->{id} } @rcpt ],
            },
            line => "$what: mail '$r->{subject}' to " . join( ', ', map { $_->{name} } @rcpt ) . ( @names ? '; ' . scalar(@names) . ' attachment' . ( @names == 1 ? '' : 's' ) : '' ),
            reason => "$what: template '$t->{name}' is rendered and sent through Odoo's composer",
        );
    }
    return $count;
}

sub _calls ($self, $series) {
    return [ [ 'mail.message', 'search_read' ], [ 'mail.mail', 'search_read' ], [ 'mail.notification', 'search_read' ], [ 'mail.compose.message', 'create' ],
        [ 'mail.compose.message', 'read' ], [ 'mail.compose.message', 'write' ], [ 'mail.compose.message', 'action_send_mail' ], [ 'ir.attachment', 'create' ],
        ( $series == 16 ? ( [ 'mail.compose.message', 'generate_email_for_composer' ] ) : () ) ];
}

# the documents the caller supplies: [ { name, mimetype, content_base64 } ] as attachments, or (undef, why)
sub _documents ($docs) {
    return ( [], undef ) if !defined $docs || ( ref $docs eq 'ARRAY' && !@$docs );
    return ( undef, 'documents is a list of { name, mimetype, content_base64 }' ) if ref $docs ne 'ARRAY';
    my @out;
    for my $d (@$docs) {
        return ( undef, 'a document is { name, mimetype, content_base64 }' ) if ref $d ne 'HASH' || !length( $d->{name} // '' ) || !length( $d->{content_base64} // '' );
        return ( undef, "document '$d->{name}' is not base64" ) if $d->{content_base64} !~ m{\A[A-Za-z0-9+/=\s]+\z};
        push @out, { name => $d->{name}, mimetype => $d->{mimetype} // 'application/octet-stream', datas => $d->{content_base64} =~ s/\s+//gr };
    }
    return ( \@out, undef );
}

# the reports to attach, rendered through core.report inline: [ { name, mimetype, datas } ] or (undef, why)
sub _reports ($self, $j, $model, $id) {
    my @out;
    for my $ref ( @{ $j->{reports} } ) {
        my ( $report, $rid ) = $ref =~ /\A(.+):(\d+)\z/ ? ( $1, 0 + $2 ) : ( $ref, $id );
        my $rep = eval { Odoo::Ops::Pack->read( $self, 'core.report', report => $report, ( $ref =~ /:\d+\z/ ? () : ( model => $model ) ), ids => [$rid], inline => 1, source => $j->{report_source} ) };
        if ( my $e = $@ ) {
            my $m = ref $e && $e->can('message') ? $e->message : "$e";
            return ( undef, "report '$ref': $m" =~ s/\s+\z//r ) if ref $e && $e->can('code') && ( $e->code // '' ) eq 'unknown-report';
            die $e;
        }
        for my $d ( @{ $rep->{rows} } ) {
            push @out, { name => $d->{name}, mimetype => $d->{mimetype}, datas => $d->{content_base64} };
        }
    }
    return ( \@out, undef );
}

sub _render ($self, $series, $t, $model, $id) {
    if ( $series == 16 ) {
        my $got = $self->client->execute_kw( 'mail.template', 'generate_email', [ [ $t->{id} ], [$id], [ sort keys %FIELDS16 ] ] );
        my $r = $got->{$id} // $got;
        return {
            subject => $r->{subject} // '', body => $r->{body_html} // $r->{body} // '', email_from => $r->{email_from}, email_to => $r->{email_to}, email_cc => $r->{email_cc},
            partner_ids => [ grep { !ref } @{ $r->{partner_ids} // [] } ],
            attachment_names => [ ( map { $_->[0] } @{ $r->{attachments} // [] } ), $self->_attachment_names( $r->{attachment_ids} ) ],
        };
    }
    my $got = $self->client->execute_kw( 'mail.compose.message', 'onchange',
        [ [], { composition_mode => 'comment', model => $model, res_ids => "[$id]", template_id => $t->{id} }, ['template_id'],
            { map { $_ => {} } qw(composition_mode model res_ids template_id subject body partner_ids email_from attachment_ids) } ] );
    my $v = $got->{value} // {};
    my @partners = map { $_->[0] == 4 ? $_->[1] : $_->[0] == 6 ? @{ $_->[2] } : () } @{ $v->{partner_ids} // [] };
    my @att = map { $_->[0] == 4 ? $_->[1] : $_->[0] == 6 ? @{ $_->[2] } : () } @{ $v->{attachment_ids} // [] };
    my @rep = @{ ref $t->{report_template_ids} eq 'ARRAY' ? $t->{report_template_ids} : [] };
    my @repnames = @rep ? map { $_->{name} . ' (report)' } @{ $self->client->model('ir.actions.report')->search_read( [ [ 'id', 'in', \@rep ] ], ['name'] ) } : ();
    return {
        subject => $v->{subject} // '', body => $v->{body} // '', email_from => $v->{email_from}, email_to => undef, email_cc => undef, partner_ids => \@partners,
        attachment_names => [ $self->_attachment_names( \@att ), @repnames ],
    };
}

sub _attachment_names ($self, $ids) {
    my @ids = grep { !ref } @{ $ids // [] };
    return () if !@ids;
    return map { $_->{name} } @{ $self->client->model('ir.attachment')->search_read( [ [ 'id', 'in', \@ids ] ], ['name'] ) };
}

sub _recipients ($self, $ids, $extra, $found) {
    my %seen;
    my @ids = grep { !$seen{$_}++ } @{ $ids // [] }, @$extra;
    return () if !@ids;
    my %known = %$found;
    my @need = grep { !$known{$_} } @ids;
    $known{ $_->{id} } = $_ for @need ? @{ $self->client->model('res.partner')->search_read( [ [ 'id', 'in', \@need ] ], [ 'id', 'name', 'email' ], context => { active_test => JSON::PP::false } ) } : ();
    return map { { id => $_, name => $known{$_}{name} // "partner $_", email => $known{$_}{email} } } grep { $known{$_} } @ids;
}

=head2 apply_custom($class, $client, $change)

Renders the template again, refuses C<stale> when the subject or body differs from the plan's, makes the composer, adds
the extra recipients and the report attachments, sends, and reads back the posted message, its notifications and its
mail.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'mail';
    my $v = $c->{vals};
    my ( $model, $id, $series ) = ( $c->{model}, $c->{id}, $v->{series} );
    my $last = $client->execute_kw( 'mail.message', 'search_read', [ [ [ 'model', '=', $model ], [ 'res_id', '=', $id ] ] ], { fields => ['id'], order => 'id desc', limit => 1 } );
    my $max = @$last ? $last->[0]{id} : 0;
    my ( $wid, $subject, $body );
    my @att_extra;
    for my $a ( @{ $v->{attachments} // [] } ) {
        push @att_extra, $client->execute_kw( 'ir.attachment', 'create', [ { name => $a->{name}, datas => $a->{datas}, mimetype => $a->{mimetype}, res_model => 'mail.compose.message', res_id => 0, type => 'binary' } ] );
    }
    if ( $series == 16 ) {
        my $got = $client->execute_kw( 'mail.compose.message', 'generate_email_for_composer', [ $v->{template}, [$id], [qw(subject body_html email_from email_cc email_to partner_to reply_to attachment_ids mail_server_id)] ] );
        my $r = $got->{$id} // $got;
        ( $subject, $body ) = ( $r->{subject} // '', $r->{body} // $r->{body_html} // '' );
        $class->_stale( $v, $subject, $body, $model, $id );
        my @att = @{ $r->{attachment_ids} // [] };
        for my $a ( @{ $r->{attachments} // [] } ) {
            push @att, $client->execute_kw( 'ir.attachment', 'create', [ { name => $a->[0], datas => $a->[1], res_model => 'mail.compose.message', res_id => 0, type => 'binary' } ] );
        }
        my %seen;
        my @partners = grep { !$seen{$_}++ } @{ $r->{partner_ids} // [] }, @{ $v->{partners} };
        $wid = $client->execute_kw( 'mail.compose.message', 'create', [ {
            composition_mode => 'comment', model => $model, res_id => $id, template_id => $v->{template}, subject => $subject, body => $body,
            ( length( $r->{email_from} // '' ) ? ( email_from => $r->{email_from} ) : () ),
            partner_ids => [ [ 6, 0, \@partners ] ], attachment_ids => [ [ 6, 0, [ @att, @att_extra ] ] ],
        } ] );
    }
    else {
        $wid = $client->execute_kw( 'mail.compose.message', 'create', [ { composition_mode => 'comment', model => $model, res_ids => "[$id]", template_id => $v->{template} } ] );
        my $w = $client->execute_kw( 'mail.compose.message', 'read', [ [$wid] ], { fields => [qw(subject body)] } )->[0];
        ( $subject, $body ) = ( $w->{subject} // '', $w->{body} // '' );
        $class->_stale( $v, $subject, $body, $model, $id );
        my @cmds = ( ( map { [ 4, $_ ] } @{ $v->{partners} } ) );
        $client->execute_kw( 'mail.compose.message', 'write', [ [$wid], { ( @cmds ? ( partner_ids => \@cmds ) : () ), ( @att_extra ? ( attachment_ids => [ map { [ 4, $_ ] } @att_extra ] ) : () ) } ] )
            if @cmds || @att_extra;
    }
    $client->execute_kw( 'mail.compose.message', 'action_send_mail', [ [$wid] ] );
    # the message the composer posted: a comment with the rendered subject (Odoo may post a note about the attachments after it)
    my $msg = $client->execute_kw( 'mail.message', 'search_read', [ [ [ 'model', '=', $model ], [ 'res_id', '=', $id ], [ 'id', '>', $max ], [ 'message_type', '=', 'comment' ], [ 'subject', '=', $subject ] ] ],
        { fields => [qw(id subject message_type partner_ids attachment_ids)], order => 'id desc', limit => 1 } );
    Odoo::Error->throw( kind => 'fault', message => "no message was posted on $model $id after sending", fix => 'Odoo took the composer without posting; read the record\'s history' ) if !@$msg;
    my $m = $msg->[0];
    my $notes = $client->execute_kw( 'mail.notification', 'search_read', [ [ [ 'mail_message_id', '=', $m->{id} ] ] ], { fields => [qw(res_partner_id notification_type notification_status failure_type failure_reason)], order => 'id' } );
    my $mails = $client->execute_kw( 'mail.mail', 'search_read', [ [ [ 'mail_message_id', '=', $m->{id} ] ] ], { fields => [qw(id state failure_reason)], order => 'id' } );
    my %ret = (
        message_id => $m->{id}, subject => $m->{subject}, message_type => $m->{message_type}, recipients => $m->{partner_ids}, attachments => $m->{attachment_ids},
        notifications => [ map { { partner => ( ref $_->{res_partner_id} eq 'ARRAY' ? $_->{res_partner_id}[0] : undef ), type => $_->{notification_type}, status => $_->{notification_status},
                ( $_->{failure_type} ? ( failure_type => $_->{failure_type} ) : () ), ( $_->{failure_reason} ? ( failure_reason => $_->{failure_reason} ) : () ) } } @$notes ],
        mails => [ map { { id => $_->{id}, state => $_->{state}, ( $_->{failure_reason} ? ( failure_reason => $_->{failure_reason} ) : () ) } } @$mails ],
    );
    return { id => $id, returned => \%ret, after => { message_id => $m->{id} } };
}

sub _stale ($class, $v, $subject, $body, $model, $id) {
    return if $subject eq $v->{subject} && sha256_hex( Encode::encode_utf8($body) ) eq $v->{body_sha256};
    Odoo::Error->throw( kind => 'refused', code => 'stale', message => "core.mail: the mail Odoo renders for $model $id is not the one the plan showed" . ( $subject ne $v->{subject} ? " (subject now '$subject')" : ' (the body differs)' ),
        fix => 'plan it again: oom-ops run core.mail with the same parameters' );
}

# a sent mail cannot be taken back
sub undo_custom ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'mail';
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    return ( undef, 'a sent mail cannot be taken back' . ( $ret->{message_id} ? " (mail.message $ret->{message_id} stays in the record's history)" : '' ) );
}

1;
