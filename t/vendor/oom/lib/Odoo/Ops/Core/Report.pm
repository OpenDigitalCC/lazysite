package Odoo::Ops::Core::Report;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC);
use File::Path qw(make_path);
use File::Spec;
use MIME::Base64 qw(decode_base64);
use Time::HiRes ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Core::Fetch;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Report - bring a rendered report, or its stored copy, to a local file

=head1 SYNOPSIS

    oom-ops run core.reports --conf C --set model=sale.order
    oom-ops run core.report  --conf C --set report=sale.report_saleorder \
        --set model=sale.order --set record=name=S00042 --set dir=out/

=head1 DESCRIPTION

C<core.report> fetches one document per record to a file under C<dir>
(made 0700), mode 0600, never overwriting unless C<overwrite>, content
never printed: the files rules of L<Odoo::Ops::Core::Fetch>.

C<report> is a C<report_name> (C<sale.report_saleorder>) or the xml id of
the C<ir.actions.report> (C<sale.action_report_saleorder>);
C<core.reports> lists them. The records are C<record> (an id, or
C<field=value>, with C<model>) or C<ids>; exactly one of the two. C<format>
is C<pdf> (default), C<html> or C<text>.

C<source> says where the bytes come from. C<render>: a GET of
C</report/E<lt>formatE<gt>/E<lt>report_nameE<gt>/E<lt>idE<gt>> over the web
session, one request per record (Odoo renders in the answer; the private
render method cannot be called over RPC), so the connection needs a web
session: a config whose credential is C<password>. C<attachment>: the
newest stored C<ir.attachment> of the record, with no render, for a report
with an C<attachment> expression; its checksum is compared with Odoo's.
Where the report has no such expression, or the record holds no attachment
of the format asked, the refusal C<no-stored-copy> says which. C<auto>: the
stored copy when the report has an attachment expression and the record
holds one, else render.

The answer is accepted only when it is the format asked for (status 200,
C<application/pdf> and C<%PDF-> for a pdf). A login redirect or an HTML page
where a pdf was expected is a lost session: the session is opened once more
(a C<password> credential can) and the request retried once, then the
operation is refused C<transport/session-lost>. An RPC transport holds no
web session: C<render> is refused C<refused/needs-session>. An HTTP error
whose page carries Odoo's own message is a C<fault> with that message as
Odoo worded it; no answer, a TLS failure or an error page without Odoo's
message is C<transport>.

A read operation; the report carries the report, its ids and one row per
document with the path, size and SHA-1 of what was written. Nothing of the
content is printed or journalled.

=cut

sub op_name ($class) { 'core.report' }
sub summary ($class) { 'Fetch a rendered report, or its stored copy, to a local file (mode 0600)' }
sub pack    ($class) { undef }
sub params ($class) {
    {   report    => { type => 'str',  required => 1, help => 'a report_name (sale.report_saleorder) or the xml id of the report action; core.reports lists them' },
        model     => { type => 'str',  help => 'physical model of the records (with record; the report\'s own model otherwise)' },
        record    => { type => 'str',  help => 'one record: an id, or field=value such as name=S00042' },
        ids       => { type => 'list', help => 'comma-separated record ids (instead of record)' },
        format    => { type => 'str',  default => 'pdf', help => 'pdf (default), html or text' },
        dir       => { type => 'path', required => 1, help => 'directory the files are written to' },
        name      => { type => 'str',  help => 'file name for one document (default: Odoo\'s print name when plain, else report_name-id.format)' },
        overwrite => { type => 'bool', default => 0, help => 'replace a file already in dir' },
        source    => { type => 'str',  default => 'render', help => 'render (default; needs a web session), attachment (the stored copy, no render) or auto' },
        timeout   => { type => 'int',  help => 'seconds the render request may take (default: the connection\'s)' },
    };
}

sub read_scope ($class) {
    {   'ir.actions.report' => ['search_read'],
        'ir.model.data'     => ['search_read'],
        'ir.attachment'     => [ 'search_read', 'read' ],
    };
}

sub fields ($class) {
    return [
        { name => 'report',      meaning => 'The report as asked (report_name or xml id)' },
        { name => 'report_name', meaning => 'The report_name the route carried' },
        { name => 'model',       meaning => 'The record\'s model' },
        { name => 'id',          meaning => 'The record\'s id' },
        { name => 'display_name', meaning => 'The record\'s display name' },
        { name => 'format',      meaning => 'pdf, html or text' },
        { name => 'source',      meaning => 'render, or attachment N (the stored copy that was read)' },
        { name => 'path',        meaning => 'The file written' },
        { name => 'size',        meaning => 'Bytes written' },
        { name => 'sha1',        meaning => 'SHA-1 of what was written' },
        { name => 'checksum_ok', meaning => 'Stored copy only: Odoo\'s checksum equals the SHA-1 of what was written' },
        { name => 'stored',      meaning => 'The stored copy\'s attachment id. On an attachment row it is the copy that was read (the id in source); on a render row, of a report that stores a copy: the attachment id Odoo created or reloaded on the record. Odoo keeps the first stored copy and does not refresh it after posting, so a copy stored while the record was a draft stays the draft\'s (MAPPER-SPEC section 9); a draft record\'s result says so in notes' },
        { name => 'stored_name', meaning => 'The name of the stored copy (stored is its id), the name a person finds it by in Odoo: on an attachment row the file that was read, on a render row the file Odoo stored' },
        { name => 'stored_at',   meaning => 'The stored copy\'s create_date (UTC). A record that is no longer a draft can still hold a copy stored while it was: compare this with the record\'s write_date' },
        { name => 'pages',       meaning => 'Pdf: pages counted from the /Type /Page objects; approximate (a pdf that packs them in object streams counts fewer)' },
        { name => 'note',        meaning => 'Attachment row, when the report names its stored file with an expression OOM does not evaluate: OOM took the newest PDF attached to the record, and stored_name is the file it took' },
    ];
}

my %MIME = ( pdf => 'application/pdf', html => 'text/html', text => 'text/plain' );

sub report ($self) {
    my %p = %{ $self->all_params };
    my $fmt = $p{format};
    Odoo::Error->throw( kind => 'usage', message => "core.report: format must be pdf, html or text, not '$fmt'" ) if $fmt !~ /^(?:pdf|html|text)\z/;
    Odoo::Error->throw( kind => 'usage', message => "core.report: source must be render, attachment or auto, not '$p{source}'" ) if $p{source} !~ /^(?:render|attachment|auto)\z/;
    my $have_record = defined $p{record};
    my $have_ids    = defined $p{ids} && @{ $p{ids} };
    Odoo::Error->throw( kind => 'usage', message => 'core.report: give exactly one of record and ids' ) if $have_record == $have_ids || ( $have_record && $have_ids );
    my @bad = grep { !/^\d+\z/ } @{ $p{ids} // [] };
    Odoo::Error->throw( kind => 'usage', message => "core.report: ids must be whole numbers, got '$bad[0]'" ) if @bad;
    Odoo::Error->throw( kind => 'usage', message => 'core.report: model is needed with record' ) if $have_record && !defined $p{model};

    my $rep   = $self->_resolve_report( $p{report}, $p{model} );
    my $model = $rep->{model};
    Odoo::Error->throw( kind => 'usage', message => "core.report: report $rep->{report_name} prints $model, not $p{model}" )
        if defined $p{model} && $p{model} ne $model;
    Odoo::Error->throw( kind => 'usage', message => "core.report: report $rep->{report_name} is $rep->{report_type}; format $fmt does not apply to it (core.reports shows each report's type)" )
        if ( $fmt eq 'pdf' && $rep->{report_type} ne 'qweb-pdf' ) || ( $fmt eq 'html' && $rep->{report_type} !~ /^qweb-(?:pdf|html)\z/ ) || ( $fmt eq 'text' && $rep->{report_type} ne 'qweb-text' );

    my $dir = $p{dir};
    my @ids = $self->_with_model_scope( $model, sub { $have_record ? ( $self->_record_id( $model, $p{record} ) ) : map { 0 + $_ } @{ $p{ids} } } );
    Odoo::Error->throw( kind => 'usage', message => 'core.report: name names one file; with several ids the names are derived' ) if defined $p{name} && @ids > 1;

    # the state is read only where the model has one: a draft's stored copy is the draft's
    my $has_state = $self->_with_model_scope( $model, sub { $self->model($model)->fields->{state} ? 1 : 0 } );
    my ( %display, %state );
    $self->_with_model_scope( $model, sub {
        my $rows = $self->model($model)->read( \@ids, [ 'display_name', ( $has_state ? ('state') : () ) ] );
        %display = map { $_->{id} => $_->{display_name} } @$rows;
        %state   = map { $_->{id} => $_->{state} } @$rows if $has_state;
    } );
    for my $id (@ids) {
        Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "core.report: no $model with id $id",
            fix => 'give the id of a record that exists on the instance' ) if !exists $display{$id};
    }

    make_path( $dir, { mode => 0700 } ) if !-d $dir;
    Odoo::Error->throw( kind => 'usage', message => "cannot use dir $dir", fix => 'give a path this user can write (dir, out or name), then plan again' ) if !-d $dir || !-w _;

    # Odoo finds a stored copy by the name its attachment expression gives, so
    # that is the name to look for when the expression is a plain string
    my $plain = _plain_name( $rep->{attachment} );
    my $stores = length $rep->{attachment} ? 1 : 0;
    my ( @rows, %used, @notes );
    for my $id (@ids) {
        my $want = defined $p{name} ? $p{name}
            : defined _plain_name( $rep->{print_report_name} ) ? _plain_name( $rep->{print_report_name} ) . ( @ids > 1 ? "-$id" : '' ) . ".$fmt"
            : "$rep->{report_name}-$id.$fmt";
        my $safe = Odoo::Ops::Core::Fetch::_safe_name( $want, $id );
        $safe = "$id-$safe" if $used{ lc $safe }++;
        my $path = File::Spec->catfile( $dir, $safe );
        # the target file is looked at last: a report that stores no copy, a record with none and a connection
        # with no session are answered first, so they show whether or not the file is already there
        my $check_exists = sub {
            Odoo::Error->throw( kind => 'refused', code => 'exists', message => "cannot write $path: it exists; overwrite=1 replaces it", fix => 'pass --set overwrite=1' )
                if -e $path && !$p{overwrite};
        };

        my ( $bytes, %extra );
        my $source = $p{source};
        if ( $source eq 'attachment' && !$stores ) {
            Odoo::Error->throw( kind => 'refused', code => 'no-stored-copy',
                message => "core.report: report $rep->{report_name} has no attachment expression, so source=attachment has nothing to read",
                fix => 'use source=render (it needs a web session: a config whose credential is password)' );
        }
        if ( $source eq 'attachment' || ( $source eq 'auto' && $stores ) ) {
            my $att = $self->_stored_copy( $model, $id, $fmt, $plain );
            if ($att) {
                $check_exists->();
                ( $bytes, %extra ) = ( decode_base64( $att->{datas} ), source => "attachment $att->{id}", _att => $att, stored => $att->{id},
                    ( _text( $att->{name} ) ne ''        ? ( stored_name => $att->{name} )        : () ),
                    ( _text( $att->{create_date} ) ne '' ? ( stored_at   => $att->{create_date} ) : () ) );
                $extra{note} = 'the report names its stored file with an expression OOM does not evaluate, so OOM took the newest '
                    . uc($fmt) . ' attached to the record; stored_name is the file it took'
                    if !defined $plain;
            }
            elsif ( $source eq 'attachment' ) {
                Odoo::Error->throw( kind => 'refused', code => 'no-stored-copy',
                    message => "core.report: no attachment on $model $id for report $rep->{report_name}",
                    fix => 'use source=render (it needs a web session: a config whose credential is password)' );
            }
        }
        if ( !defined $bytes ) {
            $self->_need_session( $rep, $id );
            $check_exists->();
            my $before = $stores && $fmt eq 'pdf' ? $self->_max_attachment( $model, $id ) : undef;
            $bytes = $self->_render( $rep, $fmt, $id, $p{timeout} );
            %extra = ( source => 'render' );
            if ( defined $before ) {
                my $att = $self->_stored_copy( $model, $id, $fmt, $plain, 1 );
                if ( $att && ( $att->{id} > $before || $rep->{attachment_use} ) ) {
                    $extra{stored} = $att->{id};
                    $extra{stored_at} = $att->{create_date} if _text( $att->{create_date} ) ne '';
                    $extra{stored_name} = $att->{name} if _text( $att->{name} ) ne '';
                }
            }
        }

        my $flags = O_WRONLY | O_CREAT | ( $p{overwrite} ? O_TRUNC : O_EXCL );
        sysopen( my $fh, $path, $flags, 0600 )
            or Odoo::Error->throw( -e $path
                ? ( kind => 'refused', code => 'exists', message => "cannot write $path: it exists; overwrite=1 replaces it", fix => 'pass --set overwrite=1' )
                : ( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path this user can write (dir, out or name), then plan again' ) );
        binmode $fh;
        print {$fh} $bytes;
        close $fh or Odoo::Error->throw( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path this user can write (dir, out or name), then plan again' );
        chmod 0600, $path;
        my $sum = Digest::SHA::sha1_hex($bytes);
        my $att = delete $extra{_att};
        push @notes, "the stored copy is this draft's; Odoo keeps the first stored copy and does not refresh it after posting (MAPPER-SPEC section 9)"
            if $stores && ( $extra{stored} || $att ) && ( $state{$id} // '' ) eq 'draft' && !grep { /this draft's/ } @notes;
        push @rows, {
            report => $p{report}, report_name => $rep->{report_name}, model => $model, id => $id,
            display_name => $display{$id}, format => $fmt, path => $path, size => length($bytes), sha1 => $sum,
            ( $att ? ( checksum_ok => ( ( $att->{checksum} // '' ) eq $sum ? 1 : 0 ) ) : () ),
            ( $fmt eq 'pdf' ? ( pages => _pages($bytes) ) : () ),
            %extra,
        };
    }
    my $text = sub ($s) { { portable_type => 'text', string => $s } };
    return {
        report => $p{report}, report_name => $rep->{report_name}, model => $model, ids => \@ids,
        format => $fmt, source => $p{source},
        rows => \@rows, count => scalar(@rows), dir => $dir,
        ( @notes ? ( notes => \@notes ) : () ),
        fields => { map { $_->{name} => $text->( $_->{meaning} ) } @{ $self->fields } },
    };
}

# --- the report -------------------------------------------------------------

my @REPORT_FIELDS = qw(name report_name report_type model attachment attachment_use print_report_name);

sub _resolve_report ($self, $ref, $model) {
    my $m = $self->model('ir.actions.report');
    my $found = $m->search_read( [ [ 'report_name', '=', $ref ] ], [@REPORT_FIELDS] );
    # one report_name can serve several models: the model chooses among them
    my @for_model = defined $model ? grep { _text( $_->{model} ) eq $model } @$found : ();
    $found = \@for_model if @for_model;
    if ( !@$found && $ref =~ /^([^.\s]+)\.([^.\s]+)\z/ ) {
        my $d = $self->model('ir.model.data')->search_read(
            [ [ 'module', '=', $1 ], [ 'name', '=', $2 ], [ 'model', '=', 'ir.actions.report' ] ], ['res_id'] );
        $found = $m->search_read( [ [ 'id', 'in', [ map { $_->{res_id} } @$d ] ] ], [@REPORT_FIELDS] ) if @$d;
    }
    Odoo::Error->throw( kind => 'refused', code => 'unknown-report', message => "core.report: no report '$ref'",
        fix => 'oom-ops run core.reports --conf <conf> --set model=<model> lists the reports and their report_name' ) if !@$found;
    Odoo::Error->throw( kind => 'usage', message => "core.report: '$ref' is the report_name of " . scalar(@$found) . ' reports (' . join( ', ', map { "$_->{model} id $_->{id}" } @$found ) . '); pass model to choose' ) if @$found > 1;
    my %r = %{ $found->[0] };
    for my $k (qw(name report_name report_type model attachment print_report_name)) { $r{$k} = _text( $r{$k} ) }
    return \%r;
}

# the record's model is known only once the report is: its reads run under a
# scope widened by that model, inside the operation's own
sub _with_model_scope ($self, $model, $code) {
    my $scope = $self->scope_for('read');
    $scope->{$model} = [ sort keys %{ { map { $_ => 1 } @{ $scope->{$model} // [] }, qw(read search_read) } } ];
    return $self->ctx->guard->with_scope( $scope, $self->op_name, $code );
}

sub _record_id ($self, $model, $rec) {
    my $m = $self->model($model);
    my $dom;
    if ( $rec =~ /^\d+\z/ ) { $dom = [ [ 'id', '=', 0 + $rec ] ] }
    elsif ( my ( $f, $val ) = $rec =~ /^(\w+)=(.*)\z/s ) {
        Odoo::Error->throw( kind => 'usage', message => "core.report: $model has no field '$f'" ) if !$m->fields->{$f};
        $dom = [ [ $f, '=', $val ] ];
    }
    else { Odoo::Error->throw( kind => 'usage', message => "core.report: record '$rec' is neither an id nor field=value" ) }
    my $found = $m->search_read( $dom, ['id'] );
    Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "core.report: no $model matches $rec",
        fix => 'give the id of a record that exists on the instance' ) if !@$found;
    Odoo::Error->throw( kind => 'usage', message => "core.report: $rec matches $model records " . join( ', ', map { $_->{id} } @$found ) ) if @$found > 1;
    return $found->[0]{id};
}

# an expression that is a quoted literal and nothing else: the name Odoo
# would give, known without evaluating Python
sub _plain_name ($expr) {
    return undef if !defined $expr || $expr eq '';
    return $2 if $expr =~ /^\s*(['"])([^'"%\$\{\}()]+)\1\s*\z/;
    return undef;
}

sub _text ($v) { return ( !defined $v || ref $v || $v eq '' || $v eq '0' ) ? '' : "$v" }

# --- the stored copy ----------------------------------------------------------

sub _max_attachment ($self, $model, $id) {
    my $rows = $self->model('ir.attachment')->search_read( [ [ 'res_model', '=', $model ], [ 'res_id', '=', $id ] ], ['id'] );
    my $max = 0;
    for my $r (@$rows) { $max = $r->{id} if $r->{id} > $max }
    return $max;
}

# the newest attachment of the record that is the format asked for (named as
# the report's attachment expression names it when that is a plain string);
# $nodata skips the content
sub _stored_copy ($self, $model, $id, $fmt, $plain, $nodata = 0) {
    my @dom = ( [ 'res_model', '=', $model ], [ 'res_id', '=', $id ], [ 'mimetype', '=', $MIME{$fmt} ] );
    push @dom, [ 'name', '=', $plain ] if defined $plain;
    my $rows = $self->model('ir.attachment')->search_read( \@dom, ['id'] );
    my ($newest) = sort { $b->{id} <=> $a->{id} } @$rows;
    return undef if !$newest;
    return $self->model('ir.attachment')->read_one( $newest->{id}, [qw(name type checksum datas mimetype create_date)] )
        if !$nodata;
    my $when = $self->model('ir.attachment')->read_one( $newest->{id}, [ 'create_date', 'name' ] );
    return { id => $newest->{id}, create_date => $when ? $when->{create_date} : undef, name => $when ? $when->{name} : undef };
}

# --- the render -------------------------------------------------------------

# a render needs a web session; asked before the target file is looked at
sub _need_session ($self, $rep, $id) {
    my $st = $self->ctx->session_transport;
    Odoo::Error->throw( kind => 'refused', code => 'needs-session',
        message => "core.report: rendering $rep->{report_name} for record $id needs a web session, and this connection has none",
        fix => 'use a config whose credential is password (login and password_file), or source=attachment when the report stores a copy' )
        if !$st || !$st->can('get') || !$st->session_id;
    return $st;
}

sub _render ($self, $rep, $fmt, $id, $timeout) {
    my $ctx = $self->ctx;
    my $st  = $self->_need_session( $rep, $id );

    my $path = '/report/' . $fmt . '/' . ( $rep->{report_name} =~ s/([^A-Za-z0-9._-])/sprintf( '%%%02X', ord $1 )/ger ) . "/$id";
    my $what = "report $rep->{report_name} for $rep->{model} $id";
    my $res;
    for my $try ( 1, 2 ) {
        my $t0 = Time::HiRes::time();
        $res = eval { $st->get( $path, ( defined $timeout ? ( timeout => $timeout ) : () ) ) };
        my $err = $@;
        my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );
        if ($err) {
            $ctx->guard->audit_web( 'report.render', 'transport', $ms );
            die $err;
        }
        my ( $verdict, $why ) = _judge( $res, $fmt );
        if ( $verdict eq 'ok' ) {
            $ctx->guard->audit_web( 'report.render', 'answered', $ms );
            return $res->{content};
        }
        if ( $verdict eq 'lost' ) {
            $ctx->guard->audit_web( 'report.render', 'fault', $ms );
            if ( $try == 1 && $ctx->can_reopen_session ) {
                $ctx->open_session;
                next;
            }
            Odoo::Error->throw( kind => 'transport', code => 'session-lost',
                message => "core.report: the web session was lost fetching $what ($why)" . ( $try == 2 ? ' and opening it again did not help' : ' and this connection cannot open it again' ),
                fix => 'where Odoo runs several workers or hosts, give the server a sticky session cookie or a shared session directory, so a session one host opened is known to the next' );
        }
        if ( $verdict eq 'odoo' ) {
            # Odoo answered with its own error: that is its refusal, not a broken connection
            $ctx->guard->audit_web( 'report.render', 'fault', $ms );
            Odoo::Error->throw( kind => 'fault', message => "core.report: $what: $why" );
        }
        $ctx->guard->audit_web( 'report.render', 'transport', $ms );
        my $m = "core.report: $what: $why";
        $m .= '; the render runs inside one worker under the server\'s time limit, so a slow report may need a longer timeout than the server allows' if $verdict eq 'timeout';
        Odoo::Error->throw( kind => 'transport', message => $m );
    }
    return undef;    # not reached: the second try either returns or throws
}

# ok | lost | timeout | odoo | failed, with the reason in a few words
sub _judge ($res, $fmt) {
    my $status = $res->{status} // 0;
    my $ct = lc( $res->{headers}{'content-type'} // '' );
    $ct = $ct->[-1] if ref $ct eq 'ARRAY';
    my $body = $res->{content} // '';
    return ( 'timeout', 'no answer in time: ' . ( $body =~ /^(.{0,80})/s )[0] ) if $status == 599 && $body =~ /timed out/i;
    return ( 'failed', 'no answer: ' . ( $body =~ /^(.{0,80})/s )[0] ) if $status == 599;
    return ( 'lost', "a redirect to " . ( $res->{headers}{location} // 'another page' ) =~ s{^\w+://[^/]+}{}r ) if $status =~ /^3\d\d\z/;
    return ( 'lost', "HTTP $status" ) if $status == 401;
    if ( $status != 200 ) {
        my $why = _odoo_message($body);
        return ( 'odoo', "HTTP $status $res->{reason}: $why" ) if length $why;
        return ( 'failed', "HTTP $status $res->{reason}" );
    }
    if ( $fmt eq 'pdf' ) {
        return ( 'ok', '' ) if $ct =~ m{^application/pdf} && $body =~ /\A%PDF-/;
        return ( 'lost', 'an HTML page instead of a pdf' ) if $ct =~ m{^text/html};
        return ( 'failed', "the answer is '" . ( $ct || 'untyped' ) . "', not a pdf" );
    }
    if ( $fmt eq 'html' ) {
        return ( 'lost', 'the login page instead of the report' ) if $body =~ m{<form[^>]+action="/web/login}i || $body =~ /oe_login_form/;
        return ( 'ok', '' ) if $ct =~ m{^text/html};
        return ( 'failed', "the answer is '" . ( $ct || 'untyped' ) . "', not html" );
    }
    return ( 'lost', 'an HTML page instead of text' ) if $ct =~ m{^text/html};
    return ( 'ok', '' ) if $ct =~ m{^text/};
    return ( 'failed', "the answer is '" . ( $ct || 'untyped' ) . "', not text" );
}

# Odoo's error page carries the message of the exception ("Error message:" then
# a pre): the reason a person acts on, as Odoo worded it, on one line
sub _odoo_message ($body) {
    my ($m) = $body =~ m{<strong>Error message:</strong>\s*<pre>(.*?)</pre>}s or return '';
    my %ent = ( amp => '&', lt => '<', gt => '>', quot => '"', '#39' => "'" );
    $m =~ s/&(amp|lt|gt|quot|#39);/$ent{$1}/g;
    $m =~ s/\s+/ /g;
    $m =~ s/^ | \z//g;
    return $m;
}

# page objects, counted in the bytes: approximate
sub _pages ($bytes) {
    my $n = () = $bytes =~ m{/Type\s*/Page(?![A-Za-z])}g;
    return $n;
}

1;
