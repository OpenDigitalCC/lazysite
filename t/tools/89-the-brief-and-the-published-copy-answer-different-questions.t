#!/usr/bin/perl
# SM910: the partner brief told its reader to confirm the brief's claims against
# /.well-known/ai-partner, and named that endpoint as the published copy of its
# own machine-readable block. The endpoint is partner-agnostic, so its capability
# list is about the SITE. On the reported host the two differed in both
# directions, five of nine, and it was the ENDPOINT that was misleading: the
# partner exchanged its key and whoami returned exactly the nine the brief named,
# with manage_config false - which the endpoint advertised and the account did not
# hold.
#
# Three published statements also disagreed about one WebDAV write. Whichever is
# true, two are wrong, and they shipped together. So the assertions that matter
# here are not wording: they PIN THE DOCUMENT TO THE CODE THAT ENFORCES IT, so the
# next edit to either cannot re-open the disagreement.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return <$fh>;
}

my $users = slurp("$root/tools/lazysite-users.pl");
my $proc  = slurp("$root/lazysite-processor.pl");
my $dav   = slurp("$root/lazysite-dav.pl");

subtest 'the brief sends a grant question to whoami, not to the site document' => sub {
    like( $users, qr/Only\s+`whoami` confirms your grant/,
        'it says which check answers a grant' );
    unlike( $users, qr/confirm its claims\s*\n?\s*against \$base\/\.well-known/,
        'and no longer sends the reader there to confirm its claims' )
        or diag( 'That instruction cost a field run: the check it asks for is the '
            . 'one check that cannot settle the question.' );
};

subtest 'ONE capability gates the navigation write, and the code decides which' => sub {
    # The enforcement, read out of the WebDAV endpoint rather than remembered.
    my ($cap) = $dav =~ m{lazysite/nav\.conf requires the (\w+) capability};
    is( $cap, 'manage_nav', 'the endpoint enforces manage_nav' ) or return;

    like( $proc, qr/lazysite\/nav\.conf \(with \Q$cap\E\)/,
        "the published site document names $cap" )
        or diag( 'It said manage_config. A partner holding manage_nav and not '
            . 'manage_config wrote the file, so the document was wrong.' );
    like( $users, qr/PUT to `\/dav\/lazysite\/nav\.conf` is accepted with `\Q$cap\E`/,
        "and the brief's Notes say the same, in the same capability" )
        or diag( 'The Notes said the PUT "is refused" while the body of the same '
            . 'document said it is accepted. A careful reader trusts the Notes.' );
};

subtest 'the layouts tree is writable, and the brief no longer denies it' => sub {
    like( $dav, qr/only lazysite\/layouts\/ is writable over WebDAV/,
        'the endpoint says so itself' );
    unlike( $users, qr/`lazysite\/` paths are internal and not writable over WebDAV/,
        'the brief no longer claims the whole tree is unwritable' )
        or diag( 'It would send a partner holding manage_layouts to ask a sysop '
            . 'for something it can do itself - measured: MKCOL then ten PUTs.' );
    like( $users, qr/`lazysite\/layouts\/` \*\*is\*\* writable/,
        'and says which part is writable' );
};

subtest 'the site document cannot be mistaken for a grant' => sub {
    like( $proc, qr/capabilities_note/, 'it carries a note about its own list' );
    like( $proc, qr/not the capabilities YOU hold/,
        'which says the list is not the reader\'s grant' );
    like( $proc, qr/Only whoami answers that/, 'and names what does' );
};

subtest 'an empty endpoints map says WHY it is empty' => sub {
    # Measured while building this: the fields populate whenever the service is
    # on, so "never filled" was not the defect. The defect was that a site
    # publishing over no surface looked identical to an unfinished document.
    like( $proc, qr/services\s*=>\s*\{/, 'the document states the service switches' );
    for my $svc (qw(webdav control mcp exchange)) {
        like( $proc, qr/\b\Q$svc\E\s*=>\s*\(\s*\$\w+\s*\?\s*JSON::PP::true/,
            "$svc is reported as an explicit boolean" );
    }
};

subtest 'the navigation save says that it replaces everything' => sub {
    like( $users, qr/REPLACES THE WHOLE NAVIGATION/,
        'the brief warns beside the recommendation' )
        or diag( 'It discarded a nine-item starter nav on the reported site, '
            . 'which is correct behaviour and worth saying out loud.' );
};

subtest 'a channel held and a service switched off are two facts' => sub {
    like( $users, qr/THE CHANNEL AND THE SERVICE ARE TWO FACTS/,
        'the brief distinguishes them' );
    like( $users, qr/services\.mcp/, 'and names where the site\'s answer lives' );
};

done_testing();
