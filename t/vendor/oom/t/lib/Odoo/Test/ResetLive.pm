package Odoo::Test::ResetLive;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter 'import';
use HTTP::Tiny;
use JSON::PP ();

use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Core::User;
use Odoo::Ops::Runner;
use Odoo::Ops::Runs;
use File::Temp qw(tempdir);

our @EXPORT_OK = qw(reset_user catcher_link rebase mail_cleanup remove_user);

=head1 NAME

Odoo::Test::ResetLive - what the live reset-take tests share

=head1 DESCRIPTION

A user is made under a fresh stamp with C<core.user action=create>, Odoo's own
reset mail is sent with C<action=reset> (the catcher takes it), and the link
is read from the partner's C<signup_url>. C<rebase> puts a link on the
instance's own address: the host in C<signup_url> is C<web.base.url>, which on
the local cluster is not the name the proxy answers to.

=cut

# create + reset through core.user, as the key connection; returns the facts a test needs
sub reset_user ( $cfg, $odoo, $stamp, $label = 'rt' ) {
    my $login = "$stamp-$label\@oom.example";
    # 18 and 19 give the partner no signup_url field, so the link is the mail's; an instance with no outgoing
    # server cannot send it, so one that points at the catcher is made for the run and removed after
    my $server;
    my $have = $odoo->model('ir.mail_server')->search_read( [], [ 'smtp_host', 'sequence' ] );
    if ( !grep { ($_->{smtp_host} // '') eq 'mailcatcher' } @$have ) {
        # Odoo uses the lowest sequence first
        my ($low) = sort { $a <=> $b } map { $_->{sequence} // 10 } @$have;
        $server = $odoo->model('ir.mail_server')->create( { name => "oom-test-$stamp-catcher", smtp_host => 'mailcatcher', smtp_port => 1025,
            smtp_encryption => 'none', sequence => ( defined $low ? $low - 1 : 10 ) } );
    }
    my $runs  = $cfg->get('runs_dir');
    my $run   = sub (@rows) {
        my $ctx  = Odoo::Ops::Context->new( config => $cfg );
        my $plan = Odoo::Ops::Core::User->new( ctx => $ctx, params => { records => \@rows } )->run;
        my $dir  = tempdir( 'reset-XXXX', DIR => $runs );
        Odoo::Ops::Runs->approve_plan( $dir, $plan, by => 'live-test' );
        return ( $plan, Odoo::Ops::Runner->apply( Odoo::Ops::Context->new( config => $cfg ), $plan, dir => $dir ) );
    };
    my ( $p1, $r1 ) = $run->( { action => 'create', login => $login, name => "OOM Reset $stamp $label", email => $login } );
    my ( $p2, $r2 ) = $run->( { action => 'reset', login => $login } );
    my $u = $odoo->model('res.users')->search_read( [ [ 'login', '=', $login ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ], [ 'partner_id' ] )->[0];
    my $pid = ref $u->{partner_id} eq 'ARRAY' ? $u->{partner_id}[0] : $u->{partner_id};
    return { login => $login, uid => $u->{id}, pid => $pid, created => $r1, reset => $r2, server => $server,
        signup_url => sub { $odoo->model('res.partner')->fields->{signup_url} ? $odoo->model('res.partner')->read_one( $pid, ['signup_url'] )->{signup_url} : undef } };
}

# the link a caught mail carries (the first /web/reset_password URL of its HTML), or undef
sub catcher_link ( $catcher, $to ) {
    my $http = HTTP::Tiny->new( timeout => 10 );
    my $json = JSON::PP->new;
    my $got;
    for ( 1 .. 20 ) {
        my $res = $http->get( "$catcher/api/v1/search?query=" . _q("to:$to") );
        if ( $res->{success} ) {
            my $m = ( $json->decode( $res->{content} )->{messages} // [] )->[0];
            if ($m) { $got = $m->{ID}; last }
        }
        select undef, undef, undef, 0.5;
    }
    return ( undef, undef ) if !defined $got;
    my $res  = $http->get("$catcher/api/v1/message/$got");
    my $msg  = $json->decode( $res->{content} );
    my ($link) = ( $msg->{HTML} // $msg->{Text} // '' ) =~ m{(https?://[^"'\s<>]+/web/reset_password\?[^"'\s<>]+)};
    $link =~ s/&amp;/&/g if defined $link;
    return ( $link, $got );
}

sub _q ($s) { $s =~ s/([^A-Za-z0-9._~-])/sprintf '%%%02X', ord $1/ger }

# the link on this config's own scheme, host and port
sub rebase ( $link, $cfg ) {
    my ($tail) = $link =~ m{\Ahttps?://[^/]+(/.*)\z};
    ( my $base = $cfg->get('url') ) =~ s{/+\z}{};
    return "$base$tail";
}

sub mail_cleanup ( $catcher, @ids ) {
    @ids = grep { defined } @ids;
    return if !@ids;
    HTTP::Tiny->new( timeout => 10 )->request( 'DELETE', "$catcher/api/v1/messages",
        { headers => { 'content-type' => 'application/json' }, content => JSON::PP->new->encode( { IDs => \@ids } ) } );
}

# deactivate, then delete the user and its partner where Odoo allows; says what stayed
sub remove_user ( $odoo, $r ) {
    my @stays;
    eval { $odoo->model('res.users')->write( $r->{uid}, { active => JSON::PP::false } ); 1 } or push @stays, "user $r->{uid} not deactivated";
    my $gone = eval { $odoo->model('res.users')->unlink( $r->{uid} ); 1 };
    push @stays, "user $r->{uid} archived (Odoo refused the delete)" if !$gone;
    if ($gone) {
        my $pg = eval { $odoo->model('res.partner')->unlink( $r->{pid} ); 1 };
        push @stays, "partner $r->{pid} stays" if !$pg;
    }
    else { push @stays, "partner $r->{pid} stays" }
    if ( $r->{server} ) {
        eval { $odoo->model('ir.mail_server')->unlink( $r->{server} ); 1 } or push @stays, "mail server $r->{server} stays";
    }
    return @stays;
}

1;
