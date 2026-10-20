#!/usr/bin/perl
# SM1229: deleting an address list that a binding names is refused, as it is for
# every other user of a list.
#
# SM1159 let a session binding carry signin_addresses / signin_addresses_deny
# (names of address lists, held on the binding's calls). Its filing recorded the
# residual: the delete guard (Auth::AddressRefs, SM1141) did not read
# handlers.conf, so a list a binding named could be deleted with nothing said,
# and the binding then refused every call (an allow rule naming a deleted list
# admits nobody, SM1138).
#
# Both doors run the one guard in the users tool (the manager's
# Manager::AddressLists and the control API's address-list-delete both call it),
# so the test drives it by the CLI and by --api, as t/unit/users/53 does:
#   - refused while a binding names it, in either slot, and in a comma list or a
#     flow list; the refusal names the binding and the references carry it
#   - every kind of user is named together: a page, an access rule, a group, a
#     lazysite.conf key and a binding
#   - allowed once nothing names it (the binding edited), and a different list,
#     a handler that is not an Odoo binding, or a disabled binding's other list
#     is not in the way
#   - force still deletes, and says what still named it
#   - a handlers.conf that cannot be read refuses (it cannot say nothing names it)
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map { "\Q$_\E" } $^X, $script, '--docroot', $d, @args;
    return `$cmd 2>&1` // '';
}

sub api {
    my ( $d, $req ) = @_;
    my $in = File::Temp->new;
    print {$in} encode_json($req);
    close $in;
    my $cmd    = join ' ', map { "\Q$_\E" } $^X, $script, '--docroot', $d, '--api';
    my $out    = `$cmd < \Q$in\E 2>/dev/null`;
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

sub names {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/address-lists.json" or return ();
    local $/;
    return sort keys %{ decode_json(<$fh>) };
}

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

sub binding {
    my (%o) = @_;
    my $text = "handlers:\n  - id: " . ( $o{id} // 'stock' ) . "\n    type: " . ( $o{type} // 'odoo' ) . "\n";
    $text .= "    credential: session\n" unless ( $o{type} // 'odoo' ) ne 'odoo';
    $text .= "    enabled: false\n"                  if $o{disabled};
    $text .= "    signin_addresses: $o{allow}\n"     if defined $o{allow};
    $text .= "    signin_addresses_deny: $o{deny}\n" if defined $o{deny};
    return $text;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/forms" );
    put( "$d/lazysite/lazysite.conf", "site_name: T\n" . ( $o{conf} // '' ) );
    cli( $d, 'address-list-set', $_, '--kind', 'allow', '--entry', '203.0.113.0/24' ) for qw(office other);
    cli( $d, 'address-list-set', 'bad', '--kind', 'deny', '--entry', '198.51.100.0/24' );
    put( "$d/lazysite/forms/handlers.conf", $o{handlers} ) if defined $o{handlers};
    put( "$d/staff.md", "---\ntitle: Staff\naddresses: [$o{page}]\n---\n\nbody\n" ) if $o{page};
    put( "$d/lazysite/auth/acls.json",
        encode_json( { '/intranet/' => { read => ['@staff'], addresses => [ $o{acl} ] } } ) )
        if $o{acl};
    put( "$d/lazysite/auth/groups-settings.json", encode_json( { operators => { addresses => [ $o{group} ] } } ) )
        if $o{group};
    return $d;
}

for my $c (
    [ 'its allow key',                'office', { allow => 'office' } ],
    [ 'its allow key in a list',      'office', { allow => 'other, office' } ],
    [ 'its allow key as a flow list', 'office', { allow => '[office]' } ],
    [ 'its deny key',                 'bad',    { deny  => 'bad' } ],
    [ 'a disabled binding',           'office', { allow => 'office', disabled => 1 } ],
    )
{
    my ( $what, $list, $b ) = @$c;
    subtest "refused while a binding names it: $what" => sub {
        my $d   = site( handlers => binding(%$b) );
        my $out = cli( $d, 'address-list-delete', $list );
        like $out, qr/still named by .*Odoo binding stock/, 'refused, naming the binding';
        like $out, qr/--force/,                             'and how to override';
        is_deeply( [ names($d) ], [ 'bad', 'office', 'other' ], 'the store is untouched' );
        my $r = api( $d, { action => 'address-list-delete', name => $list } );
        ok !$r->{ok} && $r->{kind} eq 'in-use', 'the API refuses with kind in-use';
        like $r->{error}, qr/Odoo binding stock/, 'and names the binding';
        is_deeply( [ map { "$_->{where}:$_->{ref}" } @{ $r->{references} || [] } ], ['binding:stock'], 'and carries the reference' );
    };
}

subtest 'every kind of user is named in one refusal' => sub {
    my $d = site(
        page  => 'office',
        acl   => 'office',
        group => 'office',
        conf  => "manager_addresses: office\nsignin_addresses: office\n",
        handlers => binding( id => 'stock', allow => 'office' ) . binding( id => 'orders', allow => 'office' ) =~ s/handlers:\n//r,
    );
    my $r = api( $d, { action => 'address-list-delete', name => 'office' } );
    ok !$r->{ok} && $r->{kind} eq 'in-use', 'refused';
    my %by;
    push @{ $by{ $_->{where} } }, $_->{ref} for @{ $r->{references} || [] };
    is_deeply( [ sort keys %by ], [qw(acl binding conf group page)], 'a page, an access rule, a group, conf and a binding' );
    is_deeply( [ sort @{ $by{binding} || [] } ], [qw(orders stock)], 'each binding is named' );
    like $r->{error}, qr/Odoo binding orders, stock/, 'and the sentence lists them';
    is_deeply( [ names($d) ], [ 'bad', 'office', 'other' ], 'the store is untouched' );
};

subtest 'allowed once nothing names it' => sub {
    my $d = site( handlers => binding( allow => 'office' ) );
    like cli( $d, 'address-list-delete', 'office' ), qr/still named by/, 'refused while named';
    put( "$d/lazysite/forms/handlers.conf", binding( allow => 'other' ) );
    like cli( $d, 'address-list-delete', 'office' ), qr/Address list 'office' deleted \(1 entries, allow\)\./,
        'deleted once the binding names another list';
    is_deeply( [ names($d) ], [ 'bad', 'other' ], 'and only that one went' );
    my $d2 = site( handlers => binding( allow => 'office' ) );
    put( "$d2/lazysite/forms/handlers.conf", binding() );
    my $r = api( $d2, { action => 'address-list-delete', name => 'office' } );
    ok $r->{ok}, 'deleted over the API once the binding names none' or diag $r->{error};
};

subtest 'what is not a binding naming the list is not in the way' => sub {
    my $d = site( handlers => binding( id => 'mail', type => 'smtp', allow => 'office' ) );
    like cli( $d, 'address-list-delete', 'office' ), qr/Address list 'office' deleted/, 'a handler that is not Odoo';
    my $d2 = site( handlers => binding( allow => 'other', deny => 'bad' ) );
    like cli( $d2, 'address-list-delete', 'office' ), qr/Address list 'office' deleted/, 'a binding naming other lists';
    my $d3 = site();
    like cli( $d3, 'address-list-delete', 'office' ), qr/Address list 'office' deleted/, 'no handlers.conf at all';
};

subtest 'a forced delete goes through and says the binding still named it' => sub {
    my $d = site( handlers => binding( allow => 'office' ) );
    my $r = api( $d, { action => 'address-list-delete', name => 'office', force => JSON::PP::true } );
    ok $r->{ok}, 'force:true' or diag $r->{error};
    like $r->{change}, qr/forced\); still named by .*Odoo binding stock/, 'the change line names the binding';
    is_deeply( [ names($d) ], [ 'bad', 'other' ], 'gone' );
};

subtest 'a handlers.conf that cannot be read refuses' => sub {
    my $d = site( handlers => binding( allow => 'other' ) );
    chmod 0000, "$d/lazysite/forms/handlers.conf";
SKIP: {
        skip 'running as root: the file stays readable', 2 if -r "$d/lazysite/forms/handlers.conf";
        my $r = api( $d, { action => 'address-list-delete', name => 'office' } );
        ok !$r->{ok} && $r->{kind} eq 'in-use', 'refused';
        like $r->{error}, qr/could not check: handlers\.conf/, 'and says what it could not read';
    }
    chmod 0644, "$d/lazysite/forms/handlers.conf";
};

done_testing();
