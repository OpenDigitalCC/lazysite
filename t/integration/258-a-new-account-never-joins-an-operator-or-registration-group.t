#!/usr/bin/perl
# SM1053 (n580), closed by the coordinating session 2026-10-13, consistent with
# the P-1/2/3 ruling ("never the operator flag") and SM991: an import creates
# an account in the groups that exist - and never in an operator group (the
# `manager` flag and its nesting) or a registration group, as an update never
# joins one (n572). The dry run shows the refused group and why. A row naming
# only refused groups still creates the account, in no group.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL = qw(ui api manage_users manage_content);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d   = $s->docroot;
$s->add_user( 'op', 'pw-op-0123456789' );
$s->grant( 'op', 'g-op', [qw(ui manage_users manage_content)], \@ALL );
$s->users( 'group-set', 'g-op', 'manager', 'on' );
uapi( { action => 'group-create', group => 'authors' } );
uapi( { action => 'group-create', group => 'reg' } );
$s->users( 'group-set', 'reg', 'registration', 'on' );
uapi( { action => 'group-create', group => 'nested' } );
uapi( { action => 'group-nest', sub => 'nested', parent => 'g-op' } );    # nested inside the operator group: its members are operators

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub api {
    my ( $action, $body, $query ) = @_;
    return $s->call( 'op', $action, ( defined $body ? ( body => $body ) : () ), query => $query // "action=$action" );
}
sub groups_of {
    my ($u) = @_;
    my $g = uapi( { action => 'groups' } )->{groups} || {};
    return join ',', sort grep { my $n = $_; grep { $_ eq $u } @{ $g->{$n} || [] } } keys %$g;
}

my $r = api( 'accounts-import-stage', { accounts => [
            { username => 'n1', groups => [qw(authors g-op reg nested nosuch)] },
            { username => 'n2', groups => [qw(g-op reg)] },
            { username => 'n3' } ] } );
my $id = $r->{id} // '';
ok( $id, 'staged' ) or diag( $r->{error} // '' );

subtest 'the dry run says what is refused, and why' => sub {
    my $p = api( 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id" );
    my %row = map { $_->{username} => $_ } @{ $p->{rows} || [] };
    is_deeply( $row{n1}{groups}, ['authors'], 'n1 would join authors only' );
    my %ref = map { $_->{group} => $_->{why} } @{ $row{n1}{groups_refused} || [] };
    like( $ref{'g-op'}  // '', qr/operator/,       'the operator group: refused, said why' );
    like( $ref{nested}  // '', qr/operator/,       'a group nested in it: refused too' );
    like( $ref{reg}     // '', qr/registration/,   'a registration group: refused, said why' );
    ok( !exists $ref{nosuch}, 'a group that does not exist stays groups_missing, as before' );
    is_deeply( $row{n1}{groups_missing}, ['nosuch'], '...named as missing' );
    is_deeply( $row{n2}{groups}, [], 'n2, naming only refused groups, would join none' );
    is( $row{n2}{action}, 'create', '...and is still created' );
};

subtest 'the apply creates them in no operator or registration group' => sub {
    my $r = api( 'accounts-import-apply', { id => $id, confirm => $id } );
    ok( $r->{ok}, 'applied' ) or diag( $r->{error} // '' );
    is( groups_of('n1'), 'authors', 'n1: authors only' );
    is( groups_of('n2'), '',        'n2 exists, in no group' );
    my $u = uapi( { action => 'list' } )->{users} || [];
    ok( ( grep { $_ eq 'n2' } @$u ), 'n2 was created' );
    my ($n1) = grep { $_->{username} eq 'n1' } @{ $r->{created} || [] };
    is_deeply( $n1->{groups}, ['authors'], 'the reply says where it was placed' );
};

done_testing;
