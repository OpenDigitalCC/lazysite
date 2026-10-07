#!/usr/bin/perl
# SM963: an approval that could not place the account in a group says so.
#
# account-approve joins every group flagged to take registrations, each inside
# an eval whose failure was skipped. Reproduced before the fix with a flagged
# BACKEND group (cmd_group_add refuses to give one to a person): the CLI printed
# "Approved 'alice' into learners." and the Users API answered ok with
# group ["learners"] - the flagged `vault` was dropped with nothing said, so the
# approval read as complete for an account missing a group it was meant to have.
#
# The account is still created and the link still minted - a failed placement
# is not a reason to throw the approval away - but each one is now reported:
# `unplaced` on the result (always present, empty when everything took), a line
# per group on the CLI, the audit detail, and SM858's approve result and trail.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root site_tempdir run_cmd);
use ManagerSession qw(new_site);

my $tool = repo_root() . '/tools/lazysite-users.pl';
plan skip_all => 'users tool missing' unless -f $tool;

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    return $d;
}

sub cli {
    my ( $d, @a ) = @_;
    my $out = run_cmd( $^X, $tool, '--docroot', $d, @a );
    return ( $? >> 8, $out );
}

sub api {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    my $r = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}

sub accounts {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or return ();
    my @u = map { ( split /:/ )[0] } grep { /\S/ } <$fh>;
    close $fh;
    return sort @u;
}

sub audit_lines {
    my ( $d, $re ) = @_;
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = grep { $_ =~ $re } <$fh>;
    close $fh;
    return @l;
}

# Two groups take registrations; `vault` is a backend group, which no person
# can be put in - the placement that cannot take.
sub flagged_site {
    my $d = shift // site();
    cli( $d, 'group-set', 'learners', 'ui', 'on' );
    cli( $d, 'group-set', 'vault',    'ui', 'on' );
    cli( $d, 'group-set', 'vault', 'assignable', 'off' );
    for my $g (qw(learners vault)) {
        my $s = api( $d, { action => 'group-settings-set', group => $g,
                key => 'registration', value => 'on' } );
        die "could not flag $g: " . ( $s->{error} // $s->{_raw} // '' ) unless $s->{ok};
    }
    return $d;
}

subtest 'the Users API reports the group that did not take' => sub {
    my $d = flagged_site();
    my $r = api( $d, { action => 'account-approve', username => 'bob' } );
    ok( $r->{ok}, 'the approval still succeeds - the account is not rolled back' )
        or diag( $r->{error} // $r->{_raw} );
    is_deeply( $r->{group}, ['learners'], 'placed in the group that took' );
    is( ref $r->{unplaced}, 'ARRAY', 'and the result carries the placements that failed' )
        or diag( 'A flagged group that could not be joined was skipped with '
            . 'nothing said: an absence reported as a success.' );
    is_deeply( [ map { $_->{group} } @{ $r->{unplaced} || [] } ], ['vault'],
        'naming the group' );
    like( ( $r->{unplaced} || [] )->[0]{error} // '', qr/BACKEND group/,
        'and why it did not take' );
    is_deeply( [ accounts($d) ], ['bob'], 'the account exists' );
    ok( length( $r->{claim} // '' ), 'and its link was minted' );
};

subtest 'the CLI prints it, and its trail records it' => sub {
    my $d = flagged_site();
    my ( $rc, $out ) = cli( $d, 'account-approve', 'alice' );
    is( $rc, 0, 'the approval succeeds' ) or diag($out);
    like( $out, qr/Approved 'alice' into learners/, 'naming the group it joined' );
    like( $out, qr/NOT placed in 'vault': '?vault'? is a BACKEND group/,
        'and the one it could not join, with the reason' );
    like( $out, qr{/claim\?u=alice&c=}, 'and the link is still printed' );

    my @a = audit_lines( $d, qr/\| user-account-approve \| alice \|/ );
    like( $a[-1] // '', qr/placed in learners; NOT placed in vault/,
        'the audit detail names the group that did not take' );
};

subtest 'the manager Users API passes it on, and its trail records it' => sub {
    my $s = new_site( root => repo_root() );
    my $d = $s->docroot;
    my @ALL = qw(ui manage_users);
    $s->add_user('boss');
    $s->grant( 'boss', 'ops', \@ALL, \@ALL );
    flagged_site($d);

    my $r = $s->call( 'boss', 'users', body => { action => 'account-approve', username => 'gus' } );
    ok( $r->{ok}, 'approved' ) or diag( explain $r );
    is_deeply( [ map { $_->{group} } @{ $r->{unplaced} || [] } ], ['vault'],
        'the result names the group it could not join' );

    my @a = audit_lines( $d, qr/\| user-account-approve \|.*\| ok \|/ );
    like( $a[-1] // '', qr/not-placed=vault\s*$/, 'and the manager trail records it' )
        or diag( 'The users tool audits only on the CLI; through the Users API '
            . 'the manager writes the trail, so it has to say so itself.' );
};

subtest 'an explicit --group that cannot be joined is reported the same way' => sub {
    my $d = flagged_site();
    my ( $rc, $out ) = cli( $d, 'account-approve', 'carol', '--group', 'vault' );
    is( $rc, 0, 'the account is created' ) or diag($out);
    like( $out, qr/Approved 'carol' \(no group\)/, 'in no group' );
    like( $out, qr/NOT placed in 'vault'/, 'saying which group did not take' );
};

subtest 'when every placement takes, unplaced is present and empty' => sub {
    my $d = site();
    cli( $d, 'group-set', 'learners', 'ui', 'on' );
    api( $d, { action => 'group-settings-set', group => 'learners',
            key => 'registration', value => 'on' } );
    my $r = api( $d, { action => 'account-approve', username => 'dora' } );
    ok( $r->{ok}, 'approved' );
    is_deeply( $r->{unplaced}, [], 'nothing failed, and the result says so' );
    my ( undef, $out ) = cli( $d, 'account-approve', 'erin' );
    unlike( $out, qr/NOT placed/, 'and the CLI prints no failure' );
};

# --- SM858's button, through the manager API --------------------------------

my $PLUGIN = repo_root() . '/plugins/form-handler.pl';
SKIP: {
    skip "no $PLUGIN", 1 unless -f $PLUGIN;
    subtest 'the approve button reports it, and its trail records it' => sub {
        my $s = new_site( root => repo_root() );
        my $d = $s->docroot;
        make_path("$d/lazysite/forms");
        my $SECRET = 'test-secret-approve-49';
        my $spit   = sub {
            my ( $p, $t ) = @_;
            open my $fh, '>', $p or die "$p: $!";
            print {$fh} $t;
            close $fh;
        };
        $spit->( "$d/lazysite/forms/.secret", "$SECRET\n" );
        $spit->( "$d/lazysite/forms/handlers.conf",
            "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
                . "    path: lazysite/forms/submissions\n" );
        $spit->( "$d/lazysite/forms/register.conf",
            "targets:\n  - handler: jsonl\naccount_email: email\n" );

        my $ts   = time() - 10;
        my $body = join '&', '_form=register', "_ts=$ts",
            '_tk=' . hmac_sha256_hex( $ts, $SECRET ), '_hp=', 'email=fay@example.org',
            'name=Fay';
        $spit->( "$d/post.txt", $body );
        {
            local $ENV{REQUEST_METHOD} = 'POST';
            local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
            local $ENV{CONTENT_LENGTH} = length $body;
            local $ENV{DOCUMENT_ROOT}  = $d;
            local $ENV{REMOTE_ADDR}    = '10.9.49.1';
            local $ENV{HTTP_ACCEPT}    = 'application/json';
            qx($^X \Q$PLUGIN\E < \Q$d/post.txt\E 2>/dev/null);
        }

        my @ALL = qw(ui manage_users read_submissions);
        $s->add_user('boss');
        $s->grant( 'boss', 'ops', \@ALL, \@ALL );
        flagged_site($d);

        my $file = 'lazysite/forms/submissions/register.jsonl';
        my $list = $s->call( 'boss', 'form-submissions',
            query => "action=form-submissions&file=$file" );
        my ($row) = grep { ( $_->{email} // '' ) eq 'fay@example.org' } @{ $list->{rows} || [] };
        ok( $row, 'the canary: the real handler stored the registration' ) or return;

        my $r = $s->call( 'boss', 'form-submission-approve',
            body => { file => $file, id => $row->{_id} } );
        ok( $r->{ok}, 'approved' ) or diag( explain $r );
        is_deeply( $r->{group}, ['learners'], 'placed where it could be' );
        is_deeply( [ map { $_->{group} } @{ $r->{unplaced} || [] } ], ['vault'],
            'and the result names the group it could not join' )
            or diag( 'action_form_submission_approve passed group, claim and path '
                . 'through and dropped anything else account-approve said.' );

        my @a = audit_lines( $d, qr/\| form-submission-approve \|.*\| ok \|/ );
        like( $a[-1] // '', qr/account=fay not-placed=vault/,
            'the manager trail records the failed placement' );
    };
}

done_testing();
