#!/usr/bin/perl
# SM353: three things that answered differently depending on how you asked.
#
# WHY ONE FILE. They are the same defect - two surfaces disagreeing about one
# question, which SM268 recorded as its recurring theme and SM288 fixed one layer
# down for group membership. None justifies its own lint and together they
# describe a rule: a caller reasoning about its own request should not get a
# different answer from the channel it used.
#
# THE TRAP IN TESTING THIS, recorded because it nearly cost the coverage.
# JSON::PP::true stringifies to "1" and numifies to 1. So every existing Perl
# assertion of the form is( $r->{ok}, 1 ) passes whether `ok` is the number or
# the boolean, and a suite full of them would report success across the whole
# change while the wire format flipped underneath. The only assertion that can
# see the difference is one made against the ENCODED JSON, which is what the
# `ok` subtests below use.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP   ();

my $root = repo_root();

sub slurp {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or die "$f: $!";
    local $/;
    return <$fh>;
}

subtest 'ok is coerced once per surface, not per handler' => sub {
    # Coercing at the ~130 places that set `ok` would have been 130 chances to
    # miss one. Each surface has exactly one point every result passes through,
    # and that is where the rule lives.
    like( slurp('lib/Lazysite/Manager/Common.pm'),
        qr/sub respond \{.*?\$data->\{ok\} = \$data->\{ok\}\s*\?\s*JSON::PP::true\s*:\s*JSON::PP::false/s,
        'the control API coerces in respond()' );
    like( slurp('lazysite-mcp.pl'),
        qr/\$out->\{ok\} = \$out->\{ok\}\s*\?\s*JSON::PP::true\s*:\s*JSON::PP::false/,
        'and MCP coerces at its single tool-result point' )
        or diag( 'MCP was not internally consistent either - '
            . 'describe_capabilities emitted true and validate_page emitted 1 - '
            . 'so this is not the API being brought into line with MCP.' );
};

subtest 'and it reaches the wire as a boolean' => sub {
    # Against the encoded JSON, for the reason in the header: the decoded value
    # compares equal to 1 either way.
    require Lazysite::Manager::Common;

    for my $case ( [ 1, 'true' ], [ 0, 'false' ] ) {
        my ( $in, $want ) = @$case;
        my $out = '';
        {
            local *STDOUT;
            open STDOUT, '>', \$out or die $!;
            Lazysite::Manager::Common::respond( { ok => $in, thing => 'x' } );
        }
        like( $out, qr/"ok":$want/,
            "ok => $in is encoded as $want" )
            or diag( "Response was: $out\n"
                . 'A caller written as res.ok === true succeeds on one surface '
                . 'and fails on the other, silently, and only when someone '
                . 'ports code between channels.' );
    }
};

subtest 'the capability map holds the same keys on both surfaces' => sub {
    # This is the document that tells a caller what it may do. An MCP caller
    # could not see its own group membership and an API caller could.
    like( slurp('lazysite-mcp.pl'),
        qr/describe\(\s*caps\s*=>.*?groups\s*=>/s,
        'MCP passes groups to describe()' )
        or diag( 'SM288 already settled this one layer down: a token carrying '
            . 'no groups was not a safe default, it was a third answer.' );
    like( slurp('lazysite-manager-api.pl'),
        qr/describe\(\s*caps\s*=>.*?groups\s*=>/s,
        'and so does the control API' );
};

subtest 'every redirect states its content type' => sub {
    # The filing found ONE - the gating bounce declaring text/x-perl, the CGI's
    # own type leaking because the response named none. Sweeping for the shape
    # rather than fixing the reported instance found seven, three of them in the
    # auth wrapper, which is also on the gating path.
    my @bare;
    for my $file (
        qw(lazysite-processor.pl lazysite-front.pl
        lazysite-manager-api.pl lazysite-auth.pl)
        )
    {
        my @l = split /\n/, slurp($file);
        for my $i ( 0 .. $#l ) {
            next unless $l[$i] =~ /print "Status: 30[12]/;
            my $ct = 0;
            for my $j ( $i .. ( $i + 8 > $#l ? $#l : $i + 8 ) ) {
                $ct = 1 if $l[$j] =~ /Content-Type:/i;
                last if $l[$j] =~ /\\r\\n\\r\\n|\\n\\n/;
            }
            push @bare, "$file:" . ( $i + 1 ) unless $ct;
        }
    }
    is_deeply( \@bare, [],
        'no redirect leaves the type to be inferred' )
        or diag( "Bare at: @bare\n"
            . 'With none stated the response carries whatever the web server '
            . 'infers from the CGI, which advertises the implementation '
            . 'language on a security boundary for no benefit.' );
};

done_testing();
