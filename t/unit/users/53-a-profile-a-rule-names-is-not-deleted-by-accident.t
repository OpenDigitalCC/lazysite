#!/usr/bin/perl
# SM1141 (slice D of SM1134): address-profile-delete refuses to delete a list that a
# rule still names, and says WHERE. n812 (ruling 234): there is no way past it - the
# CLI's --force is an unknown option and the API's force is not read.
#   - unreferenced: deleted as before
#   - named by a page, an access rule, a group, or either manager conf key: refused
#     (kind in-use), the store untouched, every place named in the refusal
#   - --force and force:true: refused all the same, the store untouched
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
    open my $fh, '<', "$d/lazysite/auth/address-profiles.json" or return ();
    local $/;
    return sort keys %{ decode_json(<$fh>) };
}

sub audit_rows {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep {/address-profile-delete/} <$fh>;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $o{conf} // '' );
    close $cf;
    cli( $d, 'address-profile-set', $_, '--entry', '203.0.113.0/24' ) for qw(office other);
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
    like cli( $d, 'address-profile-delete', 'office' ), qr/Address profile 'office' deleted \(1 entries\)\./, 'deleted';
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
        my $out = cli( $d, 'address-profile-delete', 'office' );
        like $out, qr/still named by .*$re/, 'refused, naming where';
        unlike $out, qr/--force|anyway/, 'and offers no override';
        is_deeply( [ names($d) ], [ 'office', 'other' ], 'the store is untouched' );
        my $r = api( $d, { action => 'address-profile-delete', name => 'office' } );
        ok !$r->{ok} && $r->{kind} eq 'in-use', 'the API refuses with kind in-use';
        like $r->{error}, $re, 'and names it';
        ok scalar @{ $r->{references} }, 'and carries the references';
    };
}

subtest 'there is no force (ruling 234): a profile a rule names is not deleted, at any door' => sub {
    my $d = site( page => 'office', acl => 'office' );
    my $out = cli( $d, 'address-profile-delete', 'office', '--force' );
    like $out, qr/unknown option '--force'/, 'the CLI has no --force';
    is_deeply( [ names($d) ], [ 'office', 'other' ], 'and the store is untouched' );
    my $r = api( $d, { action => 'address-profile-delete', name => 'office', force => JSON::PP::true } );
    ok !$r->{ok} && $r->{kind} eq 'in-use', 'force:true over the API is refused as in-use';
    like $r->{error}, qr/page staff\.md.*access rule for \/intranet\//, 'naming the rules that use it';
    is_deeply( [ names($d) ], [ 'office', 'other' ], 'and the store is untouched' );
};

subtest 'a rule store that cannot be read refuses, and nothing overrides it' => sub {
    my $d = site();
    open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
    print {$a} '{ nope';
    close $a;
    my $out = cli( $d, 'address-profile-delete', 'office' );
    like $out, qr/could not check: acls\.json does not decode/, 'refused: it cannot say nothing names the list';
    ok( ( grep { $_ eq 'office' } names($d) ), 'still there' );
    like cli( $d, 'address-profile-delete', 'office', '--force' ), qr/unknown option '--force'/, 'and --force does not go through';
    ok( ( grep { $_ eq 'office' } names($d) ), 'still there' );
};

subtest 'a profile in use may still be modified (ruling 234)' => sub {
    my $d = site( page => 'office', acl => 'office' );
    like cli( $d, 'address-profile-set', 'office', '--entry', '198.51.100.0/24' ), qr/office/, 'its entries are replaced';
    my $r = api( $d, { action => 'address-profiles-get' } );
    is_deeply( [ map { $_->{cidr} } @{ $r->{profiles}{office}{entries} || [] } ], ['198.51.100.0/24'], 'and the change is stored' )
        or diag explain $r;
    is_deeply( [ names($d) ], [ 'office', 'other' ], 'and the profile is still there' );
};

done_testing();
