package Odoo::Test::MailFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use MIME::Base64 ();

use Odoo::Error;
use Odoo::Test::FakeOdoo;

# A fake Odoo 16 or 18 with account.move records, mail templates and the mail composer, each method as the source has it
# (mail_template.py generate_email, mail_compose_message.py generate_email_for_composer / the computed fields of 18 and
# its onchange, action_send_mail) and nothing more:
#
#   16  mail.template.generate_email(res_ids, fields) renders subject, body_html and recipients for each record, and the
#       template's report as ('name.pdf', base64); mail.compose.message.generate_email_for_composer does the same for the
#       composer; the composer is created with the values it is given
#   18  the composer computes subject, body, partner_ids and attachment_ids from template_id when it is created (res_ids a
#       text holding a list); onchange(template_id) answers those values with partner_ids as commands
#   both  action_send_mail posts a comment on the record, makes a notification per recipient (status sent, or exception when
#       $fx->{fail_send} is set) and, when $fx->{keep_mail}, a mail.mail
#
#   my ($fake, $fx) = Odoo::Test::MailFixture->fake( series => 16 );
#   $fx->{render} = sub ($record) { ... { subject =>, body =>, partners => [ids] } };    # what the template renders
#   $fx->{log}    # [ "mail.compose.message.action_send_mail(1)" ... ]

my $c    = sub { { type => 'char', store => 1 } };
my $t    = sub { { type => 'text', store => 1 } };
my $bool = sub { { type => 'boolean', store => 1 } };
my $sel  = sub { { type => 'selection', store => 1 } };
my $int  = sub { { type => 'integer', store => 1 } };
my $m2o  = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };
my $m2m  = sub ($rel) { { type => 'many2many', relation => $rel, store => 1 } };

sub fields ($series) {
    my $f = {
        'account.move' => { name => $c->(), display_name => $c->(), state => $sel->(), partner_id => $m2o->('res.partner') },
        'res.partner' => { name => $c->(), email => $c->(), display_name => $c->() },
        'mail.template' => { name => $c->(), model => $c->(), subject => $c->(), attachment_ids => $m2m->('ir.attachment'),
            ( $series == 16 ? ( report_template => $m2o->('ir.actions.report') ) : ( report_template_ids => $m2m->('ir.actions.report') ) ) },
        'ir.model.data' => { module => $c->(), name => $c->(), model => $c->(), res_id => $int->() },
        'ir.attachment' => { name => $c->(), datas => $t->(), mimetype => $c->(), res_model => $c->(), res_id => $int->(), type => $c->() },
        'ir.actions.report' => { name => $c->(), report_name => $c->(), model => $c->() },
        'ir.module.module' => { name => $c->(), state => $c->() },
        'mail.message' => { model => $c->(), res_id => $int->(), subject => $c->(), body => $t->(), message_type => $sel->(), partner_ids => $m2m->('res.partner'), attachment_ids => $m2m->('ir.attachment') },
        'mail.notification' => { mail_message_id => $m2o->('mail.message'), res_partner_id => $m2o->('res.partner'), notification_type => $sel->(), notification_status => $sel->(), failure_type => $c->(), failure_reason => $c->() },
        'mail.mail' => { mail_message_id => $m2o->('mail.message'), state => $sel->(), failure_reason => $c->() },
        'mail.compose.message' => { composition_mode => $sel->(), model => $c->(), res_id => $int->(), res_ids => $t->(), template_id => $m2o->('mail.template'),
            subject => $c->(), body => $t->(), email_from => $c->(), partner_ids => $m2m->('res.partner'), attachment_ids => $m2m->('ir.attachment') },
    };
    $_->{id} //= $int->() for values %$f;
    return $f;
}

sub _fault ($class, $msg) { Odoo::Test::FakeOdoo::_fault( $class, $msg ) }

sub fake ($class, %o) {
    my $series = $o{series} // 16;
    my $fx = { log => [], series => $series, %{ $o{fx} // {} } };
    my $fake = Odoo::Test::FakeOdoo->new( series => $series, fields => fields($series) );
    $fx->{fake} = $fake;
    bless $fx, 'Odoo::Test::MailFixture::Fx';
    my $d = $fake->{data};
    $fx->{partner} = $fake->insert( 'res.partner', { name => 'OOM Buyer Ltd', email => 'buyer@example.invalid', display_name => 'OOM Buyer Ltd' } );
    $fx->{report}  = $fake->insert( 'ir.actions.report', { name => 'Invoices', report_name => 'account.report_invoice_with_payments', model => 'account.move' } );
    $fx->{template} = $fake->insert( 'mail.template', { name => 'Invoice: Sending', model => 'account.move', subject => '{{ name }}', attachment_ids => [],
        ( $series == 16 ? ( report_template => $fx->{report} ) : ( report_template_ids => [] ) ) } );
    $fake->insert( 'ir.model.data', { module => 'account', name => 'email_template_edi_invoice', model => 'mail.template', res_id => $fx->{template} } );
    $fake->insert( 'ir.model.data', { module => 'account', name => 'account_invoices', model => 'ir.actions.report', res_id => $fx->{report} } );
    $fx->{render} //= sub ($rec, $model = 'account.move') {
        return { subject => "Reminder for $rec->{name}", body => "<p>Dear $rec->{name},</p><p>Your account needs attention.</p>", partners => [ $rec->{id} ] } if $model eq 'res.partner';
        return { subject => "Invoice $rec->{name}", body => "<p>Dear @{[ $d->{'res.partner'}{ $rec->{partner_id} }{name} // 'customer' ]},</p><p>Here is invoice $rec->{name}.</p>", partners => [ $rec->{partner_id} ] } };

    my $m = $fake->{methods};
    my $log = sub ($model, $meth, $ids) { push @{ $fx->{log} }, "$model.$meth(" . join( ',', @$ids ) . ')' };
    my $rec = sub ($fk, $model, $id) { $fk->{data}{$model}{$id} or _fault( 'MissingError', "$model $id gone" ) };
    # a test's own render takes the record alone (invoices); the partner render takes the model too
    my $render = sub ($r, $model) { $model eq 'account.move' ? $fx->{render}->($r) : $fx->{render}->( $r, $model ) };
    my $pdf = sub ($r) { return [ "Invoice_$r->{name}.pdf" =~ s{/}{_}gr, MIME::Base64::encode_base64( "%PDF-fake $r->{name}", '' ) ] };

    if ( $series == 16 ) {
        $m->{'mail.template.generate_email'} = sub ( $fk, $args, $kw ) {
            my ( $tids, $res_ids, $fields ) = @$args;
            $log->( 'mail.template', 'generate_email', $res_ids );
            my $model = $rec->( $fk, 'mail.template', $tids->[0] )->{model};
            my %out;
            for my $rid (@$res_ids) {
                my $r = $rec->( $fk, $model, $rid );
                my $x = $render->( $r, $model );
                $out{$rid} = { subject => $x->{subject}, body_html => $x->{body}, body => $x->{body}, email_from => '"Administrator" <admin@example.com>', email_to => $x->{email_to} // '', email_cc => '', reply_to => '',
                    partner_ids => [ @{ $x->{partners} } ], attachment_ids => [], model => $model, res_id => $rid, attachments => $model eq 'account.move' ? [ $pdf->($r) ] : [] };
            }
            return \%out;
        };
        $m->{'mail.compose.message.generate_email_for_composer'} = sub ( $fk, $args, $kw ) {
            my ( $tid, $res_ids, $fields ) = @$args;
            $log->( 'mail.compose.message', 'generate_email_for_composer', $res_ids );
            my $model = $rec->( $fk, 'mail.template', $tid )->{model};
            my %out;
            for my $rid (@$res_ids) {
                my $r = $rec->( $fk, $model, $rid );
                my $x = $render->( $r, $model );
                $out{$rid} = { subject => $x->{subject}, body => $x->{body}, email_from => '"Administrator" <admin@example.com>', partner_ids => [ @{ $x->{partners} } ], attachments => $model eq 'account.move' ? [ $pdf->($r) ] : [] };
            }
            return $res_ids->[0] && @$res_ids == 1 ? $out{ $res_ids->[0] } : \%out;
        };
    }
    else {
        $m->{'mail.compose.message.onchange'} = sub ( $fk, $args, $kw ) {
            my ( undef, $vals, $names, $spec ) = @$args;
            $log->( 'mail.compose.message', 'onchange', [ $vals->{template_id} ] );
            my ($rid) = $vals->{res_ids} =~ /(\d+)/;
            my $x = $render->( $rec->( $fk, $vals->{model}, $rid ), $vals->{model} );
            return { value => { subject => $x->{subject}, body => $x->{body}, partner_ids => [ map { [ 4, $_, { id => $_ } ] } @{ $x->{partners} } ] } };
        };
        # the computed fields of the composer: subject, body and recipients from the template when it is created
        $m->{'mail.compose.message.create'} = sub ( $fk, $args, $kw ) {
            my $v = { %{ $args->[0] } };
            $log->( 'mail.compose.message', 'create', [] );
            if ( $v->{template_id} && !defined $v->{subject} ) {
                my ($rid) = ( $v->{res_ids} // '' ) =~ /(\d+)/;
                my $x = $render->( $rec->( $fk, $v->{model}, $rid ), $v->{model} );
                $v->{subject} = $x->{subject};
                $v->{body} = $x->{body};
                $v->{partner_ids} = [ [ 6, 0, $x->{partners} ] ];
            }
            my $id = ++$fk->{next_id}{'mail.compose.message'};
            $fk->{data}{'mail.compose.message'}{$id} = { id => $id, active => 1 };
            $fk->_assign( 'mail.compose.message', $fk->{data}{'mail.compose.message'}{$id}, $v );
            return $id;
        };
    }

    $m->{'mail.compose.message.action_send_mail'} = sub ( $fk, $args, $kw ) {
        $log->( 'mail.compose.message', 'action_send_mail', $args->[0] );
        for my $w ( map { $rec->( $fk, 'mail.compose.message', $_ ) } @{ $args->[0] } ) {
            my ($rid) = $w->{res_id} || ( ( $w->{res_ids} // '' ) =~ /(\d+)/ )[0];
            my $mid = $fk->insert( 'mail.message', { model => $w->{model}, res_id => $rid, subject => $w->{subject}, body => $w->{body}, message_type => 'comment',
                partner_ids => [ @{ $w->{partner_ids} // [] } ], attachment_ids => [ @{ $w->{attachment_ids} // [] } ] } );
            for my $pid ( @{ $w->{partner_ids} // [] } ) {
                $fk->insert( 'mail.notification', { mail_message_id => $mid, res_partner_id => $pid, notification_type => 'email', notification_status => $fx->{fail_send} ? 'exception' : 'sent',
                    ( $fx->{fail_send} ? ( failure_type => 'mail_smtp', failure_reason => 'Connection refused' ) : () ) } );
            }
            $fk->insert( 'mail.mail', { mail_message_id => $mid, state => $fx->{fail_send} ? 'exception' : 'sent' } ) if $fx->{keep_mail};
            # Odoo posts a note about the attachments after the mail
            $fk->insert( 'mail.message', { model => $w->{model}, res_id => $rid, subject => 0, body => 'attachments', message_type => 'comment', partner_ids => [], attachment_ids => [] } ) if $fx->{note_after};
        }
        return { type => 'ir.actions.act_window_close' };
    };
    return ( $fake, $fx );
}

package Odoo::Test::MailFixture::Fx;

sub invoice ($fx, %o) {
    return $fx->{fake}->insert( 'account.move', { name => $o{name} // 'INV/2026/00001', display_name => $o{name} // 'INV/2026/00001', state => 'posted', partner_id => $o{partner} // $fx->{partner} } );
}

1;
