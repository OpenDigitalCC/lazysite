package Odoo::Ops::Discuss::Post;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(basename);
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Digest::SHA ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Core::Attach;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::Post - post a message to a channel, or reply to one

=head1 SYNOPSIS

    oom-ops run discuss.post --conf ops.conf --set channel=7 --set body="Stock count is done"
    oom-ops run discuss.post --conf ops.conf --set channel=7 --set body="Thanks" --set reply_to=120
    oom-ops run discuss.post --conf ops.conf --set channel=7 --set body="See the sheet" \
        --set mentions=ann@example.com,42 --set attachments=/data/count.pdf

=head1 DESCRIPTION

C<discuss.post>: one message from the login the config runs as, posted to the
channel C<channel> through Odoo's own C<message_post> (as a C<comment> with
the C<mail.mt_comment> subtype, which is what its client sends). The plan names
the channel, the message replied to and the text. Apply reads the new message
back (channel, parent, attachments, recipients) and names it, as
C<made: mail.message N (channel name, comment)>.

C<body> is plain text, put in a paragraph with its line breaks kept and any
markup escaped; C<html> is on when it is already HTML. C<reply_to> is a message
id in the same channel: Odoo drops a parent from another channel without a word
and posts the message unthreaded, so such a reply is held
(C<reply-elsewhere>). C<mentions> lists partner ids and logins; each becomes a
recipient of the message (Odoo notifies a user by the way their settings say,
which for most is an email). C<attachments> lists files, put on the channel as
C<core.attach> puts a file on a record: the plan holds each file's path, size
and SHA-1 and never its bytes, apply refuses (C<changed-since-plan>) a file that
changed, and C<max_bytes> (default 25 MB) holds a larger one (C<too-large>).

A plan is one post and lands in one bucket:

    post             the message is planned
    unknown-channel  this login can read no channel with that id - held
    unknown-message  the reply target is not a message this login can read - held
    reply-elsewhere  the reply target is on another channel - held
    unknown-mention  a mention names no partner or login - held
    file-missing     a file cannot be read - held
    too-large        a file is over max_bytes - held

A channel the login is not a member of can be posted to when Odoo lets it (a
public channel does); the plan does not predict that, and Odoo's answer comes
back on apply.

Revert: the post is undone by C<discuss.delete> of the message it made. Odoo
keeps the message record, emptied, with its attachments removed; the revert plan
says so. Series: written for Odoo 16; another series is refused by name.

=cut

sub op_name ($class) { 'discuss.post' }
sub summary ($class) { 'Post a message to a Discuss channel, or reply to one' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [ { name => 'post', meaning => 'one message is posted to the channel through Odoo\'s message_post' } ];
}
sub holds ($class) {
    return [
        { name => 'unknown-channel', meaning => 'this login can read no channel with that id' },
        { name => 'unknown-message', meaning => 'the reply target is not a message this login can read' },
        { name => 'reply-elsewhere', meaning => 'the reply target is a message of another channel; Odoo would post without a parent' },
        { name => 'unknown-mention', meaning => 'a mention names no partner id and no login' },
        { name => 'file-missing', meaning => 'an attachment cannot be read' },
        { name => 'too-large', meaning => 'an attachment is over max_bytes' },
    ];
}

sub params ($class) {
    {   channel     => { type => 'int',  required => 1, help => 'the channel id (discuss.channels prints it)' },
        body        => { type => 'str',  help => 'the text; plain unless html is on' },
        html        => { type => 'bool', default => 0, help => 'body is already HTML' },
        reply_to    => { type => 'int',  help => 'a message id in the same channel' },
        mentions    => { type => 'list', help => 'partner ids and logins, comma separated' },
        attachments => { type => 'list', help => 'file paths, comma separated' },
        max_bytes   => { type => 'int',  default => 25 * 1024 * 1024, help => 'hold a file over this size (default 25 MB)' },
    };
}
sub read_scope ($class) {
    {   channel => ['search_read'], member => ['search_read'], message => ['search_read'],
        user => ['search_read'], partner => ['search_read'],
    };
}
sub write_scope ($class) {
    { channel => ['message_post'], attachment => [ 'create', 'unlink' ] };
}

# the message and the attachments are read back at apply
sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    if ( $phase eq 'apply' ) {
        my $mm = $self->physical_model('message');
        $s->{$mm} = [ sort keys %{ { map { $_ => 1 } @{ $s->{$mm} // [] }, 'read' } } ];
    }
    return $s;
}

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $plan = $self->new_plan( input_count => 1 );
    my $cid  = $self->param('channel');
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => "channel:$cid", reason => $why ); return $plan };

    my @files_in = @{ $self->param('attachments') // [] };
    my $raw = $self->param('body');
    Odoo::Error->throw( kind => 'usage', message => 'discuss.post: give a body or an attachment', fix => 'pass --set body=... or --set attachments=PATH' )
        if ( !defined $raw || $raw !~ /\S/ ) && !@files_in;
    my $html = !defined $raw || $raw !~ /\S/ ? '' : $self->param('html') ? $raw : Odoo::Ops::Discuss::Common::text_html($raw);

    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $cid )
        or return $hold->( 'unknown-channel', "this login can read no channel $cid" );

    my $reply = $self->param('reply_to');
    my $target;
    if ( defined $reply ) {
        $target = Odoo::Ops::Discuss::Common::message_row( $self, $reply )
            or return $hold->( 'unknown-message', "message $reply is not readable by this login" );
        return $hold->( 'reply-elsewhere',
            "message $reply is " . ( defined $target->{channel} ? "on channel $target->{channel}" : 'not on a channel' )
            . ", not on channel $cid; Odoo would post without a parent" )
            if !defined $target->{channel} || $target->{channel} != $cid;
    }

    my ( @partners, @mention_names );
    if ( my @m = @{ $self->param('mentions') // [] } ) {
        my ( @ids, @logins );
        for my $m (@m) { $m =~ /\A\d+\z/ ? push @ids, 0 + $m : push @logins, $m }
        my %pname = !@ids ? () : map { $_->{id} => $_->{ $f->( partner => 'name' ) } }
            @{ $self->model('partner')->search_read( [ [ 'id', 'in', \@ids ] ], [ $f->( partner => 'name' ) ] ) };
        my %user = !@logins ? () : map { $_->{ $f->( user => 'login' ) } => $_ }
            @{ $self->model('user')->search_read( [ [ $f->( user => 'login' ), 'in', \@logins ] ], [ map { $f->( user => $_ ) } qw(login partner) ] ) };
        my %seen;
        for my $m (@m) {
            my ( $pid, $shown );
            if ( $m =~ /\A\d+\z/ ) {
                return $hold->( 'unknown-mention', "no partner $m" ) if !exists $pname{ 0 + $m };
                ( $pid, $shown ) = ( 0 + $m, $pname{ 0 + $m } );
            }
            else {
                return $hold->( 'unknown-mention', "no user with login $m" ) if !$user{$m};
                ( $pid, $shown ) = ( Odoo::Ops::Discuss::Common::id_of( $user{$m}{ $f->( user => 'partner' ) } ), $m );
            }
            next if $seen{$pid}++;
            push @partners, $pid;
            push @mention_names, $shown;
        }
    }

    my @files;
    my $max = $self->param('max_bytes');
    for my $path (@files_in) {
        return $hold->( 'file-missing', "cannot read file $path" ) if !-f $path || !-r _;
        my $size = -s _;
        return $hold->( 'too-large', "file $path is $size bytes; the limit is $max (max_bytes)" ) if $size > $max;
        my $name = basename($path);
        my ($ext) = lc($name) =~ /\.(\w+)\z/;
        push @files, {
            file => $path, name => $name, size => $size + 0, checksum => Odoo::Ops::Discuss::Common::sha1_file($path),
            ( $ext && $Odoo::Ops::Core::Attach::MIME{$ext} ? ( mimetype => $Odoo::Ops::Core::Attach::MIME{$ext} ) : () ),
        };
    }

    my $text = Odoo::Ops::Discuss::Common::html_text($html);
    (my $flat = $text) =~ s{\s*\n\s*}{ }g;
    my $shown = length $flat > 200 ? substr( $flat, 0, 200 ) . '... (' . length($flat) . ' characters)' : $flat;
    my $line = 'post to ' . $p->model_name('channel') . " $cid ($ch->{name}): "
        . ( length $shown ? "\"$shown\"" : '(no text)' )
        . ( defined $reply ? "; reply to message $reply" . ( length $target->{author_name} ? " by $target->{author_name}" : '' ) : '' )
        . ( @mention_names ? '; mentions ' . join( ', ', @mention_names ) : '' )
        . ( @files ? '; ' . scalar(@files) . ' file' . ( @files == 1 ? '' : 's' ) . ' (' . join( ', ', map { $_->{name} } @files ) . ')' : '' );
    $plan->add(
        bucket => 'post', action => 'custom', handler => $self->op_name, kind => 'post',
        model  => $p->model_name('channel'), id => $cid + 0, key => "channel:$cid",
        vals   => {
            channel => $cid + 0, channel_name => $ch->{name}, body => $html,
            ( defined $reply ? ( reply_to => $reply + 0 ) : () ),
            ( @partners ? ( mentions => \@partners ) : () ),
            ( @files ? ( files => \@files ) : () ),
        },
        line   => $line,
        reason => 'a message cannot be unsent; the revert (discuss.delete) empties it and removes its attachments, and Odoo keeps the record',
    );
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner. Puts each file on the channel (the checksum compared with
the plan's), posts through C<message_post> with the attachments, reads the
message back and returns it. A post that fails removes the attachments it made.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "discuss.post cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'post';
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.post' );
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $v = $c->{vals};
    my $cid = $v->{channel};
    my $att = $client->model( $p->model_name('attachment') );
    my @made;
    my $mid = eval {
        for my $file ( @{ $v->{files} // [] } ) {
            open my $fh, '<:raw', $file->{file}
                or Odoo::Error->throw( kind => 'refused', code => 'changed-since-plan', message => "file $file->{file} cannot be read now: $!" );
            my $bytes = do { local $/; <$fh> };
            close $fh;
            Odoo::Error->throw( kind => 'refused', code => 'changed-since-plan',
                message => "file $file->{file} no longer has the checksum it had when planned; re-plan" )
                if Digest::SHA::sha1_hex($bytes) ne $file->{checksum};
            push @made, $att->create( {
                $f->( attachment => 'name' ) => $file->{name},
                $f->( attachment => 'res_model' ) => $p->model_name('channel'),
                $f->( attachment => 'res_id' ) => $cid,
                $f->( attachment => 'datas' ) => encode_base64( $bytes, '' ),
                ( $file->{mimetype} ? ( $f->( attachment => 'mimetype' ) => $file->{mimetype} ) : () ),
            } );
        }
        $client->execute_kw( $p->model_name('channel'), $p->action('post'), [ [$cid] ], {
            body => $v->{body}, message_type => 'comment', subtype_xmlid => $p->action('comment_subtype'),
            ( defined $v->{reply_to} ? ( parent_id => $v->{reply_to} ) : () ),
            ( $v->{mentions} ? ( partner_ids => $v->{mentions} ) : () ),
            ( @made ? ( attachment_ids => \@made ) : () ),
        } );
    };
    if ( my $e = $@ ) {
        eval { $att->unlink( \@made ) } if @made;
        die $e;
    }
    my $msg = $client->model( $p->model_name('message') )->read_one( $mid,
        [ map { $f->( message => $_ ) } qw(model res_id parent attachments mentions type body) ] );
    Odoo::Error->throw( kind => 'fault', message => "no message $mid on channel $cid after posting" ) if !$msg;
    my %after = (
        id          => $mid,
        channel     => $msg->{ $f->( message => 'res_id' ) },
        parent      => Odoo::Ops::Discuss::Common::id_of( $msg->{ $f->( message => 'parent' ) } ),
        attachments => [ sort { $a <=> $b } @{ $msg->{ $f->( message => 'attachments' ) } // [] } ],
        mentions    => [ sort { $a <=> $b } @{ $msg->{ $f->( message => 'mentions' ) } // [] } ],
        type        => $msg->{ $f->( message => 'type' ) },
    );
    my $ok = ( $after{channel} // 0 ) == $cid
        && ( $msg->{ $f->( message => 'model' ) } // '' ) eq $p->model_name('channel')
        && ( ( $after{parent} // 0 ) == ( $v->{reply_to} // 0 ) )
        && join( ',', @{ $after{attachments} } ) eq join( ',', sort { $a <=> $b } @made )
        && !grep( { my $m = $_; !grep { $_ == $m } @{ $after{mentions} } } @{ $v->{mentions} // [] } )
        && length( $msg->{ $f->( message => 'body' ) } // '' ) + @made > 0;
    my $made = { model => $p->model_name('message'), id => $mid, name => $v->{channel_name}, state => $after{type} };
    return {
        id       => $cid,
        reported => 'write',
        returned => {
            method => $p->action('post'), message_id => $mid, attachments => \@made, created => [$made],
            says => "posted message $mid to channel $cid" . ( defined $v->{reply_to} ? " as a reply to message $v->{reply_to}" : '' ),
        },
        created  => [$made],
        after    => $ok ? \%after : undef,
    };
}

=head2 undo_custom($class, $entry)

The revert of a post: C<discuss.delete> of the message it made (the change
carries C<unmakes>, so the revert does not also say Odoo made that message).
A post that made no message has nothing to undo.

=cut

sub undo_custom ($class, $e) {
    my $r   = $e->{returned};
    my $mid = ref $r eq 'HASH' ? $r->{message_id} : undef;
    my $cid = ref $e->{vals} eq 'HASH' ? $e->{vals}{channel} : undef;
    return ( undef, 'the journal entry made no message: nothing to undo' ) if !$mid;
    return (
        {   bucket => 'undo-post', action => 'custom', handler => 'discuss.delete', kind => 'delete',
            model  => ( ref $e->{created} eq 'ARRAY' && $e->{created}[0] ? $e->{created}[0]{model} : 'mail.message' ), id => $mid, key => "undo:message:$mid", unmakes => 1,
            vals   => { message => $mid, channel => $cid },
            line   => "empty message $mid of channel $cid: its body and attachments go, and Odoo keeps the message record",
            reason => "undo discuss.post: Odoo has no way to unsend a message; its own client empties it and removes its attachments, and the record stays",
        },
    );
}

1;
