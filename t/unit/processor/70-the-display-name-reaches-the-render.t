#!/usr/bin/perl
# SM743: a user's display_name reaches auth_name, and is escaped ONCE.
#
# The field was stored, editable, and consumed by nothing. `display_name` had a
# single reader in the whole tree - the users tool that also wrote it - while
# the admin bar was written to prefer a display name over the login and
# `auth_name` had one producer: an upstream proxy's X-Remote-Name header. On a
# site using lazysite's own auth there was no path between them, so an operator
# could set a display name, watch it save, and never see it again.
#
# THE SECOND HALF IS WHY THIS MATTERS BEYOND A DEAD FIELD. SM709 escapes
# auth_name where the TT stash is built AND again at the admin bar, which reads
# %AUTH_CONTEXT directly. Both escape from the RAW value, which is correct and
# is only correct while the value stored is raw. Store it escaped and a name
# gets escaped twice, and `O'Brien & Sons` renders as `O&amp;#39;Brien
# &amp;amp; Sons` on the page - a visible, obvious defect, and the exact reason
# the field agent could not test SM709 at all: the sink was unreachable.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use JSON::PP                 ();
use Lazysite::Auth::Settings ();

my $dir = tempdir( CLEANUP => 1 );
mkdir "$dir/auth";

# The awkward name from the 0.12.0 test plan, which is the case that had never
# been run: an apostrophe, an ampersand and an accent.
my $AWKWARD = "S\x{e9}an O'Brien & Sons";

open my $fh, '>:raw', "$dir/auth/user-settings.json" or die $!;
print {$fh} JSON::PP->new->canonical->utf8->encode(
    { vprobe => { display_name => $AWKWARD },
        plain     => { display_name => '' },
        nosetting => { comment      => 'has settings but no display name' },
    }
);
close $fh;

$Lazysite::Auth::Settings::AUTH_DIR = "$dir/auth";

subtest 'the shared reader returns the name, RAW' => sub {
    my $got = Lazysite::Auth::Settings::display_name_for('vprobe');
    is( $got, $AWKWARD, 'the value the operator typed, byte for byte' );

    # The assertion that keeps the two sinks correct. Escaping here would be
    # invisible in this test if it only checked "not empty".
    unlike( $got, qr/&(?:amp|#39|quot);/,
        'NOT escaped - both sinks escape, so escaping here would double it' );
};

subtest 'the absent and empty cases answer, rather than dying' => sub {
    is( Lazysite::Auth::Settings::display_name_for('plain'), '',
        'an empty display_name is empty' );
    is( Lazysite::Auth::Settings::display_name_for('nosetting'), '',
        'a user with settings but no display_name is empty' );
    is( Lazysite::Auth::Settings::display_name_for('ghost'), '',
        'an unknown account is empty, not an error' );
    is( Lazysite::Auth::Settings::display_name_for(undef), '',
        'and undef is empty' );
};

subtest 'the processor keeps its own copy, because it may not import this' => sub {
    # ADR 0001: the processor's render path is module-free by design, so it
    # cannot use the shared helper. A first draft called it inside an eval,
    # which would have died, been swallowed, and made every display name ''
    # forever - shipped, apparently working, doing nothing.
    #
    # So the local copy must EXIST and must not be a call to the shared one.
    my $root = "$FindBin::Bin/../../..";
    my $src  = do {
        open my $p, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$p>;
    };

    like( $src, qr/sub _display_name_for/,
        'the processor defines its own reader' );

    # COMMENTS STRIPPED FIRST. The first version of this assertion searched the
    # whole file and failed on the processor's own comment, which names the
    # shared helper in prose to say why it is NOT called. A source check that
    # cannot tell code from prose ABOUT code reports the explanation as the
    # defect - which is the same shape as every other check that matched the
    # wrong thing this week.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    unlike( $code, qr/Lazysite::Auth::Settings::display_name_for\s*\(/,
        'and does NOT call the shared one, which it cannot load' );

    # The slurp must be scoped. An unscoped `local $/` at a sub's top level is
    # what SM702 was: it changed how a LATER function read a different file and
    # cost every nested group its capabilities.
    my ($body) = $src =~ /(sub _display_name_for.*?\n    \}\n)/s;
    ok( defined $body, 'the reader was found' ) or return;
    like( $body, qr/\{\s*\n\s*open my \$fh.*?local \$\/;/s,
        'its slurp is inside a block, not at the sub\'s top level' );
};

subtest 'the header still wins where an upstream sets one' => sub {
    # A deployment behind header auth has an upstream that knows who this is.
    # Its answer must not be second-guessed by a local record - so the fallback
    # is only consulted when the header produced nothing.
    my $root = "$FindBin::Bin/../../..";
    my $src  = do {
        open my $p, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$p>;
    };
    like( $src,
        qr/my \$native_name = \$auth_result->\{auth_name\};\s*\n\s*if \( !defined \$native_name \|\| !length \$native_name \)/,
        'display_name is consulted only when auth_name is absent or empty' );

    # And the fallback must actually CALL the reader. Without this the guard
    # above could sit over a branch that does nothing, which is precisely the
    # defect being fixed - a path that looks wired and is not.
    my ($block) = $src =~ /(my \$native_name = \$auth_result->\{auth_name\};.{0,400})/s;
    ok( defined $block, 'the fallback block was found' ) or return;
    like( $block, qr/_display_name_for\(\s*\$auth_result->\{auth_user\}\s*\)/,
        'and it calls the local reader with the authenticated user' );

    # The value must reach %AUTH_CONTEXT raw. If auth_name were assigned from
    # anything else, everything above would still pass and the field would
    # still be dead.
    like( $block, qr/auth_name\s*=>\s*\$native_name/,
        'and %AUTH_CONTEXT takes auth_name FROM it' );
};

done_testing();
