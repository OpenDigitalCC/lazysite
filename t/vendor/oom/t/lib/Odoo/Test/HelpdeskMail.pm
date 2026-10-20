package Odoo::Test::HelpdeskMail;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HTTP::Tiny;

# The outgoing mail of a helpdesk live test: the cluster's mail catcher when it answers, with an outgoing server that
# points at it made for the run when the instance has none; when the catcher does not answer, a server that refuses at
# once, so that Odoo's mail does not wait on a dead one (the checks of what the catcher holds are then skipped).
#
#   my ($up, $server) = Odoo::Test::HelpdeskMail::prepare( $odoo, $catcher_url, $stamp );
#   ... Odoo::Test::HelpdeskMail::remove( $odoo, $server ) at the end
#
# A server made here and not removed by the test (the test died first) is removed at exit, so an instance's mail is
# never left pointing at the refusing server.

my @MADE;
END { local $@; remove( @$_ ) for reverse @MADE }

sub prepare ( $odoo, $catcher, $stamp ) {
    my $up = HTTP::Tiny->new( timeout => 3 )->get("$catcher/api/v1/info")->{success} ? 1 : 0;
    my $have = $odoo->model('ir.mail_server')->search_read( [], [ 'smtp_host', 'sequence' ] );
    my ($low) = sort { $a <=> $b } map { $_->{sequence} // 10 } @$have;
    my $seq = defined $low ? $low - 1 : 10;
    my $server;
    if ($up) {
        $server = $odoo->model('ir.mail_server')->create( { name => "oom-test-$stamp-catcher", smtp_host => 'mailcatcher', smtp_port => 1025, smtp_encryption => 'none', sequence => $seq } )
            if !grep { ( $_->{smtp_host} // '' ) eq 'mailcatcher' } @$have;
    }
    else {
        $server = $odoo->model('ir.mail_server')->create( { name => "oom-test-$stamp-void", smtp_host => '127.0.0.1', smtp_port => 9, smtp_encryption => 'none', sequence => $seq } );
    }
    push @MADE, [ $odoo, $server ] if $server;
    return ( $up, $server );
}

sub remove ( $odoo, $server ) {
    return if !$server;
    @MADE = grep { $_->[1] != $server } @MADE;
    eval { $odoo->model('ir.mail_server')->unlink( [$server] ) };
    return;
}

# The helpdesk service login as a member of teams, as Odoo's "User: Team tickets" record rule reads it. The rule reads the
# user's helpdesk_team_ids, and Odoo keeps the compiled rules until a group of the user is written: membership added to a
# team is not seen by the user until then, so the group is written (the same group, added again) after the membership.
#
#   my $uid = Odoo::Test::HelpdeskMail::add_member( $odoo, $login, @team_ids );   # undef when the login is not there
sub add_member ( $odoo, $login, @teams ) {
    my ($uid) = @{ $odoo->model('res.users')->search( [ [ 'login', '=', $login ] ] ) };
    return undef if !$uid;
    $odoo->model('helpdesk.ticket.team')->write( \@teams, { user_ids => [ [ 4, $uid ] ] } );
    my $gid = $odoo->execute_kw( 'ir.model.data', 'check_object_reference', [ 'helpdesk_mgmt', 'group_helpdesk_user_team' ] )->[1];
    $odoo->model('res.users')->write( [$uid], { groups_id => [ [ 4, $gid ] ] } );
    return $uid;
}

# Mail to an address in the catcher: the messages (newest first) whose subject matches, waiting up to $o{wait} half-seconds for
# at least $o{more} more than $o{after} to arrive.
sub mail_to ( $catcher, $to, %o ) {
    require JSON::PP;
    my $http = HTTP::Tiny->new( timeout => 10 );
    my @m;
    for ( 1 .. ( $o{wait} // 1 ) ) {
        my $res = $http->get( "$catcher/api/v1/search?query=" . ( "to:$to" =~ s/([^A-Za-z0-9._~-])/sprintf '%%%02X', ord $1/ger ) );
        @m = $res->{success} ? grep { !defined $o{subject} || ( $_->{Subject} // '' ) =~ $o{subject} } @{ JSON::PP::decode_json( $res->{content} )->{messages} // [] } : ();
        last if @m > ( $o{after} // 0 );
        select undef, undef, undef, 0.5;
    }
    return @m;
}

# Whether a stage's template mail can be sent: its sender is the company's email, and Odoo refuses a mail with no sender unless the
# instance sets mail.catchall.domain and mail.default.from. An instance with neither leaves the template's mail in state exception
# ("You must either provide a sender address explicitly ...").
sub template_mail_can_go ($odoo) {
    my $co = $odoo->model('res.company')->search_read( [], ['email'] );
    return 1 if @$co && !grep { !$_->{email} } @$co;
    my %icp = map { $_->{key} => $_->{value} } @{ $odoo->model('ir.config_parameter')->search_read( [ [ 'key', 'in', [ 'mail.catchall.domain', 'mail.default.from' ] ] ], [ 'key', 'value' ] ) };
    return $icp{'mail.catchall.domain'} && $icp{'mail.default.from'} ? 1 : 0;
}

1;
