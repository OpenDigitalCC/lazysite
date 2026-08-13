#!/usr/bin/perl
# SM289: `lazysite acl` - setting access from a shell.
#
# Every other administrative act on lazysite has a CLI form, because the recovery
# story for this product is "you have a shell". Access control did not, so the
# answer to "the manager is locked out and I need to grant myself access" was to
# hand-edit acls.json - the exact thing SM267 was built to stop people doing.
#
# THE SECURITY-CRITICAL PART OF THIS FILE is the actor. There is no session
# behind a shell, so a tool that defaulted to an operator identity would be a
# privilege-escalation path on the one surface with nothing checking it: a user
# who cannot grant themselves access in the manager could simply run this. The
# subtests below assert the refusals before they assert the feature.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root grant_caps);
use Lazysite::Private qw(private_path);

my $root = repo_root();
my $tool = "$root/tools/lazysite-acl.pl";
ok( -f $tool, 'tools/lazysite-acl.pl present' );

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/auth", "$d/members", "$d/open" );

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/members/secret.md",      "SECRET\n" );
spit( "$d/open/public.md",         "PUBLIC\n" );

# alice is an operator (manage_users); mallory is an ordinary account with no
# authority over anything.
spit( "$d/lazysite/auth/users", "alice:x\nmallory:y\n" );
grant_caps( $d, 'alice', 'manage_users', 'manage_content' );
grant_caps( $d, 'mallory', 'manage_content' );

# List-form exec, so no shell is involved and no argument needs quoting. The
# first version built a command string and every argument arrived mangled -
# every subtest failed with "--docroot is required", which looks like a tool
# defect and was a harness defect.
sub acl {
    my (@args) = @_;
    my $err    = "$base/acl-stderr.$$";
    my $pid    = open my $ph, '-|';
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>', $err or die $!;
        exec $^X, "-I$root/lib", $tool, @args;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    my $rc = $? >> 8;
    my $e  = '';
    if ( open my $eh, '<', $err ) { local $/; $e = <$eh> // ''; close $eh }
    unlink $err;
    return { out => ( $out // '' ) . $e, rc => $rc };
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

sub stored {
    open my $fh, '<', "$d/lazysite/auth/acls.json" or return {};
    my $t = do { local $/; <$fh> };
    close $fh;
    return JSON::PP::decode_json( $t || '{}' );
}

subtest 'a write without an actor is refused' => sub {
    my $r = acl( 'set', 'members/', '--docroot', $d, '--read', 'alice' );
    isnt( $r->{rc}, 0, 'it fails' );
    like( $r->{out}, qr/--actor is required/,
        'and says why - there is no session behind a shell, so the tool must '
            . 'not invent an identity' );
    ok( !exists stored()->{'members'}, 'and nothing was written' );
};

subtest 'an actor without authority is refused, exactly as in the manager' => sub {
    # THE ESCALATION TEST. The requirement is not "the CLI refuses people" - it
    # is "the CLI gives the same answer the manager gives", because any
    # divergence is a way round the manager.
    #
    # My first version of this had mallory claim an UNPROTECTED path and expected
    # a refusal. That was wrong about the product: protection is opt-in, and
    # creating the first rule on a path needs only write access to it, so the
    # manager allows exactly that. The CLI allowing it was correct behaviour and
    # the test was asserting a policy lazysite does not have.
    #
    # The real boundary is an EXISTING rule someone else owns: "Only the owner
    # may change permissions". That is a rule the manager enforces, so it is the
    # one worth proving the CLI cannot be used to step around.
    my $claim = acl( 'set', 'open/public.md', '--docroot', $d,
        '--actor', 'alice', '--read', 'alice' );
    is( $claim->{rc}, 0, 'alice owns a rule on this path' ) or diag( $claim->{out} );

    my $r = acl( 'set', 'open/public.md', '--docroot', $d,
        '--actor', 'mallory', '--read', 'mallory' );
    isnt( $r->{rc}, 0, 'mallory cannot take it over' );
    like( $r->{out}, qr/only the owner/i,
        'and gets the manager\'s own refusal, not a CLI-specific one' );
    is_deeply( stored()->{'open/public.md'}{read}, ['alice'],
        'the rule is untouched' );

    acl( 'remove', 'open/public.md', '--docroot', $d, '--actor', 'alice' );
};

subtest 'an operator can set a rule, and the content moves' => sub {
    my $r = acl( 'set', 'members/', '--docroot', $d,
        '--actor', 'alice', '--read', 'alice,@editors' );
    is( $r->{rc}, 0, 'it succeeds' ) or diag( $r->{out} );

    my $a = stored()->{'members'};
    ok( $a, 'the rule is stored' );
    is_deeply( $a->{read}, [ 'alice', '@editors' ],
        'with both subject kinds parsed from one comma list' );

    # SM286: the same writer, so the same move. This is the property the whole
    # design rests on - a rule set from a shell is not a second kind of rule.
    ok( !-e "$d/members/secret.md", 'the content left the document root' );
    is( slurp( private_path( $d, 'members/secret.md' ) ), "SECRET\n",
        'and is in the private store' );
};

subtest 'show and list read it back' => sub {
    # An actor is needed to READ a protected rule: who may see a gated section
    # is itself information about that section, and the shared reader refuses it
    # for the same reason the manager does.
    my $noactor = acl( 'show', 'members/', '--docroot', $d );
    isnt( $noactor->{rc}, 0, 'showing a protected rule needs an identity too' );
    like( $noactor->{out}, qr/add --actor/,
        'and the tool names the one thing the user can do about it, rather '
            . 'than leaving them with a bare "not the owner"' );

    my $s = acl( 'show', 'members/', '--docroot', $d, '--actor', 'alice' );
    is( $s->{rc}, 0, 'show succeeds' ) or diag( $s->{out} );
    like( $s->{out}, qr/\@editors/, 'and reports the read list' );
    like( $s->{out}, qr/gated/,     'and the policy' );

    my $l = acl( 'list', '--docroot', $d );
    is( $l->{rc}, 0, 'list succeeds' ) or diag( $l->{out} );
    like( $l->{out}, qr/members/, 'and names the held-back section' );

    my $o = acl( 'show', 'open/public.md', '--docroot', $d );
    like( $o->{out}, qr/no rule - public/,
        'the control: an unprotected path says so plainly rather than '
            . 'printing an empty rule' );
};

subtest 'the site-wide rule reports that it moves nothing' => sub {
    my $r = acl( 'set', '/', '--docroot', $d, '--actor', 'alice',
        '--read', 'alice' );
    is( $r->{rc}, 0, 'it succeeds' ) or diag( $r->{out} );
    like( $r->{out}, qr/site-wide/i,
        'and the warning reaches the terminal - the move can fail while the '
            . 'rule is stored, and both outcomes look identical from outside' );
    acl( 'remove', '/', '--docroot', $d, '--actor', 'alice' );
};

subtest 'remove takes the rule away and brings the content back' => sub {
    my $r = acl( 'remove', 'members/', '--docroot', $d, '--actor', 'alice' );
    is( $r->{rc}, 0, 'it succeeds' ) or diag( $r->{out} );
    ok( !exists stored()->{'members'}, 'the rule is gone' );
    ok( -e "$d/members/secret.md",     'and the content is public again' );

    # Removing what is not there is not an error - a recovery tool that fails
    # on a no-op is a tool people stop trusting mid-incident.
    my $again = acl( 'remove', 'members/', '--docroot', $d, '--actor', 'alice' );
    is( $again->{rc}, 0, 'removing again is not an error' );
    like( $again->{out}, qr/nothing to remove/, 'and says so' );
};

subtest 'json output for a caller that is not a person' => sub {
    acl( 'set', 'members/', '--docroot', $d, '--actor', 'alice',
        '--read', 'alice' );
    my $r = acl( 'show', 'members/', '--docroot', $d, '--actor', 'alice',
        '--json' );
    is( $r->{rc}, 0, 'it succeeds' );
    my $j = eval { JSON::PP::decode_json( $r->{out} ) };
    ok( $j && $j->{ok}, 'the output parses as JSON' ) or diag( $r->{out} );

    # The standing rule: filesystem paths are never exposed through any surface.
    unlike( $r->{out}, qr/\Q$base\E/,
        'and carries no absolute filesystem path' );
};

done_testing();
