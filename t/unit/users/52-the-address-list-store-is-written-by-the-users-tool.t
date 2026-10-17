#!/usr/bin/perl
# SM1138 (slice A of SM1134): lazysite/auth/address-lists.json is written only
# by the users tool, like the other access stores, and only for the operator.
#
# What this holds, through the CLI and the --api door the manager drives:
#   - address-list-set creates a list (kind + entries with notes), canonicalises
#     each entry, replaces a list's entries, keeps them when none are given,
#     and changes the kind alone
#   - every entry is validated before anything is written; a refusal names the
#     entry and changes nothing (a 0-length prefix, text, a duplicate, a long note)
#   - a name is [a-z0-9_-]{1,64}; a new list needs a kind
#   - address-list-delete removes one list and nothing else
#   - the operator writes; a manage_users holder who is not the operator is
#     refused (forbidden) and the store is untouched; reading is open to the tool
#   - every change is audited with who, which list and what changed (CLI row)
#   - a store that will not decode is not written over (SM785, SM1024)
#   - the store is 0660 and holds records the module reads back
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

sub store {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/address-lists.json" or return undef;
    local $/;
    return decode_json(<$fh>);
}

sub audit_rows {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep {/address-list/} <$fh>;
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
cli( $d, 'setup-sysop', '--user', 'op', 'secretpw1234' );
cli( $d, 'add', $_, 'pw12345678-long-enough' ) for qw(del carol);
my $r0 = api( $d, { action => 'group-add', username => 'del', group => 'user-managers' } );
ok $r0->{ok}, 'del joins user-managers (a manage_users holder, not the operator)' or diag $r0->{error};

subtest 'the CLI creates, shows and replaces a list' => sub {
    my $out = cli( $d, 'address-list-set', 'office', '--kind', 'allow',
        '--entry', '203.0.113.0/24=HQ network', '--entry', '198.51.100.7', '--entry', '2001:DB8:1::/48=v6' );
    like $out, qr/Address list 'office' \(allow\): created kind allow \+203\.0\.113\.0\/24,\+198\.51\.100\.7,\+2001:db8:1::\/48\./,
        'the change is named';
    my $s = store($d);
    is_deeply( $s->{office}{entries},
        [ { cidr => '203.0.113.0/24', note => 'HQ network' }, { cidr => '198.51.100.7', note => '' },
            { cidr => '2001:db8:1::/48', note => 'v6' } ],
        'entries are stored canonical, in the order given, with their notes' );
    is( $s->{office}{kind}, 'allow', 'kind' );
    like( $s->{office}{created_by}, qr/\Asystem:/, 'created_by is the shell identity' );
    is( sprintf( '%04o', ( stat "$d/lazysite/auth/address-lists.json" )[2] & 07777 ), '0660', 'mode 0660' );

    like cli( $d, 'address-lists' ), qr/office \(allow, 3 entries\)\n  203\.0\.113\.0\/24  # HQ network\n  198\.51\.100\.7\n/,
        'address-lists shows it';

    my $o2 = cli( $d, 'address-list-set', 'office', '--kind', 'allow', '--entry', '203.0.113.0/24=HQ network' );
    like $o2, qr/-198\.51\.100\.7,-2001:db8:1::\/48/, 'a replace names what went';
    is( scalar @{ store($d)->{office}{entries} }, 1, 'and the entries are the new set' );
    like cli( $d, 'address-list-set', 'office', '--kind', 'allow', '--entry', '203.0.113.0/24=Head office' ),
        qr/: note 203\.0\.113\.0\/24\./, 'a changed note is a change';
    like cli( $d, 'address-list-set', 'office', '--kind', 'allow', '--entry', '203.0.113.0/24=Head office' ),
        qr/: no change\./, 'the same again is no change';
    my $k = cli( $d, 'address-list-set', 'office', '--kind', 'deny' );
    like $k, qr/\(deny\): kind allow->deny\./, 'the kind alone changes, with no --entry';
    is( scalar @{ store($d)->{office}{entries} }, 1, 'and the entries were kept' );
    like cli( $d, 'address-list-set', 'office', '--kind', 'allow' ), qr/kind deny->allow/, 'and back';
};

subtest 'the API door: set, get, delete' => sub {
    my $r = api( $d, { action => 'address-list-set', name => 'blocked', kind => 'deny',
            entries => [ { cidr => '198.51.100.0/24', note => 'abuse' }, '192.0.2.9=one host' ] } );
    ok $r->{ok}, 'accepted' or diag $r->{error};
    is( $r->{change}, 'created kind deny +198.51.100.0/24,+192.0.2.9', 'the change line' );
    my $g = api( $d, { action => 'address-lists-get' } );
    ok $g->{ok}, 'address-lists-get' or diag $g->{error};
    is( $g->{store_fault}, '', 'no fault' );
    is_deeply( [ sort keys %{ $g->{lists} } ], [ 'blocked', 'office' ], 'both lists' );
    is_deeply( $g->{lists}{blocked}{entries},
        [ { cidr => '198.51.100.0/24', note => 'abuse' }, { cidr => '192.0.2.9', note => 'one host' } ], 'entries' );
    my $e = api( $d, { action => 'address-list-set', name => 'blocked', entries => [] } );
    ok $e->{ok}, 'an empty LIST clears the entries (kind kept)' or diag $e->{error};
    is( scalar @{ store($d)->{blocked}{entries} }, 0, 'cleared' );
    is( store($d)->{blocked}{kind}, 'deny', 'kind kept' );
    my $x = api( $d, { action => 'address-list-delete', name => 'blocked' } );
    ok $x->{ok}, 'deleted' or diag $x->{error};
    like $x->{change}, qr/\Adeleted \(0 entries, deny\)\z/, 'the change line';
    ok !exists store($d)->{blocked}, 'gone';
    ok exists store($d)->{office}, 'and the other list is untouched';
    my $nf = api( $d, { action => 'address-list-delete', name => 'blocked' } );
    ok !$nf->{ok} && $nf->{kind} eq 'not-found', 'deleting what is not there is not-found';
};

subtest 'validation: every entry is checked, naming it, and nothing is written' => sub {
    my $before = do { local $/; open my $h, '<', "$d/lazysite/auth/address-lists.json" or die; <$h> };
    my %bad = (
        '0.0.0.0/0'                 => qr/0\.0\.0\.0\/0/,
        'banana'                    => qr/banana/,
        '10.0.0.0/33'               => qr/10\.0\.0\.0\/33/,
        '10.0.0.0/8,10.1.0.0/16'    => qr/10\.0\.0\.0\/8,10\.1\.0\.0\/16/,
        '::/0'                      => qr/::\/0/,
    );
    for my $e ( sort keys %bad ) {
        my $r = api( $d, { action => 'address-list-set', name => 'office', kind => 'allow',
                entries => [ '203.0.113.0/24', $e ] } );
        ok !$r->{ok}, "'$e' is refused";
        like $r->{error}, $bad{$e}, 'and named';
        is( $r->{field}, 'entries', 'as an entries problem' );
    }
    my $dup = api( $d, { action => 'address-list-set', name => 'office', kind => 'allow',
            entries => [ '203.0.113.0/24', '203.0.113.0/24=again' ] } );
    ok !$dup->{ok} && $dup->{error} =~ /listed twice/, 'a duplicate is refused';
    my $long = api( $d, { action => 'address-list-set', name => 'office', kind => 'allow',
            entries => [ { cidr => '10.0.0.1', note => 'x' x 201 } ] } );
    ok !$long->{ok} && $long->{error} =~ /longer than 200/, 'a note over 200 characters is refused';
    my $nl = api( $d, { action => 'address-list-set', name => 'nl', kind => 'allow',
            entries => [ { cidr => '10.0.0.1', note => "two\nlines" } ] } );
    ok $nl->{ok}, 'a note with a newline is accepted' or diag $nl->{error};
    is( store($d)->{nl}{entries}[0]{note}, 'two lines', 'and kept on one line' );
    api( $d, { action => 'address-list-delete', name => 'nl' } );
    my $notlist = api( $d, { action => 'address-list-set', name => 'office', kind => 'allow', entries => 'x' } );
    ok !$notlist->{ok}, 'entries that are not a list are refused';
    my $many = api( $d, { action => 'address-list-set', name => 'many', kind => 'allow',
            entries => [ map { "10.0." . int( $_ / 250 ) . "." . ( $_ % 250 + 1 ) } 0 .. 1000 ] } );
    ok !$many->{ok} && $many->{error} =~ /at most 1000/, 'a thousand and one entries are refused';
    my $after = do { local $/; open my $h, '<', "$d/lazysite/auth/address-lists.json" or die; <$h> };
    is( $after, $before, 'the store is byte for byte what it was' );
};

subtest 'names and kinds' => sub {
    for my $n ( 'Office', 'a b', '', 'a' x 65, '../x', 'x.y', 'ÅB' ) {
        my $r = api( $d, { action => 'address-list-set', name => $n, kind => 'allow' } );
        ok !$r->{ok} && ( $r->{field} // '' ) eq 'name', "'" . ( length $n > 20 ? 'a' x 20 . '...' : $n ) . "' is not a name";
    }
    my $ok = api( $d, { action => 'address-list-set', name => 'a' x 64, kind => 'deny' } );
    ok $ok->{ok}, '64 characters is a name' or diag $ok->{error};
    api( $d, { action => 'address-list-delete', name => 'a' x 64 } );
    my $nk = api( $d, { action => 'address-list-set', name => 'newone' } );
    ok !$nk->{ok} && $nk->{field} eq 'kind', 'a new list needs a kind';
    my $bk = api( $d, { action => 'address-list-set', name => 'newone', kind => 'maybe' } );
    ok !$bk->{ok} && $bk->{field} eq 'kind', 'allow or deny only';
    ok !exists store($d)->{newone}, 'and nothing was created';
    like cli( $d, 'address-list-set', 'Bad Name', '--kind', 'allow' ), qr/A list name is 1 to 64/, 'the CLI says so too';
    like cli( $d, 'address-list-set', 'office', '--bogus' ), qr/unknown option/, 'an unknown option is named';
};

subtest 'the operator writes; a manage_users holder does not' => sub {
    my $before = do { local $/; open my $h, '<', "$d/lazysite/auth/address-lists.json" or die; <$h> };
    for my $req (
        { action => 'address-list-set', name => 'sneak', kind => 'allow', entries => ['0.0.0.1'] },
        { action => 'address-list-delete', name => 'office' },
        { action => 'address-list-set', name => 'office', kind => 'deny' } )
    {
        for my $actor ( 'del', 'carol' ) {
            my $r = api( $d, { %$req, actor => $actor } );
            ok !$r->{ok} && ( $r->{kind} // '' ) eq 'forbidden', "$actor: $req->{action} $req->{name} is refused";
            like $r->{error}, qr/Only the operator changes address lists/, 'and says whose they are';
        }
    }
    is( do { local $/; open my $h, '<', "$d/lazysite/auth/address-lists.json" or die; <$h> }, $before, 'the store is untouched' );
    my $op = api( $d, { action => 'address-list-set', name => 'byop', kind => 'allow', entries => ['10.0.0.1=op'], actor => 'op' } );
    ok $op->{ok}, 'the operator writes' or diag $op->{error};
    is( store($d)->{byop}{created_by}, 'op', 'and is recorded as the author' );
    is( store($d)->{byop}{updated_by}, 'op', 'and as the last editor' );
    my $dl = api( $d, { action => 'address-list-delete', name => 'byop', actor => 'op' } );
    ok $dl->{ok}, 'and deletes' or diag $dl->{error};
    my $loc = api( $d, { action => 'address-list-set', name => 'bylocal', kind => 'deny', actor => 'local' } );
    ok $loc->{ok}, 'the shell sentinel `local` is not confined' or diag $loc->{error};
    api( $d, { action => 'address-list-delete', name => 'bylocal' } );
    my $rd = api( $d, { action => 'address-lists-get', actor => 'del' } );
    ok $rd->{ok}, 'reading is not the tool\'s to refuse (the manager asks manage_users)';
};

subtest 'every CLI change is audited: who, which list, what changed' => sub {
    my @rows = audit_rows($d);
    ok( scalar @rows >= 5, 'the CLI changes left rows' );
    my ($created) = grep {/address-list-set \| office \|/ && /created kind allow/} @rows;
    ok( $created, 'the creation names the list and the change' );
    like( $created // '', qr/ \| system:\S+ \| address-list-set \| office \| \S* \| ok \| cli \| created kind allow \+203\.0\.113\.0\/24,/,
        'as the shell identity, origin cli' );
    my ($nochange) = grep {/no change/} @rows;
    ok( !$nochange, 'a no-change set writes no row' );
    ok( ( grep {/address-list-set \| office \|.*kind allow->deny/} @rows ), 'a kind change is a row' );
    cli( $d, 'address-list-delete', 'nl-none' );
    cli( $d, 'address-list-set', 'gone', '--kind', 'deny', '--entry', '192.0.2.1' );
    cli( $d, 'address-list-delete', 'gone' );
    my ($del) = grep {/address-list-delete \| gone \|.*deleted \(1 entries, deny\)/} audit_rows($d);
    ok( $del, 'a delete is a row naming the list and what it held' );
    ok( !( grep { /pw12345678|secretpw/ } audit_rows($d) ), 'no secret reaches the trail' );
    my $api_before = scalar audit_rows($d);
    api( $d, { action => 'address-list-set', name => 'viaapi', kind => 'allow', actor => 'op' } );
    is( scalar audit_rows($d), $api_before, 'under --api the tool writes none: the calling web surface records the request' );
    api( $d, { action => 'address-list-delete', name => 'viaapi', actor => 'op' } );
};

subtest 'a store that will not decode is not written over' => sub {
    my $f = "$d/lazysite/auth/address-lists.json";
    open my $h, '>', $f or die;
    print {$h} '{ "office": { "kind": "allow", "entries": [';
    close $h;
    my $r = api( $d, { action => 'address-list-set', name => 'x', kind => 'allow' } );
    ok !$r->{ok} && $r->{kind} eq 'cannot-tell' && $r->{error} =~ /does not decode/, 'set refuses, saying why';
    my $x = api( $d, { action => 'address-list-delete', name => 'office' } );
    ok !$x->{ok} && $x->{kind} eq 'cannot-tell', 'delete refuses';
    my $g = api( $d, { action => 'address-lists-get' } );
    is( $g->{store_fault}, 'undecodable', 'and the read says the store is faulted, not empty' );
    is( do { local $/; open my $in, '<', $f or die; <$in> }, '{ "office": { "kind": "allow", "entries": [', 'the file is as it was' );
    like cli( $d, 'address-lists' ), qr/is undecodable: the lists cannot be read/, 'the CLI listing says so' ;
};

done_testing;
