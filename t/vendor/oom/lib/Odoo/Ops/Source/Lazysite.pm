package Odoo::Ops::Source::Lazysite;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use MIME::Base64 ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Transport;

=head1 NAME

Odoo::Ops::Source::Lazysite - read a lazysite site's data tables

=head1 SYNOPSIS

    my $site = Odoo::Ops::Source::Lazysite->new(
        api        => 'https://site.example/cgi-bin/lazysite-manager-api.pl',
        credential => Odoo::Ops::Credential->lazysite_token($file),
    );
    my $rows = $site->rows('recon_so');    # [ { col => value, ... }, ... ]

=head1 DESCRIPTION

The one place the manager API's C<data-export> action is spoken. A
request is C<POST api?action=data-export&table=NAME> with
C<Authorization: Basic base64(partner:token)>; the answer is JSON
C<< { ok: true, rows: [...] } >>. C<ok: false> is a refusal: kind
C<fault>, fault class C<lazysite> (category C<lazysite>), carrying the
site's own C<error> text and never retried. A transport failure (no
answer, or HTTP 5xx) is retried on a ladder of sleeps (C<retries>,
default C<0, 2, 5, 15> seconds) and then dies as kind C<transport>. A
redirect is refused as L<Odoo::Transport/refuse_by_policy> does.

Nothing is written to the site; the only action sent is C<data-export>.

Options to C<new>: C<api> and C<credential> (the hash from
L<Odoo::Ops::Credential/lazysite_token>) are required; C<http> is an
object with HTTP::Tiny's C<post> (tests pass a fake); otherwise one is
built by L<Odoo::Transport/http_client> from C<ssl_ca_file>,
C<ssl_verify> and C<timeout>, the options the Odoo connection takes;
C<retries> is an array reference of sleeps.

=cut

sub new ($class, %a) {
    for my $k (qw(api credential)) {
        Odoo::Error->throw( kind => 'config', message => "lazysite reader needs $k" ) if !$a{$k};
    }
    Odoo::Error->throw( kind => 'config', message => "lazysite reader: api '$a{api}' must be an https:// or http:// URL" )
        if $a{api} !~ m{^https?://}i;
    return bless {
        api     => $a{api},
        cred    => $a{credential},
        retries => $a{retries} // [ 0, 2, 5, 15 ],
        http    => $a{http} // Odoo::Transport::http_client(
            ( map { defined $a{$_} ? ( $_ => $a{$_} ) : () } qw(ssl_ca_file ssl_verify timeout) ),
        ),
    }, $class;
}

=head2 rows($table)

The rows of one table, a list reference of hash references, in the
order the site gave them. Cached per table for the life of the object,
so a table named twice in a mapping is fetched once.

=cut

sub rows ($self, $table) {
    Odoo::Error->throw( kind => 'usage', message => 'lazysite reader: a table name is required' )
        if !defined $table || $table !~ /^[A-Za-z0-9_.-]+\z/;
    # the name is restricted above to characters that need no URL escaping
    return $self->{cache}{$table} //= $self->_export($table);
}

sub _export ($self, $table) {
    my $sep = $self->{api} =~ /\?/ ? '&' : '?';
    my $url = "$self->{api}${sep}action=data-export&table=" . $table;
    my $auth = 'Basic ' . MIME::Base64::encode_base64( "$self->{cred}{partner}:$self->{cred}{token}", '' );
    my $label = "lazysite data-export '$table'";
    my ( $res, $last );
    for my $delay ( @{ $self->{retries} } ) {
        sleep $delay if $delay;
        $res = $self->{http}->post( $url, { headers => { Authorization => $auth, 'Content-Length' => 0 }, content => '' } );
        my $status = $res->{status} // 0;
        last if $res->{success} || ( $status >= 300 && $status < 500 );
        $last = "$label: " . ( $status == 599 ? ( $res->{content} // 'no answer' ) : "HTTP $status " . ( $res->{reason} // '' ) );
        undef $res;
    }
    Odoo::Error->throw( kind => 'transport', message => ( $last // "$label: no attempt made" ) =~ s/\s+\z//r ) if !$res;
    Odoo::Transport::refuse_by_policy( $res, $label );
    my $status = $res->{status} // 0;
    if ( !$res->{success} ) {
        # the site may still say why in JSON; otherwise name the status
        my $body = eval { Odoo::Ops::json()->decode( $res->{content} // '' ) };
        my $why = ref $body eq 'HASH' && defined $body->{error} ? ": $body->{error}" : '';
        Odoo::Error->throw( kind => 'refused', code => "http-$status", message => "$label: HTTP $status$why" . ( $status == 401 ? ' (token not accepted; it may have expired)' : '' ) );
    }
    my $data = eval { Odoo::Ops::json()->decode( $res->{content} // '' ) };
    Odoo::Error->throw( kind => 'transport', message => "$label: the answer is not JSON" ) if ref $data ne 'HASH' && ref $data ne 'ARRAY';
    if ( ref $data eq 'HASH' && exists $data->{ok} && !$data->{ok} ) {
        Odoo::Error->throw( kind => 'fault', fault_class => 'lazysite',
            message => "$label refused: " . ( $data->{error} // 'ok:false without an error' ) );
    }
    my $rows = ref $data eq 'ARRAY' ? $data : $data->{rows};
    Odoo::Error->throw( kind => 'fault', fault_class => 'lazysite', message => "$label: the answer has no rows list" )
        if ref $rows ne 'ARRAY';
    return $rows;
}

1;
