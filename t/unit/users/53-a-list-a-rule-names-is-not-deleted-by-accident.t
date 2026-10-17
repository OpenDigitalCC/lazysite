#!/usr/bin/perl
# SM1141 (slice D of SM1134): address-list-delete refuses to delete a list that a
# rule still names, and says WHERE; --force (CLI) / force:true (API) deletes it
# anyway and the audit names what still refers to it.
#   - unreferenced: deleted as before
#   - named by a page, an access rule, a group, or either manager conf key: refused
#     (kind in-use), the store untouched, every place named in the refusal
#   - --force / force:true: deleted; the audit row (CLI) and the change line (API,
#     which the manager's audit row carries) name what still refers to it
#   - a rule store that cannot be read refuses too (it cannot say nothing names it)
#   - a rule naming a DIFFERENT list is not in the way
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
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, @args;
    return `$cmd 2>&1` // '';
}

sub api {
    my ( $d, $req ) = @_;
    my $in = File::Temp->new;
    print {$in} encode_json($req);
    close $in;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, '--api';
    my $out = `$cmd < \Q$in\E 2>/dev/null`;
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

sub names {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/address-lists.json" or return ();
    local $/;
    return sort keys %{ decode_json(<$fh>) };
}

sub audit_rows {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep {/address-list-delete/} <$fh>;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $o{conf} // '' );
    close $cf;
    cli( $d, 'address-list-set', $_, '--kind', 'allow', '--entry', '203.0.113.0/24' ) for qw(office other);
    if ( $o{page} ) {
        open my $p, '>', "$d/staff.md" or die $!;
        print {$p} "---\ntitle: Staff\naddresses: [$o{page}]\n---\n\nbody\n";
        close $p;
    }
    if ( $o{acl} ) {
        open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
        print {$a} encode_json( { '/intranet/' => { read => ['@staff'], addresses_deny => [ $o{acl} ] } } );
        close $a;
    }
    if ( $o{group} ) {
        open my $g, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
        print {$g} encode_json( { operators => { addresses => [ $o{group} ] } } );
        close $g;
    }
    return $d;
}

subtest 'unreferenced: deleted' => sub {
    my $d = site( page => 'other' );    # a rule exists, but for another list
    like cli( $d, 'address-list-delete', 'office' ), qr/Address list 'office' deleted \(1 entries, allow\)\./, 'deleted';
    is_deeply( [ names($d) ], ['other'], 'and only that one' );
};

for my $c (
    [ 'a page',              { page => 'office' },                     qr/page staff\.md/ ],
    [ 'an access rule',      { acl => 'office' },                      qr{access rule for /intranet/} ],
    [ 'a group',             { group => 'office' },                    qr/group operators/ ],
    [ 'the manager allow key', { conf => "manager_addresses: office\n" }, qr/lazysite\.conf key manager_addresses\b/ ],
    [ 'the manager deny key',  { conf => "manager_addresses_deny: office, x\n" }, qr/lazysite\.conf key manager_addresses_deny/ ],
    )
{
    my ( $what, $o, $re ) = @$c;
    subtest "refused while $what names it" => sub {
        my $d = site(%$o);
        my $out = cli( $d, 'address-list-delete', 'office' );
        like $out, qr/still named by .*$re/, 'refused, naming where';
        like $out, qr/--force/, 'and how to override';
        is_deeply( [ names($d) ], [ 'office', 'other' ], 'the store is untouched' );
        my $r = api( $d, { action => 'address-list-delete', name => 'office' } );
        ok !$r->{ok} && $r->{kind} eq 'in-use', 'the API refuses with kind in-use';
        like $r->{error}, $re, 'and names it';
        ok scalar @{ $r->{references} }, 'and carries the references';
    };
}

subtest 'a forced delete goes through and is audited naming what still refers to it' => sub {
    my $d = site( page => 'office', acl => 'office' );
    my $out = cli( $d, 'address-list-delete', 'office', '--force' );
    like $out, qr/deleted \(1 entries, allow, forced\); still named by .*page staff\.md.*access rule for \/intranet\//,
        'the CLI says it was forced and what still names it';
    is_deeply( [ names($d) ], ['other'], 'gone' );
    my ($row) = audit_rows($d);
    like( $row // '', qr/forced.*still named by .*page staff\.md/, 'the audit row names what still refers to it' );

    my $d2 = site( group => 'office' );
    my $r = api( $d2, { action => 'address-list-delete', name => 'office', force => JSON::PP::true } );
    ok $r->{ok}, 'force:true over the API' or diag $r->{error};
    like $r->{change}, qr/forced\); still named by group operators/, 'the change line (the manager audit row carries it) names the group';
};

subtest 'a rule store that cannot be read refuses, and force overrides' => sub {
    my $d = site();
    open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
    print {$a} '{ nope';
    close $a;
    my $out = cli( $d, 'address-list-delete', 'office' );
    like $out, qr/could not check: acls\.json does not decode/, 'refused: it cannot say nothing names the list';
    ok( ( grep { $_ eq 'office' } names($d) ), 'still there' );
    like cli( $d, 'address-list-delete', 'office', '--force' ), qr/forced\); still named by could not check/, 'forced goes through';
};

done_testing();
