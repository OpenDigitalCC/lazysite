package Odoo::Ops::CRM::Dossier;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
use Odoo::JSON ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Dossier - everything recorded about each selected lead, one file each

=head1 DESCRIPTION

C<crm.dossier>: for each selected lead writes C<< <out>/<id>.json >>
holding the lead under logical names (many2one as C<{id, name}>, tags
by name, notes as HTML and as plain text), its chatter - notes and
messages with date, author, subtype and plain-text body (tracking-only
entries, which need admin rights to read, are left out) - and the names of its
attachments. It is the input for research and for drafting follow-ups,
and it is read-only.

Without a selector it takes the open leads: active and not in a won
stage. C<exclude_stages> (names) drops further stages, e.g. C<Dead>.
The report holds counts only.

=cut

sub op_name ($class) { 'crm.dossier' }
sub summary ($class) { 'Write a per-lead dossier (fields, chatter, attachments) for research' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        exclude_stages => { type => 'list', help => 'stage names to leave out (e.g. Dead)' },
        out            => { type => 'path', help => 'directory (default: run dir dossier/)' },
    };
}
sub read_scope ($class) {
    {   lead                     => ['search_read'],
        tag                      => [qw(search_read read)],
        stage                    => ['search_read'],
        'mail.message'           => ['search_read'],
        'ir.attachment'          => ['search_read'],
    };
}

sub report ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'crm profile does not match: '
            . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};

    my $has_sel = grep { defined $self->param($_) } qw(tag domain run ids);
    my @domain  = $has_sel ? @{ Odoo::Ops::CRM::Select->domain_for($self) } : ();
    if ( !$has_sel ) {
        my $won = $self->model('stage')->search_read( [ [ $p->field( stage => 'won' ), '=', JSON::PP::true ] ], ['id'] );
        push @domain, [ $p->field( lead => 'stage' ), 'not in', [ map { $_->{id} } @$won ] ] if @$won;
    }
    if ( my $ex = $self->param('exclude_stages') ) {
        my $name_f = $p->field( stage => 'name' );
        my $st = $self->model('stage')->search_read( [ [ $name_f, 'in', $ex ] ], [$name_f] );
        push @domain, [ $p->field( lead => 'stage' ), 'not in', [ map { $_->{id} } @$st ] ] if @$st;
    }

    my $lf_all = $p->fields('lead');
    my @lf = grep { my $d = $p->descriptor( lead => $_ ); $d && ( $d->{type} // '' ) ne 'binary' } sort keys %$lf_all;
    my $leads = $self->model('lead')->all( \@domain, [ map { $lf_all->{$_} } @lf ] );
    my $model = $p->model_name('lead');
    my @ids   = map { $_->{id} } @$leads;

    my %tagname;
    if ( my @t = map { @{ $_->{ $lf_all->{tags} } // [] } } @$leads ) {
        my $nf = $p->field( tag => 'name' );
        %tagname = map { $_->{id} => $_->{$nf} } @{ $self->model('tag')->read( [ sort { $a <=> $b } keys %{ { map { $_ => 1 } @t } } ], [$nf] ) };
    }
    my %msgs;
    if (@ids) {
        # tracking_value_ids is Settings-only in Odoo 16 (field-level rule),
        # so field-change history is not read; tracking-only entries, which
        # have no body, are skipped.
        my $m = $self->model('mail.message')->search_read(
            [ [ 'model', '=', $model ], [ 'res_id', 'in', \@ids ] ],
            [qw(res_id date author_id message_type subtype_id body)], order => 'id asc' );
        for my $x (@$m) {
            my $text = _text( $x->{body} );
            next if !defined $text || $text eq '';
            push @{ $msgs{ $x->{res_id} } }, {
                date    => $x->{date},
                author  => ref $x->{author_id} ? $x->{author_id}[1] : undef,
                type    => $x->{message_type},
                subtype => ref $x->{subtype_id} ? $x->{subtype_id}[1] : undef,
                text    => $text,
            };
        }
    }
    my %att;
    if (@ids) {
        push @{ $att{ $_->{res_id} } }, $_->{name} for @{ $self->model('ir.attachment')->search_read(
            [ [ 'res_model', '=', $model ], [ 'res_id', 'in', \@ids ] ], [qw(res_id name)] ) };
    }

    my $dir = $self->param('out') // File::Spec->catdir( $self->ctx->run_dir( $self->op_name ), 'dossier' );
    make_path($dir);
    my $json = Odoo::JSON->new( pretty => 1 );
    my %by_stage;
    for my $row (@$leads) {
        my %l = ( id => $row->{id} );
        for my $f (@lf) {
            my $v    = $row->{ $lf_all->{$f} };
            my $type = $p->descriptor( lead => $f )->{type} // '';
            if    ( $type eq 'many2one' ) { $v = ref $v eq 'ARRAY' ? { id => $v->[0], name => $v->[1] } : undef }
            elsif ( $f eq 'tags' )        { $v = [ map { $tagname{$_} // "#$_" } @{ $v // [] } ] }
            $l{$f} = $v;
        }
        $l{notes_text} = _text( $l{notes} );
        $by_stage{ ref $l{stage} ? $l{stage}{name} : '(none)' }++;
        my $file = File::Spec->catfile( $dir, "$row->{id}.json" );
        open my $fh, '>:raw', $file or Odoo::Error->throw( kind => 'usage', message => "cannot write $file: $!", fix => 'give a path this user can write (dir, out or name), then plan again' );
        print {$fh} $json->encode( { lead => \%l, chatter => $msgs{ $row->{id} } // [], attachments => $att{ $row->{id} } // [] } );
        close $fh;
    }
    return { leads => scalar @$leads, by_stage => \%by_stage, dir => $dir };
}

sub _text ($html) {
    return undef if !defined $html || ref $html;
    my $t = $html =~ s{<br\s*/?>}{\n}gir =~ s{</p>}{\n}gir =~ s/<[^>]*>//gr;
    $t =~ s/&nbsp;/ /g;
    $t =~ s/&amp;/&/g;
    $t =~ s/&lt;/</g;
    $t =~ s/&gt;/>/g;
    $t =~ s/&quot;/"/g;
    $t =~ s/&#39;/'/g;
    $t =~ s/[ \t]+/ /g;
    $t =~ s/\n\s*\n+/\n/g;
    return $t =~ s/^\s+|\s+\z//gr;
}

1;
