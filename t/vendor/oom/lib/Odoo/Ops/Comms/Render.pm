package Odoo::Ops::Comms::Render;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Path qw(make_path);
use File::Spec;
use Template;
use YAML::PP;

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Comms::Render - one message per selected lead, for review

=head1 DESCRIPTION

C<comms.render>: renders a message template for each selected lead
and writes the results to files - nothing is sent. The owner reads
C<preview.html> (every message, one page), may edit any single message
file, and then C<comms.send> plans sending exactly what the files say.

A template is YAML with Template Toolkit fields:

    campaign: expo-2026-followup
    subject: "Good to meet you at Odoo Expo 2026"
    body: |
      <p>Dear [% lead.contact_name | html %],</p>
      <p>...</p>
      <p>[% sender.name | html %]</p>

Variables: C<lead> (logical field names; many2one as C<{id, name}>,
tags as a list of names), C<sender> (C<name>, C<email> of the configured
user).

Leads are set aside, by bucket, when they have no email address, are
on Odoo's blacklist, or already have an email in their history with the
same rendered subject (so a campaign is not sent twice).

Output in the run directory: C<messages/<lead id>.html>,
C<messages.jsonl> (lead id, email, subject, file, body hash) and
C<preview.html>. The report holds counts only.

=cut

sub op_name ($class) { 'comms.render' }
sub summary ($class) { 'Render a message per selected lead to files (sends nothing)' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        template => { type => 'path', required => 1, help => 'message template (YAML)' },
    };
}
sub read_scope ($class) {
    {   lead           => ['search_read'],
        tag            => [qw(search_read read)],
        'mail.message' => ['search_read'],
    };
}

sub load_template ($class, $path) {
    my $t = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) }
        or Odoo::Error->throw( kind => 'config', message => "cannot load template $path: $@" );
    for my $k (qw(campaign subject body)) {
        Odoo::Error->throw( kind => 'config', message => "template $path missing '$k'" ) if !$t->{$k};
    }
    return $t;
}

sub report ($self) {
    my $p   = $self->profile;
    my $v   = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile',
        message => 'crm profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my $tpl = $self->load_template( $self->param('template') );

    my $me = $self->client->execute_kw( 'res.users', 'read', [ [ $self->client->uid ] ], { fields => [qw(name email)] } )->[0];
    my %sender = ( name => $me->{name}, email => $me->{email} || undef );

    my $lf_all = $p->fields('lead');
    my @lf = grep { my $d = $p->descriptor( lead => $_ ); $d && ( $d->{type} // '' ) ne 'binary' } sort keys %$lf_all;
    my $leads = $self->model('lead')->all( Odoo::Ops::CRM::Select->domain_for($self), [ map { $lf_all->{$_} } @lf ] );

    my $tags = $self->_tag_names( $leads, $p->field( lead => 'tags' ) );
    my $dir  = File::Spec->catdir( $self->ctx->run_dir( $self->op_name ), 'messages' );
    make_path($dir);
    my $tt = Template->new( { ENCODING => 'utf8' } );

    my ( %count, @index );
    my $email_f = $p->field( lead => 'email' );
    my $bl_f    = $p->has_field( lead => 'blacklisted' ) ? $p->field( lead => 'blacklisted' ) : undef;
    for my $row (@$leads) {
        my $lead = $self->_logical( $row, \@lf, $tags );
        if ( !$lead->{email} ) { $count{'no-email'}++; next }
        if ( $bl_f && $row->{$bl_f} ) { $count{blacklisted}++; next }

        my %vars = ( lead => $lead, sender => \%sender );
        my ( $subject, $body ) = ( '', '' );
        if ( !$tt->process( \$tpl->{subject}, \%vars, \$subject ) || !$tt->process( \$tpl->{body}, \%vars, \$body ) ) {
            $count{'render-error'}++;
            push @{ $self->{errors} }, "lead $row->{id}: " . $tt->error;
            next;
        }
        $subject =~ s/^\s+|\s+\z//g;
        $subject =~ s/\s+/ /g;
        if ( sent_before( $self->client, $p->model_name('lead'), $row->{id}, $subject ) ) {
            $count{'already-sent'}++;
            next;
        }

        my $file = File::Spec->catfile( $dir, "$row->{id}.html" );
        open my $fh, '>:raw', $file or Odoo::Error->throw( kind => 'config', message => "cannot write $file: $!" );
        print {$fh} encode_utf8($body);
        close $fh;
        push @index, {
            lead_id  => $row->{id}, email => $lead->{email}, subject => $subject,
            file     => $file, body_sha256 => sha256_hex( encode_utf8($body) ),
            campaign => $tpl->{campaign}, template => $self->param('template'),
        };
        $count{rendered}++;
    }

    my $jsonl = File::Spec->catfile( $self->ctx->run_dir( $self->op_name ), 'messages.jsonl' );
    open my $ix, '>:raw', $jsonl or Odoo::Error->throw( kind => 'config', message => "cannot write $jsonl: $!" );
    print {$ix} Odoo::Ops::json()->encode($_), "\n" for @index;
    close $ix;
    my $preview = $self->_preview( \@index, $tpl );

    return {
        campaign => $tpl->{campaign},
        selected => scalar @$leads,
        counts   => \%count,
        messages => $jsonl,
        preview  => $preview,
        ( $self->{errors} ? ( render_errors => $self->{errors} ) : () ),
    };
}

=head2 sent_before($client, $model, $id, $subject)

Function: true if the record's history holds an email with exactly
this subject. Used by render and, again at plan time, by
C<comms.send>.

=cut

sub sent_before ($client, $model, $id, $subject) {
    my $hits = $client->model('mail.message')->search_read(
        [ [ 'model', '=', $model ], [ 'res_id', '=', $id ], [ 'message_type', 'in', [ 'email', 'email_outgoing' ] ], [ 'subject', '=', $subject ] ],
        ['id'], limit => 1 );
    return scalar @$hits;
}

sub _logical ($self, $row, $lf, $tags) {
    my $p = $self->profile;
    my %l = ( id => $row->{id} );
    for my $f (@$lf) {
        my $v    = $row->{ $p->field( lead => $f ) };
        my $type = $p->descriptor( lead => $f )->{type} // '';
        if    ( $type eq 'many2one' )  { $v = ref $v eq 'ARRAY' ? { id => $v->[0], name => $v->[1] } : undef }
        elsif ( $f eq 'tags' )         { $v = [ map { $tags->{$_} // "#$_" } @{ $v // [] } ] }
        elsif ( $type =~ /^(char|text|html|selection|date|datetime)\z/ && defined $v && $v eq '0' ) { $v = undef }
        $l{$f} = $v;
    }
    return \%l;
}

sub _tag_names ($self, $rows, $pf) {
    my %ids;
    $ids{$_} = 1 for map { @{ $_->{$pf} // [] } } @$rows;
    return {} if !%ids;
    my $name = $self->profile->field( tag => 'name' );
    return { map { $_->{id} => $_->{$name} } @{ $self->model('tag')->read( [ sort { $a <=> $b } keys %ids ], [$name] ) } };
}

sub _preview ($self, $index, $tpl) {
    my $path = File::Spec->catfile( $self->ctx->run_dir( $self->op_name ), 'preview.html' );
    open my $fh, '>:raw', $path or Odoo::Error->throw( kind => 'config', message => "cannot write $path: $!" );
    my $esc = sub ($s) { ( $s // '' ) =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr };
    print {$fh} encode_utf8( "<!doctype html><meta charset=utf-8><title>"
            . $esc->( $tpl->{campaign} ) . " preview</title>\n<body style=\"max-width:50em;margin:auto;font-family:sans-serif\">\n"
            . '<h1>' . $esc->( $tpl->{campaign} ) . ' - ' . scalar(@$index) . " messages</h1>\n" );
    for my $m (@$index) {
        open my $b, '<:raw', $m->{file} or next;
        my $body = do { local $/; <$b> };
        close $b;
        print {$fh} encode_utf8( "<hr><p><b>To:</b> " . $esc->( $m->{email} ) . " (lead $m->{lead_id})<br><b>Subject:</b> "
                . $esc->( $m->{subject} ) . "</p>\n" ), $body, "\n";
    }
    print {$fh} "</body>\n";
    close $fh;
    return $path;
}

1;
